import { lstatSync, readdirSync, readFileSync } from 'node:fs';
import { dirname, isAbsolute, relative, resolve } from 'node:path';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const root = fileURLToPath(new URL('../../', import.meta.url));
const project = 'opwzujhfsxqaivtbjewg';
// Use the macOS system Ruby YAML parser rather than treating YAML as indentation
// and silently missing alternate spellings, aliases, or duplicate keys.
const parseYAML = `
require 'psych'
require 'json'
def check(node)
  if node.is_a?(Psych::Nodes::Mapping)
    keys = node.children.each_slice(2).map { |key, _| key.value }
    raise 'duplicate or complex YAML key' if keys.any?(&:nil?) || keys.uniq.length != keys.length
  end
  node.children&.each { |child| check(child) }
end
text = STDIN.read
tree = Psych.parse_stream(text)
raise 'expected one YAML document' unless tree.children.length == 1
check(tree)
puts JSON.generate(Psych.safe_load(text, aliases: false))
`;

function readProject(path) {
  const result = spawnSync('ruby', ['-e', parseYAML], { input: readFileSync(path, 'utf8'), encoding: 'utf8' });
  if (result.error || result.status !== 0) throw new Error(`Cannot safely parse XcodeGen project: ${result.error?.message ?? result.stderr.trim()}`);
  return JSON.parse(result.stdout);
}

function assertKeys(object, allowed, label) {
  if (!object || typeof object !== 'object' || Array.isArray(object)) throw new Error(`Invalid ${label}`);
  for (const key of Object.keys(object)) if (!allowed.includes(key)) throw new Error(`Unsupported ${label} key: ${key}`);
}

