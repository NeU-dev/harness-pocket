export function validateAttachments(value = []) {
  if (!Array.isArray(value) || value.length > 5) throw new Error('添付は5個までです');
  let total = 0;
  return value.map(item => {
    if (!item || typeof item.name !== 'string' || !item.name.trim() || item.name.length > 255 || typeof item.data !== 'string') throw new Error('添付ファイルの形式が不正です');
    const bytes = Buffer.from(item.data, 'base64'); total += bytes.length;
    if (bytes.toString('base64') !== item.data) throw new Error('添付ファイルの形式が不正です');
    if (bytes.length > 10 * 1024 * 1024 || total > 20 * 1024 * 1024) throw new Error('添付は1個10MB、合計20MBまでです');
    if (item.kind === 'image') {
      if (!['image/jpeg', 'image/png', 'image/webp', 'image/gif'].includes(item.mediaType) || !bytes.length) throw new Error('対応していない画像形式です');
      return { kind: 'image', name: item.name, mediaType: item.mediaType, data: item.data };
    }
    if (item.kind !== 'file') throw new Error('添付の種類が不正です');
    return { kind: 'file', name: item.name, data: item.data };
  });
}
export async function promptContent(harness, sessionId, text, attachments) {
  const content = text.trim() ? [{ type: 'text', text }] : [];
  content.files = [];
  for (const item of attachments) {
    if (item.kind === 'image') content.push({ type: 'image', name: item.name, mediaType: item.mediaType, data: item.data });
    else {
      const receipt = await harness.uploadFile(sessionId, item);
      if (receipt.path) {
        content.push({ type: 'text', text: `添付ファイルをDGXへ保存しました。必要に応じてツールで読み込んでください。ファイル名: ${JSON.stringify(receipt.file.name)}\n保存先（絶対パス）: ${JSON.stringify(receipt.path)}` });
        content.files.push({ kind: 'file', ...receipt.file });
      } else content.push({ type: 'file', receiptId: receipt.receiptId });
    }
  }
  return content;
}
