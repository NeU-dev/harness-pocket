import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { Harness } from '../src/harness.mjs';

test('approval answers include the owning client and use named RPC args', async t => {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'pocket-approval-'));
  t.after(() => fs.rmSync(directory, { recursive: true, force: true }));
  const harness = new Harness({ url: 'http://127.0.0.1:3080', store: { directory } });
  harness.ready = true; harness.clientId = 'client';
  harness.pending.set('event', { event: 'approval/request', agentId: 'session' });
  const calls = [];
  harness.rpc = async (...args) => { calls.push(args); return { ok: true }; };
  await assert.rejects(() => harness.answer('event', 'allow-always'), /Invalid approval/);
  assert.equal(calls.length, 0);
  await harness.answer('event', 'allowed-once');
  assert.deepEqual(calls, [['$events/result', { clientId: 'client', eventId: 'event', outcome: { kind: 'result', value: 'allowed-once' } }]]);
  assert.equal(harness.pending.size, 0);
  await assert.rejects(() => harness.answer('event', 'allowed-once'), /終了しました/);
  assert.equal(calls.length, 1);
});
