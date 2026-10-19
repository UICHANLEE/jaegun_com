import test from 'node:test';
import assert from 'node:assert/strict';
import { compareSnapshot, snapshotSQL, collectCalls } from './check-native-rpcs.mjs';
import { fileURLToPath } from 'node:url';
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
  const calls=collectCalls(fileURLToPath(new URL('../../apps/ios-native/Sources',import.meta.url)));
  assert.ok(calls.has('list_community_posts')); assert.ok(calls.has('validate_chat_access'));
});
