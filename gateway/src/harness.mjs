import { EventEmitter } from 'node:events';
import { randomUUID } from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import WebSocket from 'ws';
import { restoreLive, applyLiveFrame, projectTranscript } from './transcript.mjs';
import { readPrivateConnection, localConnection, exchangeLaunchToken } from './connection.mjs';

export class Harness extends EventEmitter {
  constructor({ url, token, store }) {
    super();
    this.url = new URL(url);
    if (!['127.0.0.1', 'localhost', '[::1]'].includes(this.url.hostname)) throw new Error('DSH_URL must point to a loopback Harness');
    this.token = token;
    this.store = store;
    this.cookieFile = path.join(store.directory, 'upstream-cookie.json');
    this.runtimeFile = path.join(store.directory, 'dsh-runtime.json');
    this.configFile = path.join(store.directory, 'upstream-config.json');
    this.refreshConnection();
    if (fs.existsSync(this.cookieFile)) {
      const saved = JSON.parse(fs.readFileSync(this.cookieFile, 'utf8'));
      if (saved.origin === this.url.origin) this.cookie = saved.cookie;
    }
    this.sessions = new Map(); this.streams = new Map(); this.pending = new Map();
    this.workspaces = { items: [], archivedSessionIds: [] }; this.queues = {};
    this.ready = false; this.closed = false; this.retry = 0;
    this.generation = 0;
  }
  async login() {
    if (this.cookie) return;
    if (!this.token) throw new Error('Harnessの起動時トークンが必要です');
    const origin = this.url.origin, token = this.token;
    const cookie = await exchangeLaunchToken(origin, token);
    if (origin !== this.url.origin || token !== this.token) return;
    this.cookie = cookie;
    fs.writeFileSync(this.cookieFile, JSON.stringify({ origin: this.url.origin, cookie: this.cookie }), { mode: 0o600 });
  }
  refreshConnection() {
    const runtime = readPrivateConnection(this.runtimeFile, { runtime: true });
    const current = runtime || readPrivateConnection(this.configFile);
    this.automaticConnection = !!runtime;
    if (current && (this.url.origin !== current.url || this.token !== current.token)) {
      this.url = new URL(current.url); this.token = current.token; this.cookie = null;
    }
  }
  connectionStatus() { return { url: this.url.origin, automatic: !!this.automaticConnection, connected: this.ready }; }
  async configureConnection(value) {
    const config = localConnection(value);
    const runtime = readPrivateConnection(this.runtimeFile, { runtime: true });
    if (runtime && (runtime.url !== config.url || runtime.token !== config.token)) throw new Error('DSHとの自動連携が有効です。「再接続」を試してください');
    const cookie = await exchangeLaunchToken(config.url, config.token);
    fs.writeFileSync(this.configFile, JSON.stringify(config), { mode: 0o600 });
    this.stop(); this.url = new URL(config.url); this.token = config.token; this.cookie = cookie;
    fs.writeFileSync(this.cookieFile, JSON.stringify({ origin: config.url, cookie }), { mode: 0o600 });
    this.start(); return this.connectionStatus();
  }
  reconnect() { this.cookie = null; this.socket?.terminate(); if (!this.socket || this.socket.readyState === WebSocket.CLOSED) { clearTimeout(this.retryTimer); void this.connect(); } }
  async rpc(endpoint, args = {}, { raw = false } = {}) {
    await this.login();
    const rpcId = randomUUID();
    const payload = raw ? args : { args };
    const response = await fetch(new URL(`/api/${endpoint}`, this.url), {
      method: 'POST', headers: { 'Content-Type': 'application/json', Cookie: this.cookie },
      body: JSON.stringify({ type: 'client-request', rpcId, method: endpoint, payload }), signal: AbortSignal.timeout(30_000),
    });
    if (response.status === 401) { this.cookie = null; throw new Error('Harnessの認証期限が切れました。再接続してください'); }
    if (!response.ok) throw new Error(`Harness HTTP ${response.status}`);
    const message = await response.json();
    if (message.type !== 'server-response' || message.rpcId !== rpcId) throw new Error('Harness応答形式が対応バージョンと異なります');
    if (!message.result?.ok) throw Object.assign(new Error(message.result?.error?.message || 'Harness request failed'), { code: message.result?.error?.code });
    return message.result.value;
  }
  async uploadFile(sessionId, attachment) {
    const id = randomUUID();
    const directory = path.join(this.store.directory, 'uploads', id);
    fs.mkdirSync(directory, { recursive: true, mode: 0o700 });
    const name = path.basename(attachment.name).replace(/[\x00-\x1f\x7f]/g, '_').replace(/^\.+$/, '_') || 'attachment';
    const filePath = path.join(directory, name);
    const data = Buffer.from(attachment.data, 'base64');
    fs.writeFileSync(filePath, data, { mode: 0o600, flag: 'wx' });
    return { path: filePath, file: { attachmentId: id, name, bytes: data.length } };
  }
  start() { this.closed = false; this.store.questionConnectionLost?.(); void this.connect(); }
  stop() { this.closed = true; this.generation++; clearTimeout(this.retryTimer); clearTimeout(this.handshakeTimer); this.socket?.terminate(); }
  async connect() {
    if (this.closed) return;
    clearTimeout(this.retryTimer);
    const generation = ++this.generation;
    this.ready = false; this.emit('status');
    try {
      this.refreshConnection();
      await this.login();
      if (this.closed || generation !== this.generation) return;
      const url = new URL('/api/remote.mux', this.url); url.protocol = 'ws:';
      const ws = new WebSocket(url, { headers: { Cookie: this.cookie }, handshakeTimeout: 10_000, maxPayload: 32 * 1024 * 1024 });
      this.socket = ws; this.streams.clear(); this.pending.clear();
      for (const s of this.sessions.values()) { s.streamId = null; s.loaded = false; s.live = null; }
      ws.on('open', () => {
        if (this.closed || generation !== this.generation) { ws.terminate(); return; }
        this.openStream('$events', {}, async value => {
          if (value.type === 'ready') {
            clearTimeout(this.handshakeTimer); this.clientId = value.clientId; this.home = value.host.home;
            this.ready = true; this.retry = 0; this.lastError = null; this.emit('status');
            this.openStream('workspace/follow', {}, value => {
              if (value.type === 'baseline') this.workspaces = value.value;
              else if (value.type === 'upsert') this.workspaces.items = [...this.workspaces.items.filter(w => w.workspaceId !== value.workspace.workspaceId), value.workspace];
              else if (value.type === 'remove') this.workspaces.items = this.workspaces.items.filter(w => w.workspaceId !== value.workspaceId);
              else if (value.type === 'archived') this.workspaces.archivedSessionIds = value.archivedSessionIds;
              this.emit('changed', { type: 'workspaces' });
            });
            this.openStream('session/control', {}, frame => {
              if (frame.type === 'baseline') this.queues = frame.value.queues;
              if (frame.type === 'queue') this.queues[frame.sessionId] = frame.items;
            });
            await this.refreshList();
            for (const sessionId of Object.keys(this.store.state.watches)) this.follow(sessionId);
          } else if (value.type === 'waterfall') {
            if (['approval/request', 'user-questions/request'].includes(value.event)) {
              this.pending.set(value.eventId, value);
              if (value.event === 'user-questions/request') this.store.questionAsked(value.agentId, value.eventId);
              this.emit('changed', { type: 'approval', sessionId: value.agentId });
            }
          } else if (value.type === 'cancel') {
            const sessionId = this.pending.get(value.eventId)?.agentId;
            this.pending.delete(value.eventId); this.store.questionResolved(value.eventId);
            this.emit('changed', { type: 'approval', sessionId });
          }
          else if (value.type === 'emit') {
            const [id, arg] = value.args;
            if (value.event === 'api-session/status') {
              const s = this.sessions.get(id); if (s) s.running = arg;
            } else if (value.event === 'api-session/error') { const s = this.sessions.get(id); if (s) s.error = arg; }
            if (value.event.startsWith('api-session/')) this.emit('changed', { type: 'sessions', sessionId: typeof id === 'string' ? id : id?.sessionId });
          }
        });
        this.handshakeTimer = setTimeout(() => ws.terminate(), 15_000);
      });
      ws.on('message', bytes => {
        if (this.socket !== ws) return;
        let message; try { message = JSON.parse(bytes); } catch { this.lastError = 'Invalid Harness stream'; ws.terminate(); return; }
        const stream = this.streams.get(message.streamId);
        if (!stream) return;
        if (message.type === 'item') {
          stream.queue = stream.queue.then(() => stream.onValue(message.value)).catch(error => { this.lastError = error.message; ws.terminate(); });
        } else {
          const error = message.error?.message || 'Harness stream ended';
          this.streams.delete(message.streamId);
          let handled = false;
          try { handled = stream.onEnd?.(error, message.error) === true; } catch {}
          if (!handled) { this.lastError = error; ws.terminate(); }
        }
      });
      ws.on('error', () => { this.lastError ||= 'DGXのHarnessに接続できません'; });
      ws.on('unexpected-response', (_request, response) => {
        if (response.statusCode === 401) this.cookie = null;
        this.lastError = `Harness WebSocket HTTP ${response.statusCode}`;
        response.resume(); ws.terminate();
      });
      ws.on('close', () => { if (this.socket === ws && generation === this.generation) this.scheduleReconnect(); });
    } catch (error) { if (!this.closed && generation === this.generation) { this.lastError = error.message; this.scheduleReconnect(); } }
  }
  scheduleReconnect() {
    this.ready = false; this.emit('status'); clearTimeout(this.handshakeTimer);
    for (const s of this.sessions.values()) { s.streamId = null; s.loaded = false; }
    this.pending.clear();
    this.store.questionConnectionLost?.();
    if (!this.closed) this.retryTimer = setTimeout(() => void this.connect(), Math.min(10_000, 500 * 2 ** this.retry++));
  }
  openStream(endpoint, args, onValue, onEnd) {
    const streamId = randomUUID(); this.streams.set(streamId, { onValue, onEnd, queue: Promise.resolve() });
    this.socket.send(JSON.stringify({ type: 'open', streamId, endpoint, payload: { args } }));
    return streamId;
  }
  async refreshList() {
    const { items } = await this.rpc('session/list', { _request: {} });
    for (const summary of items) {
      const s = this.sessions.get(summary.sessionId) || { records: [], loaded: false };
      Object.assign(s, summary);
      this.sessions.set(summary.sessionId, s);
    }
    return this.list();
  }
  list() {
    return [...this.sessions.values()].filter(s => !s.origin && !this.workspaces.archivedSessionIds.includes(s.sessionId)).map(s => ({
      id: s.sessionId, title: s.title || s.projections?.values?.title || '新しいチャット', updatedAt: s.updatedAt || 0, running: !!s.running, cwd: s.cwd || '',
    })).sort((a, b) => b.updatedAt - a.updatedAt);
  }
  follow(sessionId) {
    if (!this.ready) throw new Error('Harnessへ接続中です');
    const s = this.sessions.get(sessionId) || { sessionId, records: [], loaded: false };
    this.sessions.set(sessionId, s);
    if (s.streamId) return;
    s.streamId = this.openStream('session/follow', { request: { address: { kind: 'session', sessionId }, maxMessages: 80, assistantStream: true } }, async value => {
      if (value.type === 'snapshot') {
        const oldCursor = this.store.state.watches[sessionId]?.cursor;
        let catchup = [...value.records];
        if (oldCursor !== undefined && value.cursor > oldCursor) {
          let first = catchup[0]?.event.seq ?? value.cursor + 1;
          while (first > oldCursor + 1) {
            const page = await this.rpc('session/page', { request: { address: { kind: 'session', sessionId }, throughSeq: value.cursor, beforeSeq: first, maxMessages: 200 } });
            if (!page.records.length || page.records[0].event.seq >= first) throw new Error('履歴の欠番を復元できません');
            catchup = [...page.records, ...catchup]; first = page.records[0].event.seq;
          }
        }
        this.store.observe(sessionId, catchup.map(r => r.event), value.cursor, { baseline: oldCursor === undefined });
        s.records = value.records; s.cursor = value.cursor; s.hasMore = value.hasMore; s.projections = value.projections;
        s.title = value.projections.values.title || s.title; s.cwd = value.header.cwd; s.loaded = true;
        const active = value.assistantStream?.activeAttempt;
        s.live = restoreLive(active);
      } else if (value.type === 'event') {
        const event = value.event;
        if (event.seq <= s.cursor) return;
        if (event.seq !== s.cursor + 1) throw new Error('履歴の連続性を修復しています');
        s.records.push(value); s.cursor = event.seq;
        if (event.type === 'session/title') s.title = event.data.title;
        if (event.type === 'permission/preset' && s.projections?.values?.permissions) s.projections.values.permissions.currentValue = event.data.preset;
        if (event.type === 'turn/start') { s.running = true; s.error = null; }
        if (event.type === 'user/message') s.updatedAt = event.time;
        if (event.type === 'turn/end') { s.running = false; s.endReason = event.data.reason.kind; if (s.endReason === 'error') s.error = event.data.reason.error?.message; }
        if (event.type === 'assistant/message' || event.type === 'assistant/attempt') s.live = null;
        this.store.observe(sessionId, [event], s.cursor);
      } else if (value.type === 'assistant-stream') {
        s.live = applyLiveFrame(s.live, value.frame);
      }
      this.emit('changed', { type: 'session', sessionId });
    }, error => {
      s.streamId = null;
      if (!/^session\s+["'].*["']\s+not found$/i.test(error)) return false;
      this.sessions.delete(sessionId);
      this.store.forgetSession(sessionId);
      this.emit('changed', { type: 'sessions', sessionId });
      return true;
    });
  }
  async watch(sessionId) {
    this.follow(sessionId);
    const until = Date.now() + 15_000;
    while (!this.sessions.get(sessionId)?.loaded) {
      if (!this.ready || Date.now() > until) throw new Error('会話の取得に失敗しました。再接続してください');
      await new Promise(resolve => setTimeout(resolve, 40));
    }
    return this.snapshot(sessionId);
  }
  snapshot(sessionId) {
    const s = this.sessions.get(sessionId);
    if (!s?.loaded) throw new Error('会話を読み込み中です');
    return { id: sessionId, title: s.title || '新しいチャット', cursor: s.cursor, hasMore: !!s.hasMore, running: !!s.running, endReason: s.endReason, error: s.error, messages: projectTranscript(s.records, s.live, Object.fromEntries(Object.values(this.store.state.submissions).filter(item => item.sessionId === sessionId).map(item => [item.requestId, item]))), approvals: [...this.pending.values()].filter(p => p.agentId === sessionId), model: s.projections?.values?.modelSelection?.next, permissions: s.projections?.values?.permissions };
  }
  async older(sessionId) {
    const s = this.sessions.get(sessionId);
    if (!s?.loaded || !s.hasMore) return this.snapshot(sessionId);
    const page = await this.rpc('session/page', { request: { address: { kind: 'session', sessionId }, throughSeq: s.cursor, beforeSeq: s.records[0].event.seq, maxMessages: 50 } });
    s.records = [...page.records, ...s.records]; s.hasMore = page.hasMore;
    return this.snapshot(sessionId);
  }
  async answer(eventId, answer) {
    const pending = this.pending.get(eventId);
    if (!pending || !this.ready) throw new Error('この承認要求は終了しました。会話を再読み込みしてください');
    if (pending.event === 'approval/request' && !['allowed-once', 'rejected'].includes(answer)) throw new Error('Invalid approval outcome');
    const result = await this.rpc('$events/result', { clientId: this.clientId, eventId, outcome: { kind: 'result', value: answer } });
    this.store.questionResolved?.(eventId);
    this.pending.delete(eventId); this.emit('changed', { type: 'approval', sessionId: pending.agentId });
    return result;
  }
}
