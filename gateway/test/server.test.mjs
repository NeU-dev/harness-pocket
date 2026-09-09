import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { EventEmitter, once } from 'node:events';
import { Store } from '../src/store.mjs';
import { createGateway } from '../src/server.mjs';
import { WebSocket } from 'ws';

async function setup(t) {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'pocket-http-test-'));
  const store = new Store(directory);
  const paired = store.pair(store.pairCode().code, 'Test iPhone');
  const harness = Object.assign(new EventEmitter(), { ready: true, home: '/workspace', sessions: new Map([['s', { records: [], loaded: true }]]), queues: {}, watch: async () => ({ cursor: 10 }), rpc: async () => ({ accepted: true }) });
  const server = createGateway({ store, harness, apns: { status: () => ({ configured: false }) }, worker: { drain: async () => {} }, publicURL: 'https://spark.example' });
  server.listen(0, '127.0.0.1'); await once(server, 'listening');
  t.after(async () => { server.closeAllConnections(); await new Promise(r => server.close(r)); fs.rmSync(directory, { recursive: true, force: true }); });
  const base = `http://127.0.0.1:${server.address().port}`;
  const post = (route, body, headers = {}) => fetch(base + route, { method: 'POST', headers: { 'content-type': 'application/json', authorization: `Bearer ${paired.token}`, ...headers }, body: JSON.stringify(body) });
  return { store, harness, paired, base, post, server };
}
test('concurrent and later retries cause exactly one upstream submission', async t => {
  const { harness, post } = await setup(t);
  let prompts = 0;
  harness.rpc = async endpoint => { if (endpoint === 'session/prompt') { prompts++; await new Promise(r => setTimeout(r, 30)); } return { accepted: true }; };
  const body = { text: 'Hello', requestId: 'same-id' };
  const responses = await Promise.all([post('/v1/sessions/s/messages', body), post('/v1/sessions/s/messages', body)]);
  assert.deepEqual(responses.map(r => r.status), [200, 200]);
  assert.equal((await post('/v1/sessions/s/messages', body)).status, 200);
  assert.equal(prompts, 1);
  assert.equal((await post('/v1/sessions/s/messages', { ...body, text: 'different' })).status, 409);
});

test('focused sockets coalesce bursts, patch only the selected session and retain legacy compatibility', async t => {
  const { harness, paired, base, server } = await setup(t);
  const connect = async () => {
    const ws = new WebSocket(base.replace('http:', 'ws:') + '/v1/events', { headers: { authorization: `Bearer ${paired.token}` } });
    const frames = [];
    ws.on('message', data => frames.push(JSON.parse(data)));
    await once(ws, 'open');
    return { ws, frames };
  };
  let text = 'initial';
  harness.snapshot = id => ({ id, running: true, messages: [{ id: 'history', text: 'h'.repeat(20_000) }, { id: 'live', text }] });
  harness.sessions.set('other', { loaded: true, title: 'Other', running: true });
  const focused = await connect(), legacy = await connect();
  t.after(() => { focused.ws.terminate(); legacy.ws.terminate(); server.close(); });
  const wait = () => new Promise(resolve => setTimeout(resolve, 350));
  focused.ws.send(JSON.stringify({ type: 'focus', sessionId: 's' }));
  await wait();
  assert.equal(focused.frames.at(-1).type, 'session');
  for (let i = 0; i < 100; i++) { text = `chunk ${i}`; harness.emit('changed', { type: 'session', sessionId: 's' }); }
  await wait();
  assert.equal(focused.frames.filter(f => f.type === 'sessionDelta').length, 1);
  assert.deepEqual(focused.frames.at(-1).messages, [{ id: 'live', text: 'chunk 99' }]);
  assert.equal(legacy.frames.at(-1).snapshot.messages.length, 2);
  harness.emit('changed', { type: 'session', sessionId: 'other' }); await wait();
  assert.equal(focused.frames.at(-1).type, 'sessionSummary');
  const count = focused.frames.length;
  harness.emit('changed', { type: 'session', sessionId: 'other' }); await wait();
  assert.equal(focused.frames.length, count);
  focused.ws.send(JSON.stringify({ type: 'focus', sessionId: null })); await wait();
  harness.emit('changed', { type: 'session', sessionId: 's' }); await wait();
  assert.equal(focused.frames.at(-1).type, 'sessionSummary');
  focused.ws.send(JSON.stringify({ type: 'focus', sessionId: 's' })); await wait();
  assert.equal(focused.frames.at(-1).type, 'session');
  focused.ws.terminate(); legacy.ws.terminate();
});
test('unknown acceptance after a crash fails closed instead of blindly resending', async t => {
  const { harness, post } = await setup(t);
  let calls = 0;
  harness.rpc = async () => { calls++; throw new Error('timeout'); };
  assert.equal((await post('/v1/sessions/s/messages', { text: 'Hello', requestId: 'id' })).status, 400);
  assert.equal((await post('/v1/sessions/s/messages', { text: 'Hello', requestId: 'id' })).status, 409);
  assert.equal(calls, 1);
});
test('reject unauthenticated and cross-site requests; revocation works immediately', async t => {
  const { paired, base, post } = await setup(t);
  assert.equal((await fetch(base + '/v1/status')).status, 401);
  assert.equal((await post('/v1/push/preferences', { enabled: true }, { origin: 'https://evil.example' })).status, 403);
  const headers = { authorization: `Bearer ${paired.token}` };
  assert.equal((await fetch(base + `/v1/devices/${paired.deviceId}`, { method: 'DELETE', headers })).status, 200);
  assert.equal((await fetch(base + '/v1/status', { headers })).status, 401);
});

