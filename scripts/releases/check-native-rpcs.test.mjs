import test from 'node:test';
import assert from 'node:assert/strict';
import { compareSnapshot, snapshotSQL, collectCalls } from './check-native-rpcs.mjs';
import { fileURLToPath } from 'node:url';
import { mkdtempSync, mkdirSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
const now = Date.parse('2026-10-16T01:30:00Z');
const valid = () => ({ project_ref: 'opwzujhfsxqaivtbjewg', checked_at: new Date(now).toISOString(), required_rpc_names: ['read_a', 'read_b'], functions: [{name:'read_a',arguments:''}] });
test('blocks missing RPCs and accepts a complete current snapshot', () => {
  const snapshot = valid(); assert.deepEqual(compareSnapshot(['read_a','read_b'],snapshot,now),['read_b']);
  snapshot.functions.push({name:'read_b',arguments:'p_id uuid'}); assert.deepEqual(compareSnapshot(['read_a','read_b'],snapshot,now),[]);
});
test('fails closed for stale, future, wrong-project, incomplete or malformed metadata', () => {
  for (const value of [ {...valid(),checked_at:'2026-10-15T00:00:00Z'}, {...valid(),checked_at:'2026-10-17T00:00:00Z'}, {...valid(),project_ref:'other'}, {...valid(),required_rpc_names:[]}, {...valid(),functions:null} ]) assert.throws(() => compareSnapshot(['read_a'],value,now));
});
test('SQL inventories only validated literal names and actual native calls', () => {
  assert.throws(() => snapshotSQL(["x';drop table x;"]));
  assert.match(snapshotSQL(['get_my_native_context']),/pg_catalog|pg_proc/);
  const calls=collectCalls(fileURLToPath(new URL('../../apps/ios-native/project.yml',import.meta.url)));
  assert.ok(calls.has('list_community_posts')); assert.ok(calls.has('validate_chat_access'));
});

function fixture(t) {
  const dir = mkdtempSync(join(tmpdir(), 'native-rpcs-'));
  t.after(() => rmSync(dir, { recursive: true, force: true }));
  const put = (path, text) => {
    const full = join(dir, path);
    mkdirSync(join(full, '..'), { recursive: true });
    writeFileSync(full, text);
  };
  const config = {
    name: 'Fixture', options: {},
    targets: { JaegunNative: { type: 'application', platform: 'iOS', sources: [
      { path: 'Sources', excludes: ['Excluded.swift', 'Nested/Excluded'] },
      { path: 'Assets', buildPhase: 'resources' },
    ] } },
  };
  const save = () => put('project.yml', JSON.stringify(config));
  put('Sources/Root.swift', '.rpc("root_call")');
  put('Sources/Nested/Deep/Shipped.swift', '.rpc("nested_call")');
  put('Sources/Excluded.swift', '.rpc("excluded_file")');
  put('Sources/Nested/Excluded/Hidden.swift', '.rpc("excluded_directory")');
  put('Assets/Resource.swift', '.rpc("resource_call")');
  save();
  return { config, save, project: join(dir, 'project.yml'), put };
}

test('inventories nested shipped Swift while honoring configured exclusions and resource phases', t => {
  const { project } = fixture(t);
  const calls = collectCalls(project);
  assert.deepEqual([...calls.keys()].sort(), ['nested_call', 'root_call']);
  assert.match([...calls.get('nested_call')][0], /Nested\/Deep\/Shipped\.swift$/);
  assert.match(snapshotSQL([...calls.keys()].sort()), /'nested_call'/);
});

test('fails closed when the project uses unsupported source configuration', t => {
  const { config, save, project, put } = fixture(t);
  config.include = ['other.yml']; save();
  assert.throws(() => collectCalls(project), /Unsupported project key/);
  delete config.include;
  config.targets.JaegunNative.sources[0].excludes = ['**/*.swift']; save();
  assert.throws(() => collectCalls(project), /Unsupported source exclusion/);
  config.targets.JaegunNative.sources[0].excludes = [];
  config.targets.JaegunNative.sources[0].compilerFlags = '-DTEST'; save();
  assert.throws(() => collectCalls(project), /Unsupported source key/);
  delete config.targets.JaegunNative.sources[0].compilerFlags;
  config.targets.JaegunNative.settings = { base: { EXCLUDED_SOURCE_FILE_NAMES: '*.swift' } }; save();
  assert.throws(() => collectCalls(project), /Unsupported source build setting/);
  put('project.yml', 'name: one\nname: two\n');
  assert.throws(() => collectCalls(project), /Cannot safely parse/);
});
