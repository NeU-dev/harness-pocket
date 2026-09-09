import test from 'node:test';
import assert from 'node:assert/strict';
import { validateAttachments } from '../src/attachments.mjs';
import { projectTranscript } from '../src/transcript.mjs';

test('attachment validation rejects corrupt encoding, excess size and unsupported image types', () => {
  const file = { kind: 'file', name: 'file.txt', data: 'YQ==' };
  assert.throws(() => validateAttachments([{ ...file, data: 'not base64' }]));
  assert.throws(() => validateAttachments(Array(6).fill(file)));
  assert.throws(() => validateAttachments([{ ...file, data: Buffer.alloc(10 * 1024 * 1024 + 1).toString('base64') }]));
  assert.throws(() => validateAttachments([{ ...file, kind: 'image', mediaType: 'text/html' }]));
  assert.equal(validateAttachments([file])[0].name, 'file.txt');
});
test('durable image and file metadata remain visible in history without embedding bytes', () => {
  const messages = projectTranscript([{ event: { seq: 1, type: 'user/message', data: { content: [{ type: 'image', attachment: { attachmentId: 'image', name: 'photo.jpg' } }, { type: 'file', attachment: { attachmentId: 'file', name: 'doc.pdf' } }] } } }], null);
  assert.equal(messages[0].attachments.length, 2);
  assert.equal(messages[0].attachments[1].name, 'doc.pdf');
});
