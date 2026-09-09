// A full baseline on selection/reconnect, then replacements for changed rows only.
export function sessionFrame(snapshot, previous) {
  if (!previous || previous.id !== snapshot.id) return { type: 'session', sessionId: snapshot.id, snapshot };
  const prior = new Map(previous.messages.map(message => [message.id, JSON.stringify(message)]));
  const { messages, ...meta } = snapshot;
  return {
    type: 'sessionDelta', sessionId: snapshot.id, meta,
    order: messages.map(message => message.id),
    messages: messages.filter(message => prior.get(message.id) !== JSON.stringify(message)),
  };
}
