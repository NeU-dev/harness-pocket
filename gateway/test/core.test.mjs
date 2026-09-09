import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { generateKeyPairSync, verify } from 'node:crypto';
import { Store } from '../src/store.mjs';
import { APNs, NotificationWorker, makeProviderJWT, notificationPayload } from '../src/apns.mjs';
import { projectTranscript } from '../src/transcript.mjs';

function fixture(t) {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'pocket-test-'));
  t.after(() => fs.rmSync(directory, { recursive: true, force: true }));
  const store = new Store(directory);
  const pair = store.pair(store.pairCode().code, 'Test iPhone');
  const device = store.authenticate(pair.token);
  device.push = { token: 'a'.repeat(64), environment: 'sandbox' };
  store.subscribe(device, 'session-a', 10);
  return { directory, store, pair, device };
}
const event = (seq, type, reason) => ({ seq, type, data: reason ? { reason: { kind: reason } } : {} });

test('self-hosted APNs uses the app bundle ID, persists it, and keeps previous configuration on invalid input', t => {
  const { directory } = fixture(t);
  const apns = new APNs(directory, {});
  assert.equal(apns.status().configured, false);
  const { privateKey } = generateKeyPairSync('ec', { namedCurve: 'prime256v1' });
  const input = { keyId: 'KEYID12345', teamId: 'TEAMID1234', privateKey: privateKey.export({ type: 'pkcs8', format: 'pem' }), topic: 'com.example.MyPocket' };
  assert.equal(apns.configure(input).configured, true);
  const restored = new APNs(directory, {});
  assert.equal(restored.status().topic, input.topic);
  assert.equal(restored.configure({ keyId: input.keyId, teamId: input.teamId }).topic, input.topic);
  for (const topic of ['', '*', 'com.example.bad\nheader', null]) {
    assert.throws(() => restored.configure({ ...input, topic }));
    assert.equal(new APNs(directory, {}).status().topic, input.topic);
  }
  assert.equal(restored.configure({ ...input, topic: 'com.example.AnotherPocket' }).topic, 'com.example.AnotherPocket');
});

test('questions notify once with no question text and stop on answer, disconnect or turn end', async t => {
  const { store, device, directory } = fixture(t);
  store.questionAsked('session-a', 'question-1'); store.questionAsked('session-a', 'question-1');
  const restored = new Store(directory); restored.questionAsked('session-a', 'question-1');
  assert.equal(Object.keys(restored.state.outbox).length, 1);
  const item = Object.values(restored.state.outbox)[0];
  assert.match(notificationPayload(item).aps.alert.body, /質問/);
  assert.equal(notificationPayload(item).sessionId, 'session-a');
  let sends = 0;
  await new NotificationWorker(restored, { send: async () => { sends++; return { status: 200 }; } }).drain();
  assert.equal(sends, 1);
  restored.questionAsked('session-a', 'question-1');
  await new NotificationWorker(restored, { send: async () => assert.fail('duplicate') }).drain();
  restored.questionAsked('session-a', 'question-2'); restored.questionResolved('question-2');
  restored.questionAsked('session-a', 'question-3'); restored.questionConnectionLost();
  assert.equal(Object.values(restored.state.outbox).at(-1).status, 'waiting-connection');
  await new NotificationWorker(restored, { send: async () => assert.fail('disconnected question') }).drain();
  restored.questionAsked('session-a', 'question-3');
  assert.equal(Object.values(restored.state.outbox).at(-1).status, 'pending');
  restored.observe('session-a', [event(9, 'turn/end', 'completed')], 10);
  assert.equal(Object.values(restored.state.outbox).at(-1).status, 'pending', 'old turn end must not cancel a new question');
  restored.questionResolved();
  restored.questionAsked('session-a', 'question-4'); restored.observe('session-a', [event(11, 'turn/end', 'aborted')], 11);
  assert.equal(Object.values(restored.state.outbox).filter(n => n.status === 'pending').length, 0);
  store.questionAsked('unsubscribed', 'question-no'); device.notifications = false; store.questionAsked('session-a', 'question-disabled');
  assert.equal(Object.keys(store.state.outbox).length, 1);
});

test('approval notifications survive restart, deduplicate, and expire when answered before delivery', async t => {
  const { store, directory } = fixture(t);
  const asked = { seq: 11, type: 'approval/asked', data: { id: 'approval-1', toolName: 'bash', reason: 'private command' } };
  store.observe('session-a', [asked], 11);
  const restored = new Store(directory);
  restored.observe('session-a', [asked], 11);
  const items = Object.values(restored.state.outbox);
  assert.equal(items.length, 1);
  assert.equal(items[0].kind, 'approval');
  const payload = notificationPayload(items[0]);
  assert.equal(payload.sessionId, 'session-a');
  assert.match(payload.aps.alert.body, /許可/);
  assert.ok(!JSON.stringify(payload).includes('private command'));
  restored.observe('session-a', [{ seq: 12, type: 'approval/decided', data: { id: 'approval-1', outcome: 'allowed-once' } }], 12);
  await new NotificationWorker(restored, { send: async () => assert.fail('answered approval must not notify') }).drain();
  assert.equal(items[0].status, 'cancelled');
});

