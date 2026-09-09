# Upstream contract

Reference: https://github.com/deepseek-ai/deepseek-harness

Inspected revision: `c389f96bf3a9b6807cb71ed6bdad5849be0df6d8` (2026-09-08).

The gateway is an independent client. It does not modify the model loop. An optional local DSH plugin publishes restart connection information using the connection service.

- Root token exchange produces the authority-bound upstream cookie, retained on the gateway only.
- HTTP: `POST /api/<endpoint>` with `{type:'client-request', rpcId, method:endpoint, payload:{args}}`. Response: `{type:'server-response', rpcId, result:{ok,value|error}}`.
- WS `/api/remote.mux`: `{type:'open',streamId,endpoint,payload:{args}}`; receive `{type:'item',streamId,value}`. `$events` ready precedes baseline reads.
- `session/list` has argument `_request`; other session operations use `request`.
- `session/follow` snapshot includes cursor, records, active assistant baseline; every new durable event has a contiguous seq. On reconnect, recover missed pages through the snapshot cursor before advancing the persisted notification cursor.
- Assistant content contains separate `text` and `reasoning` blocks. Both are preserved; packed `reasoning-chunks` and live `reasoning-delta` feed the reasoning field. Empty assistant tool-only settlements are omitted from the display while their tool/call records remain.
- Only durable `turn/end` with `reason.kind === 'completed'` triggers completion notifications. Tool steps and partial assistant settlements do not.
- `settings/mutate` uses namespace, path operations and expectedRevision; never replace the entire redacted document.
- Approval results are correlated with the current `$events` clientId and pending eventId. Only `allowed-once` permits execution.

Sources: packages/client/connection/src/client/rpc.ts, packages/api/gateway/src/stream-protocol.ts, packages/api/session-controller/src/types.ts, packages/core/session/src/types.ts, packages/settings/settings/src/types.ts.

## Build 6 runtime integration (2026-09-09)

- Running DSH package: 0.1.2-rc.1, web profile, port 8080.
- Link plugin injects `connection` and `webServer`, waits for `loader.await()`, then calls `connection.authenticatedUrl()` with the current loopback port.
- Questions arrive as `$events` waterfall `user-questions/request` with `agentId`, `eventId`, and `request`. Matching cancel or `$events/result` resolves them. Pending questions are not durable session events in this installed version. Notification enqueueing uses device/session/event identity, not natural-language matching.
- Connection fallback accepts only local HTTP loopback URLs and validates the launch token before persisting.
