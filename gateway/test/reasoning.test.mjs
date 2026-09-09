import test from 'node:test';
import assert from 'node:assert/strict';
import { projectTranscript, restoreLive, applyLiveFrame } from '../src/transcript.mjs';

const record = (seq, data) => ({ event: { seq, type: 'assistant/message', data } });
test('reasoning-only tool steps remain visible, with empty assistant placeholders omitted', () => {
  const messages = projectTranscript([
    record(1, { message: { content: [{ type: 'reasoning', text: 'Check the working directory.' }] } }),
    record(2, { message: { content: [{ type: 'tool-call', name: 'bash' }] } }),
    record(3, { message: { content: [{ type: 'reasoning', text: 'The directory exists.' }, { type: 'text', text: 'Done.' }] } }),
  ]);
  assert.equal(messages.length, 2);
  assert.equal(messages[0].reasoning, 'Check the working directory.');
  assert.equal(messages[0].text, '');
  assert.equal(messages[1].reasoning, 'The directory exists.');
  assert.equal(messages[1].text, 'Done.');
});
test('packed reasoning and raw deltas survive history and active-stream reconnect', () => {
  const stream = [{ type: 'reasoning-chunks', texts: ['Check ', 'the folder.'] }, { type: 'chunk', chunk: { type: 'reasoning-delta', text: ' Ready.' } }, { type: 'text-chunks', texts: ['Done.'] }];
  assert.equal(projectTranscript([record(1, { stream })])[0].reasoning, 'Check the folder. Ready.');
  let live = restoreLive({ attemptId: 'a', nextIndex: 4, stream });
  live = applyLiveFrame(live, { type: 'chunk', attemptId: 'a', index: 4, chunk: { type: 'reasoning-delta', text: ' Continue.' } });
  assert.equal(projectTranscript([], live)[0].reasoning, 'Check the folder. Ready. Continue.');
  assert.equal(projectTranscript([], live)[0].streaming, true);
  assert.equal(applyLiveFrame(live, { type: 'end', attemptId: 'a' }), live);
  assert.throws(() => applyLiveFrame(live, { type: 'chunk', attemptId: 'a', index: 8, chunk: { type: 'text-delta', text: '?' } }), /再同期/);
});
test('live reasoning displays before the first answer text arrives', () => {
  let live = applyLiveFrame(null, { type: 'start', attemptId: 'a' });
  live = applyLiveFrame(live, { type: 'chunk', attemptId: 'a', index: 0, chunk: { type: 'reasoning-delta', text: 'Checking.' } });
  assert.equal(projectTranscript([], live)[0].reasoning, 'Checking.');
  assert.equal(projectTranscript([], live)[0].text, '');
});
