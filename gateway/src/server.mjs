import http from 'node:http';
import { randomBytes, randomUUID } from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import { WebSocketServer, WebSocket } from 'ws';
import { secureEqual, digest } from './store.mjs';
import { validateAttachments, promptContent } from './attachments.mjs';
import { sessionFrame } from './stream.mjs';

function fail(message, status = 400) { throw Object.assign(new Error(message), { status }); }
function string(value, label, max = 1000) { if (typeof value !== 'string' || !value.trim() || value.length > max) fail(`${label}を確認してください`); return value; }
async function body(req, limit = 2_000_000) {
  let size = 0; const chunks = [];
  for await (const part of req) { size += part.length; if (size > limit) fail('送信内容が大きすぎます', 413); chunks.push(part); }
  try { return chunks.length ? JSON.parse(Buffer.concat(chunks)) : {}; } catch { fail('JSONが不正です'); }
}
function json(res, value, status = 200) { res.writeHead(status, { 'content-type': 'application/json; charset=utf-8', 'cache-control': 'no-store', 'x-content-type-options': 'nosniff' }); res.end(JSON.stringify(value)); }

export function createGateway({ store, harness, apns, worker, publicURL }) {
  const adminFile = path.join(store.directory, 'admin-token');
  const adminToken = fs.existsSync(adminFile) ? fs.readFileSync(adminFile, 'utf8') : randomBytes(32).toString('base64url');
  fs.writeFileSync(adminFile, adminToken, { mode: 0o600 });
  const wss = new WebSocketServer({ noServer: true, maxPayload: 16_384 });
  const attempts = new Map(); const inFlight = new Map();
  const status = device => ({ connected: harness.ready, connection: harness.connectionStatus?.(), error: harness.lastError || null, home: harness.home || '', publicURL, apns: apns.status(), notificationsEnabled: device?.notifications ?? false, deviceRegistered: !!device?.push, protocolVersion: 1 });
  const authenticate = req => store.authenticate(req.headers.authorization?.replace(/^Bearer /, ''));
  const trust = req => {
    if (req.headers.origin && req.headers.origin !== publicURL) fail('Origin not allowed', 403);
    if (req.headers['sec-fetch-site'] === 'cross-site') fail('Cross-site request refused', 403);
  };
  const server = http.createServer(async (req, res) => {
    try {
      trust(req);
      const u = new URL(req.url, 'http://localhost'); const route = u.pathname;
      if (route === '/health' && req.method === 'GET') return json(res, { service: 'harness-pocket', protocolVersion: 1 });
      if (route === '/admin/pair' && req.method === 'POST') {
        if (!['127.0.0.1', '::1', '::ffff:127.0.0.1'].includes(req.socket.remoteAddress) || !secureEqual(req.headers.authorization, `Bearer ${adminToken}`)) fail('Unauthorized', 401);
        return json(res, { ...store.pairCode(), url: publicURL });
      }
      if (route === '/v1/pair' && req.method === 'POST') {
        const ip = req.socket.remoteAddress; const now = Date.now();
        const hits = (attempts.get(ip) || []).filter(time => now - time < 60_000);
        if (hits.length >= 10) fail('少し待ってから再試行してください', 429);
        hits.push(now); attempts.set(ip, hits);
        const input = await body(req); const pair = store.pair(input.code, input.name);
        if (!pair) fail('登録コードが無効または期限切れです', 401);
        return json(res, pair);
      }
      const device = authenticate(req); if (!device) fail('端末を登録し直してください', 401);
      if (route === '/v1/status' && req.method === 'GET') return json(res, status(device));
      if (route === '/v1/connection' && req.method === 'POST') {
        const input = await body(req, 4096);
        if (input.url) await harness.configureConnection(string(input.url, 'DSHの起動時URL', 2048));
        else harness.reconnect();
        return json(res, status(device));
      }
      if (route === '/v1/devices' && req.method === 'GET') return json(res, { devices: Object.values(store.state.devices).map(d => ({ id: d.id, name: d.name, current: d.id === device.id, createdAt: d.createdAt })) });
      if (route.startsWith('/v1/devices/') && req.method === 'DELETE') {
        const id = decodeURIComponent(route.slice('/v1/devices/'.length)); delete store.state.devices[id]; store.save();
        for (const ws of wss.clients) if (ws.deviceId === id) ws.close(1008, 'Device revoked');
        return json(res, { ok: true });
      }
      if (route === '/v1/push/register' && req.method === 'POST') {
        const input = await body(req);
        if (!/^[a-f0-9]{32,512}$/i.test(input.token) || !['sandbox', 'production'].includes(input.environment)) fail('プッシュ通知トークンが不正です');
        device.push = { token: input.token, environment: input.environment }; store.save();
        return json(res, status(device));
      }
      if (route === '/v1/push/preferences' && req.method === 'POST') {
        const input = await body(req); if (typeof input.enabled !== 'boolean') fail('Invalid preference');
        device.notifications = input.enabled; store.save(); return json(res, status(device));
      }
      if (route === '/v1/push/config' && req.method === 'POST') { const result = apns.configure(await body(req)); return json(res, result); }
      if (route === '/v1/push/test' && req.method === 'POST') {
        if (!device.push) fail('このiPhoneの通知を有効にしてください');
        if (!apns.status().configured) fail('Appleの通知キーを登録してください');
        const result = await apns.send(device.push, { id: randomUUID(), sessionId: '' }, { test: true });
        if (result.status !== 200) fail(`Apple通知エラー: ${result.reason}`, 502);
        return json(res, { ok: true });
      }
      if (route === '/v1/push/deliveries' && req.method === 'GET') return json(res, { items: Object.values(store.state.outbox).filter(n => n.deviceId === device.id).slice(-30).reverse().map(({ id, status, createdAt, lastResult }) => ({ id, status, createdAt, lastResult })) });
      if (!harness.ready) fail(harness.lastError || 'Harnessへ接続中です', 503);
      if (route === '/v1/sessions' && req.method === 'GET') return json(res, { items: await harness.refreshList() });
      if (route === '/v1/models' && req.method === 'GET') return json(res, await harness.rpc('session/modelCatalog'));
      if (route === '/v1/workspaces' && req.method === 'GET') return json(res, harness.workspaces);
      if (route === '/v1/workspaces' && req.method === 'POST') {
        const input = await body(req); return json(res, await harness.rpc('workspace/create', { request: { path: string(input.path, 'フォルダ') } }));
      }
      if (route === '/v1/directories' && req.method === 'GET') return json(res, await harness.rpc('directoryPicker/list', u.searchParams.has('path') ? { path: u.searchParams.get('path') } : {}));
      if (route === '/v1/settings' && req.method === 'GET') return json(res, await harness.rpc('settings/describe'));
      if (route === '/v1/settings' && req.method === 'PATCH') {
        const input = await body(req);
        if (!Number.isInteger(input.expectedRevision) || !Array.isArray(input.ops) || input.ops.length > 100) fail('設定を再読み込みしてください');
        return json(res, await harness.rpc('settings/mutate', { ns: string(input.ns, '設定名'), ops: input.ops, expectedRevision: input.expectedRevision }));
      }
      if (route === '/v1/credentials' && req.method === 'POST') {
        const input = await body(req); string(input.ref, 'キーの参照名');
        await harness.rpc('credentials/set', { ref: input.ref, value: string(input.value, 'APIキー', 32_000) }); return json(res, { ok: true });
      }
      if (route === '/v1/credentials' && req.method === 'DELETE') {
        const input = await body(req); await harness.rpc('credentials/unset', { ref: string(input.ref, 'キーの参照名') }); return json(res, { ok: true });
      }
      if (route === '/v1/sessions' && req.method === 'POST') {
        const input = await body(req);
        const request = { sessionId: string(input.sessionId, '会話ID', 100) };
        if (input.workspaceId) request.workspaceId = input.workspaceId;
        else request.cwd = string(input.cwd || harness.home, '作業場所');
        const result = await harness.rpc('session/create', { request });
        const snapshot = await harness.watch(result.sessionId); store.subscribe(device, result.sessionId, snapshot.cursor);
        return json(res, snapshot);
      }
      const match = route.match(/^\/v1\/sessions\/([^/]+)(?:\/(messages|cancel|model|older|fork|permissions|attachment))?$/);
      if (match) {
        const id = decodeURIComponent(match[1]); const action = match[2];
        if (req.method === 'GET' && !action) { const snapshot = await harness.watch(id); store.subscribe(device, id, snapshot.cursor); return json(res, snapshot); }
        if (req.method === 'DELETE' && !action) { await harness.rpc('workspace/archiveSession', { request: { sessionId: id } }); return json(res, { ok: true }); }
        if (req.method === 'PATCH' && !action) {
          const input = await body(req); return json(res, await harness.rpc('session/rename', { request: { sessionId: id, title: string(input.title, '名前', 500) } }));
        }
        if (req.method === 'POST' && action === 'messages') {
          const input = await body(req, 30_000_000);
          const attachments = validateAttachments(input.attachments);
          if (typeof input.text !== 'string' || input.text.length > 200_000 || (!input.text.trim() && !attachments.length)) fail('メッセージまたは添付を選んでください');
          string(input.requestId, '送信ID', 100);
          const snapshot = await harness.watch(id); store.subscribe(device, id, snapshot.cursor);
          const submissionKey = digest(`${id}:${input.requestId}`);
          const contentHash = digest(attachments.length ? JSON.stringify([input.text, attachments]) : input.text);
          const existing = store.state.submissions[submissionKey];
          if (existing && existing.contentHash !== contentHash) fail('同じ送信IDで内容を変更できません', 409);
          if (existing?.status === 'accepted') return json(res, { accepted: true });
          if (inFlight.has(submissionKey)) { await inFlight.get(submissionKey); return json(res, { accepted: true }); }
          if (existing && existing.status !== 'preparing') {
            const logged = harness.sessions.get(id)?.records.some(r => r.event.type === 'user/message' && r.event.data.source?.rpcId === input.requestId);
            const queued = harness.queues[id]?.some(item => item.rpcId === input.requestId);
            if (logged || queued) { existing.status = 'accepted'; store.save(); return json(res, { accepted: true }); }
            fail('送信の受理状態を確認できません。会話を更新して回答を確認してください。二重実行を防ぐため自動再送は停止しました。', 409);
          }
          store.state.submissions[submissionKey] = { contentHash, sessionId: id, requestId: input.requestId, originalText: input.text, status: 'preparing', createdAt: Date.now() }; store.save();
          const sending = (async () => {
            const content = await promptContent(harness, id, input.text, attachments);
            store.state.submissions[submissionKey].files = content.files;
            store.state.submissions[submissionKey].status = 'sending'; store.save();
            try {
              await harness.rpc('session/prompt', { request: { sessionId: id, requestId: input.requestId, mode: 'queue', content, clientTimeZone: input.timeZone || 'Asia/Tokyo' } });
            } catch (error) {
              if (error.code === 'session/attachment-invalid') { delete store.state.submissions[submissionKey]; store.save(); }
              throw error;
            }
            store.state.submissions[submissionKey].status = 'accepted'; store.save();
          })();
          inFlight.set(submissionKey, sending);
          try { await sending; } finally { inFlight.delete(submissionKey); }
          return json(res, { accepted: true });
        }
        if (req.method === 'GET' && action === 'attachment') return json(res, await harness.rpc('session/attachment', { request: { sessionId: id, attachmentId: string(u.searchParams.get('id'), '添付ID') } }));
        if (req.method === 'POST' && action === 'permissions') {
          const input = await body(req); const snapshot = await harness.watch(id);
          const preset = string(input.preset, '権限');
          if (preset === 'custom' || !snapshot.permissions?.options?.some(option => option.value === preset)) fail('現在選択できる権限ではありません');
          const result = await harness.rpc('commands/execute', { agentId: id, line: `/permission ${preset}`, images: [] });
          if (result?.result?.kind !== 'success') fail(result?.result?.text || '権限を変更できませんでした');
          return json(res, { ok: true });
        }
        if (req.method === 'POST' && action === 'cancel') return json(res, await harness.rpc('session/cancel', { request: { sessionId: id } }));
        if (req.method === 'POST' && action === 'model') {
          const input = await body(req); const request = { sessionId: id, provider: string(input.provider, 'プロバイダ'), model: string(input.model, 'モデル') };
          if (input.reasoningEffort) request.reasoningEffort = input.reasoningEffort;
          return json(res, await harness.rpc('session/selectModel', { request }));
        }
        if (req.method === 'POST' && action === 'older') return json(res, await harness.older(id));
        if (req.method === 'POST' && action === 'fork') {
          const input = await body(req); const request = { sessionId: id }; if (Number.isInteger(input.atSeq)) request.atSeq = input.atSeq;
          const result = await harness.rpc('session/fork', { request }); return json(res, await harness.watch(result.sessionId));
        }
      }
      if (route.startsWith('/v1/approvals/') && req.method === 'POST') { const input = await body(req); await harness.answer(decodeURIComponent(route.slice('/v1/approvals/'.length)), input.answer); return json(res, { ok: true }); }
      fail('Not found', 404);
    } catch (error) { json(res, { error: error.message, code: error.code }, error.status || (error.code === 'settings/conflict' ? 409 : 400)); }
  });
  const sendSnapshot = (ws, snapshot) => {
    const frame = ws.focusedMode ? sessionFrame(snapshot, ws.lastSnapshot) : { type: 'session', sessionId: snapshot.id, snapshot };
    if (ws.bufferedAmount > 1_000_000) { ws.close(1013, 'Reconnect to resync'); return; }
    ws.send(JSON.stringify(frame));
    if (ws.focusedMode) ws.lastSnapshot = snapshot;
  };
  server.on('upgrade', (req, socket, head) => {
    try {
      trust(req);
      const device = authenticate(req);
      if (req.url !== '/v1/events' || !device) { socket.end('HTTP/1.1 401 Unauthorized\r\n\r\n'); return; }
      wss.handleUpgrade(req, socket, head, ws => {
        ws.deviceId = device.id; ws.alive = true; ws.summaries = new Map();
        ws.on('pong', () => { ws.alive = true; }); ws.on('error', () => {});
        ws.on('message', data => {
          try {
            const message = JSON.parse(data);
            if (message.type !== 'focus' || !(message.sessionId === null || (typeof message.sessionId === 'string' && message.sessionId.length <= 200))) return;
            ws.focusedMode = true; ws.focusedSession = message.sessionId; ws.lastSnapshot = null;
            if (harness.sessions.get(message.sessionId)?.loaded) sendSnapshot(ws, harness.snapshot(message.sessionId));
          } catch { ws.close(1008, 'Invalid focus request'); }
        });
        ws.send(JSON.stringify({ type: 'ready', status: status(device) }));
      });
    } catch { socket.end('HTTP/1.1 403 Forbidden\r\n\r\n'); }
  });
  let pending = new Map(); let flushTimer;
  const changed = event => {
    pending.set(event.sessionId || event.type, event);
    if (flushTimer) return;
    flushTimer = setTimeout(() => {
      for (const event of pending.values()) for (const ws of wss.clients) if (ws.readyState === WebSocket.OPEN) {
        if (event.sessionId && harness.sessions.get(event.sessionId)?.loaded) {
          if (!ws.focusedMode || ws.focusedSession === event.sessionId) sendSnapshot(ws, harness.snapshot(event.sessionId));
          else {
            const session = harness.sessions.get(event.sessionId);
            const summary = { type: 'sessionSummary', sessionId: event.sessionId, title: session.title || '新しいチャット', running: !!session.running };
            const encoded = JSON.stringify(summary);
            if (ws.summaries.get(event.sessionId) !== encoded) { ws.send(encoded); ws.summaries.set(event.sessionId, encoded); }
          }
        } else ws.send(JSON.stringify(event));
      }
      pending.clear(); flushTimer = null; void worker.drain();
    }, 250);
  };
  harness.on('changed', changed);
  harness.on('status', () => { for (const ws of wss.clients) if (ws.readyState === WebSocket.OPEN) ws.send(JSON.stringify({ type: 'status', status: status(store.state.devices[ws.deviceId]) })); });
  const interval = setInterval(() => { void worker.drain(); for (const ws of wss.clients) { if (!ws.alive) { ws.terminate(); continue; } ws.alive = false; ws.ping(); } }, 20_000);
  server.on('close', () => { clearInterval(interval); clearTimeout(flushTimer); for (const ws of wss.clients) ws.terminate(); wss.close(); });
  return server;
}
