# 0041. An open result lives an hour, and there is no cap on how many

- Date: 2026-11-04T19:45:00Z
- Status: Accepted

## Context

ADR-0031 kept "at most four live cursors per connection ... the oldest is closed first", for a client that
forgets to close what it opened, and closed a cursor untouched for `cursorIdleSeconds` — five minutes by
default.

Both numbers were chosen when a result was read a page at a time by pressing a key. ADR-0040 makes a
result read by scrolling, which changes what each one means. A reader can be away from the keyboard for a
long time without having abandoned anything, and under ADR-0040 an expired cursor is a dead end rather
than something recovered — so an eviction the reader did not cause now surfaces as a visible failure.

Who actually opens more than one named result is worth naming, because it was not the grid. The grid
releases the hash of the result it replaces. The catalog tree opens one named result per expanded row
node, and the handle it returns does not close it: `runner.cancel` returns early when the request has
already answered, so collapsing a node after its page arrived closes nothing. The cap was therefore
*tree* pressure, and the user-visible cost of it was that the fifth expansion silently killed the first
node's continuation.

The cost of keeping one is worth stating exactly, because the decision below trades against it. A live
cursor holds one `Statement` and `ResultSet` on the shared connection, plus whatever the driver buffers
for the current execution, which `setMaxRows` bounds at `WINDOW + 1` = 1001 rows. The rows already handed
out are **not** retained: `batch()` collects into a local list that is dropped once the response is
written. So the retained cost is one open statement and at most ~1001 rows of driver buffer per cursor —
not the whole result.

## Decision

`MAX_LIVE` and the eviction loop go. A result stays open until something closes it.

`keep()` becomes the duplicate refusal and the registration, and nothing else. The `LinkedHashMap` stays:
it is no longer insertion-ordered so the oldest can be evicted, it is insertion-ordered so shutdown
closes results in the order they were opened, which makes a log readable. A `HashMap` would work as well —
the sweep uses `values().removeIf` and the rest are key lookups — but changing it would lose that
determinism for nothing. It does not become a `ConcurrentHashMap` either: every method is already
synchronized except `next()`, which deliberately is not, and which only calls the synchronized lookups.

`cursorIdleSeconds` defaults to one hour instead of five minutes. It stays a user-facing option, and zero
keeps its existing meaning of disabling the sweep entirely — which now means a cursor lives until its
result is replaced or the process ends.

Reclamation is now exactly four paths, and they are the only ones: `cancel {hash}`, the idle sweep, the
client's release of a result it is replacing, and shutdown. Two of those were not actually working, and
this record requires them fixed rather than leaving them for later: the tree must release a finished
listing's hash, and closing the grid must release the result's. Without those two, the consequence of
this decision would be that a known leak was made unbounded on purpose.

### No protocol version bump

The repository rule is that a change to the contract bumps the protocol version, and `doc/protocol.md`
documents the lifetime rules, so the letter of the rule points at a bump. Against it, and decisively:

The version is checked at `initialize` and a mismatch is a hard refusal, so a bump is a compatibility
break. Gripd is compiled from the sources in this repository on first use (ADR-0004), so client and
server always ship together; the version's real job is catching a stale class cache, not negotiating with
a server of a different age.

No method, request field, response field or error code changes. A hash that is gone still answers
`-32600`; only one of the reasons a hash can be gone disappears. The guarantee being removed is a *limit*,
not a capability — it cannot break a client that respected it, only one that relied on eviction to clean
up after itself, which is the client bug the cap was written for.

The concrete test that the wire did not move is that neither `lua/neogrip/rpc/protocol.lua` nor
`java/lib/neogrip/jsonrpc/JsonRpc.java` changes. `doc/protocol.md` is still rewritten in the same commit
as the Java change, per the lockstep rule.

### What this supersedes

Only the cursor-lifetime clause in ADR-0031's Decision — the four-cursor cap and the oldest-first
eviction. Everything else in that record stands, including the 1001-row window, the refill, and the
consequence that the sidecar holds up to 1000 rows per open result, which is about the window and not
about the cap.

ADR-0031's file is not edited and its status stays `Accepted`. The instructions say to mark a superseded
record as superseded and also forbid editing an accepted one, which cannot both be honoured for a partial
supersession; this follows the precedent ADR-0031 itself set, which declares "This supersedes the paging
mechanism of ADR-0014" inside its own Decision and leaves ADR-0014 accepted.

## Consequences

- N live cursors on one connection, each holding an open `Statement`/`ResultSet` and at most ~1001 rows of
  driver buffer, reclaimed no sooner than an hour after their last batch.
- No `-Xmx` is passed to gripd, so the bound on all of it together is the JVM's default maximum heap — a
  quarter of physical memory — and the failure mode is an `OutOfMemoryError` that the editor reports as
  "gripd stopped answering; restarting it", with no mention of memory. Passing an explicit heap limit is
  the obvious follow-up and is deliberately not decided here.
- The idle sweep is now the primary automatic reclamation and runs twelve times less often in effect, so
  it gets live coverage for the first time.
- An engine with a per-session open-cursor limit would now reach it instead of being protected by the cap.
  None of the drivers in play has one at any plausible number of grids.
- The eviction was asserted by a live test, which now asserts the opposite. That test has to close what it
  opens, because eviction used to clean up after it.
- The two places the cap was documented — `doc/protocol.md` and the comment in the tree's row listing that
  tells a client to collapse nodes so cursors are not evicted — both change.
