import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import http from 'node:http';
import { once } from 'node:events';
import { WebSocketServer } from 'ws';
import { Harness } from '../src/harness.mjs';
import { Store } from '../src/store.mjs';
import { localConnection, readPrivateConnection } from '../src/connection.mjs';

const token = 'test-launch-token-0123456789';
async function until(check) {
  for (let i = 0; i < 150; i++) { if (check()) return; await new Promise(r => setTimeout(r, 20)); }
  assert.fail('connection did not reach expected state');
}
function directory(t) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'pocket-connection-'));
  t.after(() => fs.rmSync(dir, { recursive: true, force: true })); return dir;
}
async function upstream(t, secret) {
  let logins = 0; const eventStreams = [];
  const server = http.createServer(async (req, res) => {
    if (req.method === 'GET') {
      if (new URL(req.url, 'http://localhost').searchParams.get('token') !== secret) { res.writeHead(401); res.end(); return; }
      logins++; res.writeHead(302, { 'set-cookie': `dsh=${secret}; HttpOnly`, location: '/' }); res.end(); return;
    }
    const chunks = []; for await (const b of req) chunks.push(b);
    const msg = JSON.parse(Buffer.concat(chunks));
    res.setHeader('content-type', 'application/json');
    res.end(JSON.stringify({ type: 'server-response', rpcId: msg.rpcId, result: { ok: true, value: msg.method === 'session/list' ? { items: [] } : {} } }));
  });
  const wss = new WebSocketServer({ server, path: '/api/remote.mux' });
  wss.on('connection', (ws, req) => {
    assert.equal(req.headers.cookie, `dsh=${secret}`);
    ws.on('message', bytes => {
      const msg = JSON.parse(bytes);
      const send = value => ws.send(JSON.stringify({ type: 'item', streamId: msg.streamId, value }));
      if (msg.endpoint === '$events') { eventStreams.push(send); send({ type: 'ready', clientId: 'client', host: { home: '/home/test' } }); }
      if (msg.endpoint === 'workspace/follow') send({ type: 'baseline', value: { items: [], archivedSessionIds: [] } });
      if (msg.endpoint === 'session/control') send({ type: 'baseline', value: { queues: {} } });
      if (msg.endpoint === 'session/follow') send({ type: 'snapshot', cursor: 10, records: [], header: { cwd: '/home/test' }, projections: { values: {} } });
    });
  });
  server.listen(0, '127.0.0.1'); await once(server, 'listening');
  t.after(async () => { for (const ws of wss.clients) ws.terminate(); server.closeAllConnections(); await new Promise(r => server.close(r)); });
  return { url: `http://127.0.0.1:${server.address().port}`, emit: value => eventStreams.at(-1)(value), disconnect: () => { for (const ws of wss.clients) ws.terminate(); }, get logins() { return logins; } };
}

test('runtime connection accepts only private owned loopback records with a living process', t => {
  const dir = directory(t), file = path.join(dir, 'runtime.json');
  const record = { version: 1, pid: process.pid, url: 'http://127.0.0.1:8080', token };
  fs.writeFileSync(file, JSON.stringify(record), { mode: 0o600 });
  assert.deepEqual(readPrivateConnection(file, { runtime: true }), { url: record.url, token });
  fs.chmodSync(file, 0o644); assert.equal(readPrivateConnection(file, { runtime: true }), null);
  fs.chmodSync(file, 0o600);
  fs.symlinkSync(file, path.join(dir, 'symlink')); assert.equal(readPrivateConnection(path.join(dir, 'symlink')), null);
  fs.writeFileSync(file, JSON.stringify({ ...record, pid: 2147483647 })); assert.equal(readPrivateConnection(file, { runtime: true }), null);
  for (const url of ['https://example.com', 'http://192.168.1.2', 'http://localhost/path', 'http://localhost/?other=x', 'http://user:pass@localhost', 'http://localhost/?token=x']) assert.throws(() => localConnection(url));
  assert.deepEqual(localConnection(`http://localhost:8080/?token=${token}`), { url: 'http://localhost:8080', token });
});

test('new DSH port and token reconnect automatically, restoring watches and question handling', async t => {
  const dir = directory(t), store = new Store(dir);
  const pair = store.pair(store.pairCode().code, 'iPhone'), device = store.authenticate(pair.token);
  device.push = { token: 'a'.repeat(64), environment: 'sandbox' }; store.subscribe(device, 'session-a', 10);
  const first = await upstream(t, token), second = await upstream(t, token + '-new');
  const record = (url, secret) => fs.writeFileSync(path.join(dir, 'dsh-runtime.json'), JSON.stringify({ version: 1, pid: process.pid, url, token: secret }), { mode: 0o600 });
  record(first.url, token);
  const harness = new Harness({ url: 'http://127.0.0.1:1', token: 'obsolete', store });
  t.after(() => harness.stop()); harness.start();
  await until(() => harness.ready && harness.sessions.get('session-a')?.loaded);
  assert.equal(first.logins, 1);
  record(second.url, token + '-new'); first.disconnect();
  await until(() => harness.ready && harness.url.origin === second.url && harness.sessions.get('session-a')?.loaded);
  assert.equal(second.logins, 1);
  assert.equal(harness.connectionStatus().automatic, true);
  assert.ok(!JSON.stringify(harness.connectionStatus()).includes(token));
  assert.ok(store.authenticate(pair.token), 'existing iPhone stays paired');
  second.emit({ type: 'waterfall', event: 'user-questions/request', eventId: 'q-1', agentId: 'session-a', request: { questions: [] } });
  await until(() => harness.pending.has('q-1'));
  assert.equal(Object.values(store.state.outbox)[0].kind, 'question');
  await harness.answer('q-1', { answers: [] });
  assert.equal(Object.values(store.state.outbox)[0].status, 'cancelled');
  second.emit({ type: 'waterfall', event: 'user-questions/request', eventId: 'q-2', agentId: 'session-a', request: { questions: [] } });
  await until(() => harness.pending.has('q-2'));
  const changes = []; harness.on('changed', v => changes.push(v));
  second.emit({ type: 'cancel', eventId: 'q-2' });
  await until(() => !harness.pending.has('q-2'));
  assert.ok(changes.some(v => v.sessionId === 'session-a'));
  assert.equal(Object.values(store.state.outbox)[1].status, 'cancelled');
  harness.stop();
});

test('manual repair validates authentication before persisting and restarting', async t => {
  const dir = directory(t), store = new Store(dir), server = await upstream(t, token);
  const harness = new Harness({ url: 'http://localhost:1', token: 'obsolete', store });
  t.after(() => harness.stop());
  await assert.rejects(harness.configureConnection(`${server.url}/?token=wrong-token-1234567890`));
  assert.equal(fs.existsSync(harness.configFile), false);
  await harness.configureConnection(`${server.url}/?token=${token}`);
  await until(() => harness.ready);
  assert.equal(fs.statSync(harness.configFile).mode & 0o777, 0o600);
  assert.equal(harness.connectionStatus().automatic, false);
  harness.stop();
});
