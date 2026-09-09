export function textContent(content, type = 'text') {
  if (!Array.isArray(content)) return '';
  return content.filter(block => block.type === type).map(block => block.text || '').join('\n');
}
export function compactText(stream = [], type = 'text') {
  return stream.flatMap(record => record.type === `${type}-chunks` ? record.texts || [] : record.type === 'chunk' && record.chunk?.type === `${type}-delta` ? [record.chunk.text || ''] : []).join('');
}
export function restoreLive(active) {
  return active ? { attemptId: active.attemptId, text: compactText(active.stream), reasoning: compactText(active.stream, 'reasoning'), nextIndex: active.nextIndex } : null;
}
export function applyLiveFrame(live, frame) {
  if (frame.type === 'start') return { attemptId: frame.attemptId, text: '', reasoning: '', nextIndex: 0 };
  if (frame.type === 'chunk' && live?.attemptId === frame.attemptId) {
    if (frame.index !== live.nextIndex) throw new Error('回答ストリームを再同期しています');
    live.nextIndex++;
    if (frame.chunk.type === 'text-delta') live.text += frame.chunk.text;
    if (frame.chunk.type === 'reasoning-delta') live.reasoning += frame.chunk.text;
  }
  // Keep the last frame visible until its durable assistant/message replaces it.
  return live;
}
export function projectTranscript(records, live, submissions = {}) {
  const messages = [];
  for (const { event } of records) {
    const d = event.data;
    if (event.type === 'user/message') {
      if (d.source && d.source.kind !== 'user' && d.source.type !== 'user-rpc') continue;
      messages.push({ id: String(event.seq), seq: event.seq, role: 'user', text: submissions[d.source?.rpcId]?.originalText ?? textContent(d.content), attachments: (d.content || []).filter(b => ['image', 'file'].includes(b.type) && b.attachment).map(b => ({ kind: b.type, ...b.attachment })).concat(submissions[d.source?.rpcId]?.files || []), time: event.time, requestId: d.source?.rpcId });
    } else if (event.type === 'assistant/message') {
      const text = textContent(d.message?.content) || compactText(d.stream);
      const reasoning = textContent(d.message?.content, 'reasoning') || compactText(d.stream, 'reasoning');
      if (text.trim() || reasoning.trim()) messages.push({ id: String(event.seq), seq: event.seq, role: 'assistant', text, reasoning, time: event.time, interrupted: !!d.interrupted });
    } else if (event.type === 'tool/call') {
      messages.push({ id: String(event.seq), seq: event.seq, role: 'tool', text: d.arguments || '', title: d.name, callId: d.callId, time: event.time, status: 'running' });
    } else if (event.type === 'tool/result') {
      const call = messages.findLast(m => m.role === 'tool' && m.callId === d.message?.toolCallId);
      if (call) { call.status = d.error ? 'failed' : 'completed'; call.result = textContent(d.message?.content); }
    }
  }
  if (live && (live.text || live.reasoning)) messages.push({ id: 'live-' + live.attemptId, role: 'assistant', text: live.text, reasoning: live.reasoning || '', time: Date.now(), streaming: true });
  return messages;
}
