import fs from 'node:fs';
import path from 'node:path';
import { randomUUID } from 'node:crypto';
import WebSocket from 'ws';

const base = process.env.TEST_GATEWAY_URL || 'http://127.0.0.1:8787';
const directory = process.env.DATA_DIR || './data';
const admin = fs.readFileSync(path.join(directory, 'admin-token'), 'utf8');
async function request(route, body, token = admin, method = body ? 'POST' : 'GET') {
  const r = await fetch(base + route, { method, headers: { authorization: `Bearer ${token}`, 'content-type': 'application/json' }, ...(body ? { body: JSON.stringify(body) } : {}) });
  const value = await r.json(); if (!r.ok) throw new Error(`${route}: ${r.status} ${value.error}`); return value;
}
const { code } = await request('/admin/pair', {});
const pair = await request('/v1/pair', { code, name: 'Integration verification' });
const { token } = pair;
fs.writeFileSync(path.join(directory, 'test-device.json'), JSON.stringify(pair), { mode: 0o600 });
const status = await request('/v1/status', null, token);
console.log('Gateway status:', { connected: status.connected, error: status.error, apnsConfigured: status.apns.configured });
if (!status.connected) process.exit(2);
const models = await request('/v1/models', null, token);
console.log('Models:', models.groups.flatMap(g => g.models.map(m => `${g.id}/${m.id}`)));
const settings = await request('/v1/settings', null, token);
console.log('Settings namespaces:', settings.namespaces.map(n => n.ns));
const list = await request('/v1/sessions', null, token);
console.log('Existing conversations:', list.items.length);
if (!process.argv.includes('--send')) {
  await request(`/v1/devices/${pair.deviceId}`, null, token, 'DELETE');
  process.exit(0);
}
const sessionId = randomUUID();
await request('/v1/sessions', { sessionId, cwd: process.env.TEST_WORKSPACE || status.home }, token);
await request(`/v1/sessions/${sessionId}`, { title: 'Harness Pocket 接続検証' }, token, 'PATCH');
await request(`/v1/sessions/${sessionId}/model`, { provider: 'qwen-local', model: 'qwen3.8-flash-next' }, token);
await request('/v1/push/register', { token: 'a'.repeat(64), environment: 'sandbox' }, token);
let updates = 0;
const ws = new WebSocket(base.replace('http', 'ws') + '/v1/events', { headers: { authorization: `Bearer ${token}` } });
ws.on('message', b => { const x = JSON.parse(b); if (x.sessionId === sessionId) updates++; });
const requestId = randomUUID();
const input = { requestId, text: '接続確認です。ツールは使わず「接続OK」とだけ回答してください。', timeZone: 'Asia/Tokyo' };
await request(`/v1/sessions/${sessionId}/messages`, input, token);
await request(`/v1/sessions/${sessionId}/messages`, input, token);
let snapshot;
for (let i = 0; i < 180; i++) {
  snapshot = await request(`/v1/sessions/${sessionId}`, null, token);
  if (snapshot.endReason) break;
  await new Promise(r => setTimeout(r, 1000));
}
console.log('Live inference:', { endReason: snapshot.endReason, userMessages: snapshot.messages.filter(m => m.role === 'user').length, assistant: snapshot.messages.filter(m => m.role === 'assistant').map(m => m.text), wsUpdates: updates });
const deliveries = await request('/v1/push/deliveries', null, token);
console.log('Completion notification outbox:', deliveries.items.map(i => ({ status: i.status, lastResult: i.lastResult })));
ws.close();
await request(`/v1/devices/${pair.deviceId}`, null, token, 'DELETE');
if (snapshot.endReason !== 'completed' || snapshot.messages.filter(m => m.role === 'user').length !== 1 || deliveries.items.length !== 1) process.exitCode = 1;
