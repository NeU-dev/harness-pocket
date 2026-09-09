import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';

export const name = 'harness-pocket-link';
export const inject = ['connection', 'webServer'];

// Publish through DSH's own authentication API; no secrets are logged or sent off-host.
export function apply(ctx) {
  const directory = path.join(os.homedir(), '.local/share/harness-pocket/data');
  const file = path.join(directory, 'dsh-runtime.json');
  let disposed = false;
  ctx.on('dispose', () => { disposed = true; });
  const publish = () => {
    if (disposed || !ctx.webServer?.port) return;
    fs.mkdirSync(directory, { recursive: true, mode: 0o700 });
    const info = fs.lstatSync(directory);
    if (!info.isDirectory() || info.uid !== process.getuid()) throw new Error('Pocket runtime directory must belong to the DSH user');
    fs.chmodSync(directory, 0o700);
    const authenticated = new URL(ctx.connection.authenticatedUrl(`http://127.0.0.1:${ctx.webServer.port}`));
    const record = { version: 1, url: authenticated.origin, token: authenticated.searchParams.get('token'), pid: process.pid, updatedAt: Date.now() };
    const temporary = file + `.${process.pid}.tmp`;
    fs.writeFileSync(temporary, JSON.stringify(record), { mode: 0o600 });
    fs.chmodSync(temporary, 0o600); fs.renameSync(temporary, file);
  };
  const safePublish = () => {
    try { publish(); }
    catch { console.warn('Harness Pocket: local connection handoff could not be saved'); }
  };
  const ready = ctx.get('loader')?.await();
  if (ready) ready.then(safePublish, () => {}); else safePublish();
}