test('pairing is single use, expires, and stores only hashed device tokens', t => {
  const { store, pair } = fixture(t);
  const code = store.pairCode().code;
  assert.ok(store.pair(code, 'second'));
  assert.equal(store.pair(code, 'third'), null);
  assert.equal(store.authenticate('wrong'), null);
  assert.ok(store.authenticate(pair.token));
  assert.ok(!fs.readFileSync(store.file, 'utf8').includes(pair.token));
  const expiry = store.pairCode();
  for (const p of Object.values(store.state.pairing)) p.expires = 0;
  assert.equal(store.pair(expiry.code, 'late'), null);
});
test('notify only completed turns; not tool steps, errors, cancellation, baseline or duplicates', t => {
  const { store } = fixture(t);
  store.observe('session-a', [event(11, 'assistant/message'), event(12, 'turn/end', 'aborted'), event(13, 'turn/end', 'error'), event(14, 'turn/end', 'max-tokens')], 14);
  assert.equal(Object.keys(store.state.outbox).length, 0);
  store.observe('session-a', [event(15, 'turn/end', 'completed')], 15);
  store.observe('session-a', [event(15, 'turn/end', 'completed')], 15);
  assert.equal(Object.keys(store.state.outbox).length, 1);
  store.observe('session-a', [event(16, 'turn/end', 'completed')], 16, { baseline: true });
  assert.equal(Object.keys(store.state.outbox).length, 1);
});
test('persist cursor and outbox together; retry after a gateway restart without enqueueing duplicates', async t => {
  const { store, directory } = fixture(t);
  store.observe('session-a', [event(11, 'turn/end', 'completed')], 11);
  const restored = new Store(directory);
  restored.observe('session-a', [event(11, 'turn/end', 'completed')], 11);
  assert.equal(Object.keys(restored.state.outbox).length, 1);
  let count = 0;
  const worker = new NotificationWorker(restored, { send: async () => { count++; return count === 1 ? { status: 503, reason: 'ServiceUnavailable', retry: true } : { status: 200 }; } });
  await worker.drain();
  const item = Object.values(restored.state.outbox)[0];
  assert.equal(item.status, 'pending');
  await worker.drain(Date.now() + 86_000);
  assert.equal(item.status, 'sent');
  await worker.drain(Date.now() + 90_000);
  assert.equal(count, 2);
});
test('notification preference and revoked devices are respected at delivery time', async t => {
  const { store, device } = fixture(t);
  store.observe('session-a', [event(11, 'turn/end', 'completed')], 11);
  device.notifications = false;
  const worker = new NotificationWorker(store, { send: async () => assert.fail('must not send') });
  await worker.drain();
  assert.equal(Object.values(store.state.outbox)[0].status, 'expired');
});
test('APNs 410 invalidates stale token and prevents repeated sends', async t => {
  const { store, device } = fixture(t);
  store.observe('session-a', [event(11, 'turn/end', 'completed')], 11);
  await new NotificationWorker(store, { send: async () => ({ status: 410, reason: 'Unregistered' }) }).drain();
  assert.equal(device.push, undefined);
  assert.equal(Object.values(store.state.outbox)[0].status, 'invalid-device');
});
test('APNs JWT has an ES256 P1363 signature and correct claims', () => {
  const { privateKey, publicKey } = generateKeyPairSync('ec', { namedCurve: 'prime256v1' });
  const token = makeProviderJWT(privateKey, 'KEYID12345', 'TEAMID1234', 1700000000000);
  const [header, payload, signature] = token.split('.');
  assert.deepEqual(JSON.parse(Buffer.from(header, 'base64url')), { alg: 'ES256', kid: 'KEYID12345' });
  assert.deepEqual(JSON.parse(Buffer.from(payload, 'base64url')), { iss: 'TEAMID1234', iat: 1700000000 });
  assert.equal(Buffer.from(signature, 'base64url').length, 64);
  assert.ok(verify('sha256', Buffer.from(`${header}.${payload}`), { key: publicKey, dsaEncoding: 'ieee-p1363' }, Buffer.from(signature, 'base64url')));
});
test('transcript preserves user text, code, tools and interrupted output', () => {
  const records = [
    { event: { seq: 1, type: 'user/message', data: { content: [{ type: 'text', text: 'hello' }], source: { kind: 'user', rpcId: 'req-1' } } } },
    { event: { seq: 2, type: 'tool/call', data: { name: 'bash', callId: 'c', arguments: '{"command":"pwd"}' } } },
    { event: { seq: 3, type: 'tool/result', data: { message: { toolCallId: 'c', content: [{ type: 'text', text: '/workspace' }] } } } },
    { event: { seq: 4, type: 'assistant/message', data: { message: { content: [{ type: 'text', text: '```sh\npwd\n```' }] }, interrupted: true } } },
  ];
  const messages = projectTranscript(records, null);
  assert.equal(messages[0].requestId, 'req-1');
  assert.equal(messages[1].status, 'completed');
  assert.equal(messages[1].result, '/workspace');
  assert.equal(messages[2].interrupted, true);
});