function checkBuildSettings(value) {
  if (!value || typeof value !== 'object') return;
  for (const [key, child] of Object.entries(value)) {
    if (/^(EXCLUDED_SOURCE_FILE_NAMES|INCLUDED_SOURCE_FILE_NAMES)(\[|$)/.test(key)) throw new Error(`Unsupported source build setting: ${key}`);
    checkBuildSettings(child);
  }
}

function safeRelative(path, label) {
  if (typeof path !== 'string' || !path || isAbsolute(path) || path.split('/').some(part => !part || part === '.' || part === '..') || /[*?[\]{}\\]/.test(path)) {
    throw new Error(`Unsupported ${label}: ${path}`);
  }
  return path;
}

export function collectCalls(projectFile) {
  const config = readProject(projectFile);
  assertKeys(config, ['name', 'options', 'settings', 'targets', 'schemes'], 'project');
  assertKeys(config.options, ['bundleIdPrefix', 'deploymentTarget', 'postGenCommand'], 'project options');
  assertKeys(config.targets, Object.keys(config.targets ?? {}), 'targets');
  const target = config.targets.JaegunNative;
  assertKeys(target, ['type', 'platform', 'info', 'sources', 'configFiles', 'settings'], 'application target');
  if (target.type !== 'application' || target.platform !== 'iOS' || !Array.isArray(target.sources)) throw new Error('Unsupported application target configuration');
  for (const [name, other] of Object.entries(config.targets)) {
    if (name !== 'JaegunNative' && other?.type !== 'bundle.unit-test') throw new Error(`Unsupported additional target: ${name}`);
  }
  checkBuildSettings(config.settings);
  checkBuildSettings(target.settings);
  const projectDir = dirname(resolve(projectFile));
  const calls = new Map();
  for (const source of target.sources) {
    const entry = typeof source === 'string' ? { path: source } : source;
    assertKeys(entry, ['path', 'excludes', 'buildPhase', 'type'], 'source');
    const sourcePath = safeRelative(entry.path, 'source path');
    if (entry.buildPhase !== undefined && !['sources', 'resources'].includes(entry.buildPhase)) throw new Error('Unsupported source build phase');
    if (entry.type !== undefined && !['group', 'folder'].includes(entry.type)) throw new Error('Unsupported source type');
    if (entry.type === 'folder' && entry.buildPhase !== 'resources') throw new Error('Unsupported folder source');
    if (entry.excludes !== undefined && !Array.isArray(entry.excludes)) throw new Error('Invalid source exclusions');
    const excludes = (entry.excludes ?? []).map(path => safeRelative(path, 'source exclusion'));
    const base = resolve(projectDir, sourcePath);
    function visit(path, subpath = '') {
      if (subpath && excludes.some(exclude => subpath === exclude || subpath.startsWith(`${exclude}/`))) return;
      const stat = lstatSync(path);
      if (stat.isSymbolicLink()) throw new Error(`Unsupported source symlink: ${path}`);
      if (stat.isDirectory()) {
        for (const name of readdirSync(path)) visit(resolve(path, name), subpath ? `${subpath}/${name}` : name);
      } else if (stat.isFile() && path.endsWith('.swift') && entry.buildPhase !== 'resources') {
        const sourceText = readFileSync(path, 'utf8');
        // Literal call-site coverage only; this is not an authorization test.
        for (const match of sourceText.matchAll(/\.rpc\("([a-z][a-z0-9_]*)"/g)) {
          const files = calls.get(match[1]) ?? new Set();
          files.add(relative(root, path)); calls.set(match[1], files);
        }
      } else if (!stat.isFile()) throw new Error(`Unsupported source entry: ${path}`);
    }
    // Resource-only entries cannot compile Swift, but validate their configuration.
    if (entry.buildPhase !== 'resources') visit(base);
  }
  return calls;
}

export function compareSnapshot(names, snapshot, now = Date.now()) {
  if (snapshot?.project_ref !== project) throw new Error('Wrong or missing Supabase project');
  const checked = Date.parse(snapshot.checked_at);
  if (!Number.isFinite(checked) || now - checked > 15 * 60_000 || checked - now > 60_000) throw new Error('RPC snapshot must be server-timestamped within 15 minutes');
  if (!Array.isArray(snapshot.functions) || !snapshot.functions.every(row => typeof row.name === 'string' && typeof row.arguments === 'string')) throw new Error('Invalid function metadata');
  if (!Array.isArray(snapshot.required_rpc_names) || names.some(name => !snapshot.required_rpc_names.includes(name))) throw new Error('Snapshot does not cover current literal call sites');
  const existing = new Set(snapshot.functions.map(row => row.name));
  return names.filter(name => !existing.has(name));
}

export function snapshotSQL(names) {
  if (!names.length || names.some(name => !/^[a-z][a-z0-9_]*$/.test(name))) throw new Error('Invalid RPC identifier');
  const quoted = names.map(name => `'${name}'`).join(',');
  return `select jsonb_build_object('checked_at',statement_timestamp(),'project_ref','${project}','required_rpc_names',jsonb_build_array(${quoted}),'functions',coalesce(jsonb_agg(jsonb_build_object('name',p.proname,'arguments',pg_get_function_identity_arguments(p.oid)) order by p.proname),'[]'::jsonb)) as snapshot from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public' and p.proname in (${quoted});`;
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try {
    const args = process.argv.slice(2);
    const names = [...collectCalls(resolve(root, 'apps/ios-native/project.yml')).keys()].sort();
    if (args.length === 1 && args[0] === '--sql') console.log(snapshotSQL(names));
    else {
      if (args.length !== 2 || args[0] !== '--snapshot') throw new Error('Usage: check-native-rpcs.mjs --sql | --snapshot <fresh metadata JSON>');
      const missing = compareSnapshot(names, JSON.parse(readFileSync(resolve(args[1]), 'utf8')));
      console.log(JSON.stringify({ literalRPCs: names.length, missingCount: missing.length, missing, limits: 'Existence only; not signatures, grants, RLS, dynamic calls, Edge deployment or E2E.' }, null, 2));
      if (missing.length) process.exitCode = 1;
    }
  } catch (error) { console.error(error.message); process.exitCode = 1; }
}