test('connection recovery remains available while DSH is down and requires device authentication', async t => {
  const { harness, base, post } = await setup(t);
  harness.ready = false; let retries = 0;
  harness.reconnect = () => { retries++; };
  harness.configureConnection = async url => { assert.equal(url, 'http://localhost:8080/?token=test'); };
  harness.connectionStatus = () => ({ url: 'http://localhost:8080', automatic: true, connected: false });
  assert.equal((await fetch(base + '/v1/connection', { method: 'POST' })).status, 401);
  const response = await post('/v1/connection', {});
  assert.equal(response.status, 200); assert.equal(retries, 1);
  assert.equal((await response.json()).connection.automatic, true);
  assert.equal((await post('/v1/connection', { url: 'http://localhost:8080/?token=test' })).status, 200);
});

test('image and file-only messages preserve order and deduplicate file uploads', async t => {
  const { harness, post } = await setup(t);
  let uploads = 0, content;
  harness.uploadFile = async (_id, item) => { uploads++; assert.equal(item.name, '日本語 + test.txt'); return { receiptId: 'receipt-1' }; };
  harness.rpc = async (_endpoint, args) => { content = args.request.content; return { accepted: true }; };
  const body = { text: '', requestId: 'attachments', attachments: [{ kind: 'image', name: 'image.png', mediaType: 'image/png', data: 'YWJj' }, { kind: 'file', name: '日本語 + test.txt', data: 'ZmlsZQ==' }] };
  assert.equal((await post('/v1/sessions/s/messages', body)).status, 200);
  assert.deepEqual(content.map(x => x.type), ['image', 'file']);
  assert.equal(content[1].receiptId, 'receipt-1');
  assert.equal((await post('/v1/sessions/s/messages', body)).status, 200);
  assert.equal(uploads, 1);
  body.attachments[1].data = 'b3RoZXI=';
  assert.equal((await post('/v1/sessions/s/messages', body)).status, 409);
});
test('failed file preparation can retry, but never resends an uncertain prompt', async t => {
  const { harness, post } = await setup(t);
  let uploads = 0, prompts = 0;
  harness.uploadFile = async () => { if (++uploads === 1) throw new Error('temporary upload failure'); return { receiptId: 'r' }; };
  harness.rpc = async () => { prompts++; return { accepted: true }; };
  const body = { text: '', requestId: 'retry-file', attachments: [{ kind: 'file', name: 'file.txt', data: 'YQ==' }] };
  assert.equal((await post('/v1/sessions/s/messages', body)).status, 400);
  assert.equal(prompts, 0);
  assert.equal((await post('/v1/sessions/s/messages', body)).status, 200);
  assert.equal(prompts, 1);
});
test('permission changes only accept advertised presets', async t => {
  const { harness, post } = await setup(t);
  harness.watch = async () => ({ permissions: { options: [{ value: 'read-only' }] } });
  harness.rpc = async (endpoint, args) => { assert.equal(endpoint, 'commands/execute'); assert.equal(args.line, '/permission read-only'); return { result: { kind: 'success' } }; };
  assert.equal((await post('/v1/sessions/s/permissions', { preset: 'danger-full-access' })).status, 400);
  assert.equal((await post('/v1/sessions/s/permissions', { preset: 'read-only' })).status, 200);
});
test('legacy Harness file handoff stores metadata and passes only its generated path', async t => {
  const { harness, post, store } = await setup(t);
  harness.uploadFile = async () => ({ path: '/data/uploads/opaque/report.txt', file: { attachmentId: 'opaque', name: 'report.txt', bytes: 1 } });
  harness.rpc = async (_endpoint, args) => { assert.match(args.request.content[1].text, /\/data\/uploads\/opaque\/report.txt/); return { accepted: true }; };
  assert.equal((await post('/v1/sessions/s/messages', { text: 'Read this', requestId: 'legacy', attachments: [{ kind: 'file', name: 'report.txt', data: 'YQ==' }] })).status, 200);
  const item = Object.values(store.state.submissions)[0];
  assert.equal(item.originalText, 'Read this'); assert.equal(item.files[0].name, 'report.txt');
});
test('explicit attachment rejection permits correction with the same request ID', async t => {
  const { harness, post } = await setup(t);
  let count = 0;
  harness.rpc = async () => { if (++count === 1) throw Object.assign(new Error('unsupported image'), { code: 'session/attachment-invalid' }); return { accepted: true }; };
  const body = { text: 'test', requestId: 'rejected-image', attachments: [{ kind: 'image', mediaType: 'image/png', name: 'a.png', data: 'YQ==' }] };
  assert.equal((await post('/v1/sessions/s/messages', body)).status, 400);
  assert.equal((await post('/v1/sessions/s/messages', { ...body, attachments: [] })).status, 200);
});
