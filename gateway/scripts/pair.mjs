import fs from 'node:fs';
import path from 'node:path';
const directory = process.env.DATA_DIR || './data';
const token = fs.readFileSync(path.join(directory, 'admin-token'), 'utf8');
const result = await fetch(`http://127.0.0.1:${process.env.PORT || 8787}/admin/pair`, { method: 'POST', headers: { Authorization: `Bearer ${token}` } });
if (!result.ok) throw new Error(`Pairing failed: HTTP ${result.status}`);
const value = await result.json();
console.log(`接続先: ${value.url}\n登録コード: ${value.code}\n有効期限: ${new Date(value.expiresAt).toLocaleString('ja-JP')}`);
