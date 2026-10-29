# 0026. An expired token fails the statement; nothing renews it silently

- Date: 2026-10-29T19:00:00Z
- Status: Accepted

## Context

ADR-0011 left open what happens to a live connection when its bearer token expires. The options were
silent renewal (the sidecar re-reads a token and reconnects), proactive expiry tracking (parse the JWT,
reconnect before the deadline), and doing nothing (the statement fails with the server's own
authentication error).

Silent renewal would mean the sidecar reading secrets on its own schedule, which breaks the one-direction
flow ADR-0007 and ADR-0009 establish: secrets are read in Lua, at connect time, and travel once. Proactive
tracking assumes the token is a JWT with a readable `exp`, which Trino's can be and others need not be.

## Decision

Nothing renews a token. When it expires, the statement fails with the driver's authentication error, the
user stores a fresh value under the same kvstore key, and `:NGripDisconnect` (or the next connect after the
process is replaced) picks it up — connect-time resolution means a fresh connect always reads the current
value. The error message path is already in place; no machinery is added.

## Consequences

- The failure mode is visible and the fix is two commands; nothing happens behind the user's back.
- Long sessions against short-lived tokens will see periodic failures; a `token_command`-style refresher
  was deliberately rejected with ADR-0007's reasoning (executables named in config files).
- If this proves painful in practice, a superseding ADR can introduce renewal through kvstore re-reads on
  auth failure — the reconnect path it needs already exists.
