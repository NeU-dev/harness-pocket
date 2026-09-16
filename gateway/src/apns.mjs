import fs from 'node:fs';
import path from 'node:path';
import http2 from 'node:http2';
import { createPrivateKey, sign } from 'node:crypto';

export function makeProviderJWT(key, keyId, teamId, now = Date.now()) {
  const encode = value => Buffer.from(JSON.stringify(value)).toString('base64url');
  const head = encode({ alg: 'ES256', kid: keyId });
  const body = encode({ iss: teamId, iat: Math.floor(now / 1000) });
  const data = `${head}.${body}`;
  return `${data}.${sign('sha256', Buffer.from(data), { key, dsaEncoding: 'ieee-p1363' }).toString('base64url')}`;
}
export class APNs {
  constructor(directory, env = process.env) {
    this.file = path.join(directory, 'apns.json');
    this.keyFile = path.join(directory, 'apns.p8');
    this.config = fs.existsSync(this.file) ? JSON.parse(fs.readFileSync(this.file, 'utf8')) : {
      keyPath: env.APNS_KEY_PATH, keyId: env.APNS_KEY_ID, teamId: env.APNS_TEAM_ID, topic: env.APNS_TOPIC || '',
    };
  }
  status() {
    return { configured: !!(this.config.keyPath && fs.existsSync(this.config.keyPath) && this.config.keyId && this.config.teamId && this.config.topic), keyId: this.config.keyId || '', teamId: this.config.teamId || '', topic: this.config.topic, };
  }
  configure({ keyId, teamId, privateKey, topic = this.config.topic }) {
    if (!/^[A-Z0-9]{10}$/.test(keyId) || !/^[A-Z0-9]{10}$/.test(teamId)) throw new Error('Key ID と Team ID は10文字の英数字です');
    if (typeof topic !== 'string' || topic.length > 255 || !/^[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+$/.test(topic)) throw new Error('アプリのBundle IDを指定してください');
    let keyPath = this.config.keyPath;
    if (privateKey) {
      const key = createPrivateKey(privateKey);
      if (key.asymmetricKeyType !== 'ec' || key.asymmetricKeyDetails?.namedCurve !== 'prime256v1') throw new Error('APNsのES256秘密鍵を指定してください');
      fs.writeFileSync(this.keyFile, privateKey, { mode: 0o600 });
      keyPath = this.keyFile;
    }
    if (!keyPath || !fs.existsSync(keyPath)) throw new Error('.p8 ファイルが必要です');
    this.config = { keyId, teamId, keyPath, topic };
    fs.writeFileSync(this.file, JSON.stringify(this.config), { mode: 0o600 });
    this.jwt = null;
    return this.status();
  }
  async send(push, item, { test = false } = {}) {
    if (!this.status().configured) return { status: 503, reason: 'APNsNotConfigured', retry: true };
    if (!this.jwt || Date.now() - this.jwtAt > 45 * 60_000) {
      this.jwt = makeProviderJWT(fs.readFileSync(this.config.keyPath), this.config.keyId, this.config.teamId);
      this.jwtAt = Date.now();
    }
    const origin = push.environment === 'sandbox' ? 'https://api.sandbox.push.apple.com' : 'https://api.push.apple.com';
    const payload = notificationPayload(item, test);
    return new Promise(resolve => {
      const client = http2.connect(origin);
      let settled = false;
      const done = value => { if (settled) return; settled = true; clearTimeout(timer); client.destroy(); resolve(value); };
      const timer = setTimeout(() => done({ status: 0, reason: 'Timeout', retry: true }), 15_000);
      client.on('error', () => done({ status: 0, reason: 'ConnectionError', retry: true }));
      const request = client.request({ ':method': 'POST', ':path': `/3/device/${push.token}`, authorization: `bearer ${this.jwt}`, 'apns-topic': this.config.topic, 'apns-push-type': 'alert', 'apns-priority': '10', 'apns-expiration': String(Math.floor((Date.now() + 86_400_000) / 1000)), 'apns-collapse-id': item.id.slice(0, 64) });
      let status = 0, response = '';
      request.on('response', headers => { status = headers[':status']; });
      request.on('data', data => { response += data; });
      request.on('error', () => done({ status: 0, reason: 'StreamError', retry: true }));
      request.on('end', () => {
        let reason = ''; try { reason = JSON.parse(response).reason || ''; } catch {}
        done({ status, reason, retry: status === 429 || status >= 500 || reason === 'ExpiredProviderToken' });
      });
      request.end(JSON.stringify(payload));
    });
  }
}
export function notificationPayload(item, test = false) {
  const localizationKey = test ? 'POCKET_NOTIFICATION_TEST' : item.kind === 'question' ? 'POCKET_NOTIFICATION_QUESTION' : item.kind === 'approval' ? 'POCKET_NOTIFICATION_APPROVAL' : 'POCKET_NOTIFICATION_COMPLETE';
  return { aps: { alert: { title: 'Harness Pocket', 'loc-key': localizationKey }, sound: 'default', 'thread-id': item.sessionId || 'test' }, sessionId: item.sessionId, eventId: item.id, kind: item.kind || 'completed' };
}
export class NotificationWorker {
  constructor(store, sender) { this.store = store; this.sender = sender; this.running = false; }
  async drain(now = Date.now()) {
    if (this.running) return;
    this.running = true;
    try {
      for (const item of Object.values(this.store.state.outbox)) {
        if (item.status !== 'pending' || item.nextAttemptAt > now) continue;
        const device = this.store.state.devices[item.deviceId];
        if (!device?.push || !device.notifications || now - item.createdAt > 86_400_000) { item.status = 'expired'; this.store.save(); continue; }
        const attemptedToken = device.push.token;
        let response;
        try { response = await this.sender.send(device.push, item); } catch { response = { status: 0, reason: 'SendError', retry: true }; }
        item.attempts++;
        item.lastResult = { status: response.status, reason: response.reason, at: Date.now() };
        if (response.status === 200) item.status = 'sent';
        else if (response.status === 410) {
          if (device.push?.token === attemptedToken) delete device.push;
          item.status = 'invalid-device';
        } else if (response.retry && item.attempts < 12) item.nextAttemptAt = Date.now() + Math.min(3_600_000, 10_000 * 2 ** item.attempts);
        else item.status = 'failed';
        this.store.save();
      }
    } finally { this.running = false; }
  }
}
