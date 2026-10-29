# 0028. Every request runs on its own thread; the session is a lock

- Date: 2026-10-29T21:10:00Z
- Status: Accepted

## Context

ADR-0027 carried the predecessor's lane model into the annotation: `@RpcMethod(lane = "read")` for
ping/cancel, a shared worker for statements, a named exclusive lane for the introspect sweep. The author
of a handler had to know and declare which thread answers — a leak of the library's problem into every
signature, and the user rejected it: threading is not the handler's business.

The constraint underneath never was the lanes. It is JDBC: the shared connection is the session
(ADR-0012) and takes one statement at a time, and `Statement.cancel()` is the one call defined as safe
from another thread. The lanes were just one spelling of that; a lock is another.

## Decision

`@RpcMethod` has no attributes. The server dispatches every request onto its own virtual thread
(Java 21), so the read loop never blocks and every method is always answerable — which is all "read lane"
ever bought. The serialization of the shared connection moves to where its owner lives: `Database` holds
one fair lock around every operation that touches the session connection. `cancel` never takes it, which
is what keeps it able to cancel; the idle-transaction watchdog takes it, which is what keeps it from
racing a statement. The introspect sweep keeps its one-at-a-time rule as a flag inside `Database` and, as
before, runs on sibling connections without the lock. The `Worker` injectable disappears — there is no
worker.

This supersedes the lane model of ADR-0027; everything else in that record stands. Nothing on the wire
changes: protocolVersion stays 1, and ordering of a client's statements is preserved by the fair lock and
by the Lua runner, which already sends one statement per connection at a time.

## Consequences

- Handler signatures carry zero threading knowledge; adding a method is a record and a function, full stop.
- The threading contract becomes two sentences: requests are concurrent; the session connection is not.
- A fair lock keeps FIFO order for callers that queue, at a few microseconds over the executor handoff.
- Virtual threads raise the Java floor in practice to 21, which ADR-0005 already pins.
- The sweep's fallback path (no siblings available: DuckDB, SQLite) runs on the session connection without
  the lock, exactly as the lane model did; the file engines finish in milliseconds and the risk profile is
  unchanged rather than silently different.
