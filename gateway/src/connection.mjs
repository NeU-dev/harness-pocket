import fs from 'node:fs';

export function localConnection(url, token) {
  const parsed = new URL(url);
  if (parsed.protocol !== 'http:' || !['127.0.0.1', 'localhost', '[::1]'].includes(parsed.hostname) || parsed.username || parsed.password || (parsed.pathname !== '/' && parsed.pathname !== '') || parsed.hash) throw new Error('DSHの接続先はDGX内のlocalhostを指定してください');
  if (parsed.search && (parsed.searchParams.size !== 1 || !parsed.searchParams.has('token'))) throw new Error('DSHの起動時URLを指定してください');
  const secret = token || parsed.searchParams.get('token');
  if (typeof secret !== 'string' || secret.length < 16 || secret.length > 512 || /[\s\x00-\x1f]/.test(secret)) throw new Error('DSHの起動時URLにtokenが必要です');
  return { url: parsed.origin, token: secret };
}

export function readPrivateConnection(file, { runtime = false } = {}) {
  try {
    const info = fs.lstatSync(file);
    if (!info.isFile() || info.size > 8192 || (info.mode & 0o077) || (process.getuid && info.uid !== process.getuid())) return null;
    const record = JSON.parse(fs.readFileSync(file, 'utf8'));
    if (runtime) {
      if (record.version !== 1 || !Number.isInteger(record.pid) || record.pid <= 0) return null;
      process.kill(record.pid, 0);
    }
    return localConnection(record.url, record.token);
  } catch { return null; }
}

export async function exchangeLaunchToken(url, token) {
  const target = new URL('/', url); target.searchParams.set('token', token);
  const result = await fetch(target, { redirect: 'manual', signal: AbortSignal.timeout(10_000) });
  const cookies = result.headers.getSetCookie();
  if (![302, 303].includes(result.status) || !cookies.length) throw new Error('DSHの認証を更新できません。接続設定で起動時URLを更新してください');
  return cookies.map(cookie => cookie.split(';')[0]).join('; ');
}
