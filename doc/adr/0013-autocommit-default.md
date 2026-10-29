# 0013. Autocommit is the default; an explicit transaction pins the session

- Date: 2026-10-29T13:39:55Z
- Status: Accepted

## Context

An explicit transaction needs a stable session, which interacts with extra connections (ADR-0012) and with
server-side locks. An idle open transaction holds locks indefinitely.

## Decision

Autocommit is on by default. `BEGIN`, `COMMIT` and `ROLLBACK` are intercepted by the sidecar and mapped to
`setAutoCommit(false)`, `commit()` and `rollback()` on the JDBC connection rather than passed through as
text, because passing them through desynchronises the driver's view of the transaction state. While a
transaction is open, the session is pinned to the main connection until commit or rollback. If the editor
dies or the sidecar shuts down with a transaction open, the sidecar rolls back — never commits. An idle
open transaction times out (configurable) with a rollback, and the open-transaction state is exposed to
the statusline component.

## Consequences

- Statements from other buffers run on extras during a transaction and do not see uncommitted changes;
  the visible transaction indicator is what keeps that from surprising anyone.
- Dialect-specific transaction syntax (savepoints, named transactions) is deliberately out of scope until
  someone needs it; the interceptor must pass unrecognised forms through untouched.
