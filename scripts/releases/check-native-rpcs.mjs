import { readdirSync, readFileSync } from 'node:fs';
import { resolve, relative } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = fileURLToPath(new URL('../../', import.meta.url));
const project = 'opwzujhfsxqaivtbjewg';
export function collectCalls(directory) {
  const calls = new Map();
  for (const entry of readdirSync(directory, { withFileTypes: true })) {
    if (!entry.isFile() || !entry.name.endsWith('.swift')) continue;
    const path = resolve(directory, entry.name);
    const source = readFileSync(path, 'utf8');
    // Literal call-site coverage only: dynamic RPC names and Edge Functions
    // need their own contracts. Do not interpret this as an authorization test.
    for (const match of source.matchAll(/\.rpc\("([a-z][a-z0-9_]*)"/g)) {
      const files = calls.get(match[1]) ?? new Set();
      files.add(relative(root, path)); calls.set(match[1], files);
    }
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
    const names = [...collectCalls(resolve(root, 'apps/ios-native/Sources')).keys()].sort();
    if (args.length === 1 && args[0] === '--sql') console.log(snapshotSQL(names));
    else {
      if (args.length !== 2 || args[0] !== '--snapshot') throw new Error('Usage: check-native-rpcs.mjs --sql | --snapshot <fresh metadata JSON>');
      const missing = compareSnapshot(names, JSON.parse(readFileSync(resolve(args[1]), 'utf8')));
      console.log(JSON.stringify({ literalRPCs: names.length, missingCount: missing.length, missing, limits: 'Existence only; not signatures, grants, RLS, dynamic calls, Edge deployment or E2E.' }, null, 2));
      if (missing.length) process.exitCode = 1;
    }
  } catch (error) { console.error(error.message); process.exitCode = 1; }
}
