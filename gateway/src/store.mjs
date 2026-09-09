import fs from 'node:fs';
import path from 'node:path';
import { randomBytes, randomUUID, createHash, timingSafeEqual } from 'node:crypto';

export const digest = value => createHash('sha256').update(value).digest('hex');
export const secureEqual = (a, b) => typeof a === 'string' && typeof b === 'string' && a.length === b.length && timingSafeEqual(Buffer.from(a), Buffer.from(b));
export class Store {
  constructor(directory) {
    this.directory = path.resolve(directory);
    fs.mkdirSync(this.directory, { recursive: true, mode: 0o700 });
    this.file = path.join(this.directory, 'state.json');
    this.state = fs.existsSync(this.file) ? JSON.parse(fs.readFileSync(this.file, 'utf8')) : {
      version: 1, devices: {}, pairing: {}, watches: {}, outbox: {}, preferences: {},
    };
    if (this.state.version !== 1) throw new Error('Unsupported gateway state version');
    this.state.submissions ??= {};
    this.save();
  }
  save() {
    const temporary = this.file + '.tmp';
    const fd = fs.openSync(temporary, 'w', 0o600);
    try { fs.writeFileSync(fd, JSON.stringify(this.state)); fs.fsyncSync(fd); } finally { fs.closeSync(fd); }
    fs.renameSync(temporary, this.file);
  }
  pairCode() {
    const code = randomBytes(6).toString('hex').toUpperCase();
    const now = Date.now();
    for (const [key, item] of Object.entries(this.state.pairing)) if (item.expires < now) delete this.state.pairing[key];
    this.state.pairing[digest(code)] = { expires: now + 10 * 60_000 };
    this.save();
    return { code, expiresAt: now + 10 * 60_000 };
  }
  pair(code, name) {
    const key = digest(String(code).replace(/[\s-]/g, '').toUpperCase());
    if (!this.state.pairing[key] || this.state.pairing[key].expires < Date.now()) return null;
    delete this.state.pairing[key];
    const token = randomBytes(32).toString('base64url');
    const device = { id: randomUUID(), name: String(name || 'iPhone').slice(0, 80), tokenHash: digest(token), createdAt: Date.now(), notifications: true, subscriptions: {} };
    this.state.devices[device.id] = device;
    this.save();
    return { token, deviceId: device.id };
  }
  authenticate(token) {
    if (typeof token !== 'string' || token.length > 512) return null;
    const hashed = digest(token);
    return Object.values(this.state.devices).find(device => secureEqual(device.tokenHash, hashed)) ?? null;
  }
  subscribe(device, sessionId, cursor) {
    if (!Object.hasOwn(device.subscriptions, sessionId)) device.subscriptions[sessionId] = { afterSeq: cursor, since: Date.now() };
    this.state.watches[sessionId] ??= { cursor, lastSeenAt: Date.now() };
    this.save();
  }
  questionAsked(sessionId, eventId) {
    if (!sessionId || !eventId) return;
    for (const device of Object.values(this.state.devices)) {
      if (!device.subscriptions[sessionId] || !device.notifications || !device.push) continue;
      const id = digest(`${device.id}:${sessionId}:question:${eventId}`);
      this.state.outbox[id] ??= { id, deviceId: device.id, sessionId, questionId: eventId, kind: 'question', createdAt: Date.now(), attempts: 0, nextAttemptAt: Date.now(), status: 'pending' };
      if (this.state.outbox[id].status === 'waiting-connection') { this.state.outbox[id].status = 'pending'; this.state.outbox[id].nextAttemptAt = Date.now(); }
    }
    this.save();
  }
  questionResolved(eventId) {
    let changed = false;
    for (const item of Object.values(this.state.outbox)) {
      if (item.kind === 'question' && ['pending', 'waiting-connection'].includes(item.status) && (!eventId || item.questionId === eventId)) { item.status = 'cancelled'; changed = true; }
    }
    if (changed) this.save();
  }
  questionConnectionLost() {
    let changed = false;
    for (const item of Object.values(this.state.outbox)) {
      if (item.kind === 'question' && item.status === 'pending') { item.status = 'waiting-connection'; changed = true; }
    }
    if (changed) this.save();
  }
  observe(sessionId, events, cursor, { baseline = false } = {}) {
    const watch = this.state.watches[sessionId];
    if (!watch) return;
    const previous = watch.cursor;
    for (const event of events) {
      if (!baseline && event.seq > previous && event.type === 'turn/end') for (const item of Object.values(this.state.outbox)) {
        if (item.sessionId === sessionId && item.kind === 'question' && ['pending', 'waiting-connection'].includes(item.status) && (!event.time || event.time >= item.createdAt)) item.status = 'cancelled';
      }
      if (event.type === 'approval/decided') {
        for (const item of Object.values(this.state.outbox)) {
          if (item.sessionId === sessionId && item.approvalId === event.data.id && item.status === 'pending') item.status = 'cancelled';
        }
      }
      const approval = event.type === 'approval/asked';
      if (baseline || event.seq <= previous || (!approval && !(event.type === 'turn/end' && event.data?.reason?.kind === 'completed'))) continue;
      for (const device of Object.values(this.state.devices)) {
        const sub = device.subscriptions[sessionId];
        if (!sub || event.seq <= sub.afterSeq || !device.notifications || !device.push) continue;
        const id = digest(`${device.id}:${sessionId}:${event.seq}`);
        this.state.outbox[id] ??= { id, deviceId: device.id, sessionId, seq: event.seq, kind: approval ? 'approval' : 'completed', ...(approval ? { approvalId: event.data.id } : {}), createdAt: Date.now(), attempts: 0, nextAttemptAt: Date.now(), status: 'pending' };
      }
    }
    watch.cursor = Math.max(previous, cursor);
    watch.lastSeenAt = Date.now();
    // Outbox insertion and cursor advancement share one durable atomic commit.
    this.save();
  }
}
