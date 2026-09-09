import test from 'node:test';
import assert from 'node:assert/strict';
import { sessionFrame } from '../src/stream.mjs';

test('stream deltas reconstruct added, changed, removed rows and final status without resending history', () => {
  const previous = { id: 's', running: true, approvals: [], messages: [{ id: 'old', text: 'a'.repeat(100_000) }, { id: 'live', reasoning: 'thinking' }] };
  assert.equal(sessionFrame(previous, null).type, 'session');
  const next = { ...previous, running: false, approvals: [{ id: 'permission' }], messages: [previous.messages[0], { id: 'answer', text: 'done' }] };
  const frame = sessionFrame(next, previous);
  assert.equal(frame.type, 'sessionDelta');
  assert.deepEqual(frame.messages, [next.messages[1]]);
  assert.ok(JSON.stringify(frame).length < JSON.stringify(next).length / 100);
  const rows = new Map([...previous.messages, ...frame.messages].map(row => [row.id, row]));
  assert.deepEqual({ ...frame.meta, messages: frame.order.map(id => rows.get(id)) }, next);
  assert.equal(sessionFrame({ ...next, id: 'different' }, previous).type, 'session');
});
