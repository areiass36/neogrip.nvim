# 0042. Protocol 5: gripd says when an execution begins

- Date: 2026-11-09T14:46:23Z
- Status: Accepted

## Context

A reader who runs a slow statement is told nothing until it answers. The only signal today is a
notification scheduled 2000 ms after the request leaves, which says a query is running on a connection
and nothing after that.

The number a reader actually wants is how long the statement has been executing, and the client cannot
derive it. `elapsedMs` arrives with the answer and is therefore useless while waiting. Measuring from
the moment the client sent the request measures something else: the Lua runner serializes one request
per connection, `ExecutionLane` holds a fair lock on the Java side (ADR-0028), the driver may be
downloaded and gripd may be compiled on first use (ADR-0004, ADR-0006), and `Statements` takes its
`start` only after acquiring that lock. On a first query of a session the difference between "since I
pressed the key" and "since the database started working" is tens of seconds.

So the instant execution begins is knowable on the server and nowhere else.

Two facts about where the time goes bound what the server can report. A query's execution is one
blocking call — `statement.execute(sql)` — so nothing inside it can be sampled without a thread that
does not exist there. And the rows of the opening window are pulled inside the driver by `setMaxRows`,
not by a loop gripd runs, so there is no row counter to publish either; the only loop in `batch` is
bounded by `limit`, which is 200 by default.

## Decision

Gripd emits one notification immediately before every execution of a named result's statement:

```json
{"jsonrpc":"2.0","method":"progress","params":{"hash":"a1b2c3d4e5f6","phase":"executing"}}
```

The client starts counting when it arrives and stops when the answer does. `elapsedMs` in the response
is unchanged and stays the authoritative number; the running one is a progress indicator.

1. **Two emission sites, both inside `Cursor`**, each one line before the blocking call: before
   `statement.execute(sql)` when the result opens, and before `statement.executeQuery(sql)` in
   `refill()`. The rule is "a notification precedes every execution of this statement", not "every
   request", which is why it cannot live in `Statements.query`: `refill` is reached through
   `Cursors.next` and `advance` and never passes through it. Leaving it out would leave the clock frozen
   on the slowest case there is — ADR-0031 measured 226 s and 236 s on a Trino refill.

2. **One phase and no counter.** `phase` is a closed vocabulary of one word, `executing`. A row count
   was considered and has nowhere to be measured for a query, per the Context. The real row loop is in
   `Exports`, which has no result name and no window to draw in; an export progress indicator is its own
   change and is deliberately not decided here.

3. **The identifier is the result's name, so only named results report.** A request with no `hash`
   emits nothing, which excludes `exec`, `export`, `validate`, `catalog/*`, an intercepted
   `BEGIN`/`COMMIT`/`ROLLBACK`, and every background query — the samples and probes that are named by
   nobody because nothing will ever page them. Reporting those would need a different identifier,
   and the one available is the JSON-RPC request id: the client already keeps it, and the server would
   need a `ThreadLocal` set in `RpcServer.handle`, which is cheap under one virtual thread per request
   (ADR-0028). That is the extension path, named here so it is not re-derived, and not built for a
   feature nothing shows yet.

4. **The domain says what happened and the edge spells the frame.** `Notifications` gains
   `executing(String hash)` rather than a generic `progress(hash, phase, rows)`, because the wire name
   and the parameter map belong to the rpc adapter and to nowhere else (ADR-0035). The adapter class is
   renamed from `StatusNotifications` to `WireNotifications`, since it now sends two families of frame.

5. **`Cursor` is told through a one-method interface, `Started`, not through `Notifications`.** A cursor
   has no business holding a notifier or knowing its own name on the wire. `Statements` decides whether
   anybody is listening and hands over a no-op when nobody is, so there is no null to check and no
   branch at the emission site.

6. **The version goes to 5.** A method appears on the wire, so the rule applies and the handshake is
   where incompatibility becomes a refusal (ADR-0034). ADR-0041's argument for not bumping does not
   reach here: its own concrete test was that `lua/neogrip/rpc/protocol.lua` does not change, and this
   changes it.

### What this makes observable

`doc/protocol.md` says of a window refill that "the client is not told — a refill is indistinguishable
from a continuation". It now is told, and that line is rewritten in the same commit. The guarantee being
removed is opacity, not capability: a client still cannot act differently on a refill, because there is
no request it could make instead. What it can do is keep the clock moving, which is the whole point.

## Consequences

- Bumping the version in `lua/neogrip/rpc/protocol.lua` invalidates every user's class cache through the
  stamp file and costs one `javac` run on next use. That is the mechanism working as ADR-0004 intended.
- The running number and the footer's number disagree by a few milliseconds, and the sign is
  indeterminate: the server's `start` is taken before `createStatement` and `setMaxRows` while the
  notification is emitted after them, and the client's clock additionally pays the inbound trip while
  its last tick pays the outbound one. The footer is authoritative. No test may assert they are equal.
- Ordering is guaranteed without new machinery. The notification is written by the same virtual thread
  that will write the response, through a `synchronized` transport, strictly before it; the client
  consumes lines in order inside one scheduled callback. So a `progress` can never overtake the answer
  it precedes, and a query fast enough to answer first simply never emits one the client can use.
- `log` and the server-initiated `input` request stay documented and unimplemented. This record does not
  touch them.
- Every notification is still ignorable: a client that does not handle `progress` loses a clock and
  nothing else.
