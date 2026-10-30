# 0031. A result is a cursor the client names, continued instead of re-run

- Date: 2026-10-30T14:56:55Z
- Status: Accepted

## Context

ADR-0014 paged with `setMaxRows(limit + offset + 1)` and a client-side skip, which meant every page
re-executed the statement and threw away `offset` rows inside the sidecar after the server had already
produced and transferred them. Page N cost N x limit rows of server work; its own consequences section
said so and left "a cursor-per-result design remains a possible future ADR" open.

What DataGrip does, measured against that: the page-size limit is a JDBC row count, the total is never
counted unless asked, and turning a page re-queries with an offset the way we do - but inside one result
the grid grows from a `ResultSet` that stays open. The expensive half of our design is the half that had
no counterpart there.

Streaming - the server handing out rows before it has finished producing them - was examined and
rejected for now. On PostgreSQL a server-side cursor needs autocommit off, which ADR-0013 makes the
default on, which starts a real transaction on the session, which the idle-transaction watchdog would
roll back out from under a live cursor. Doing it correctly means the cursor lives on an extra connection
of its own (ADR-0012, accepted and still unimplemented) with a read-only transaction nobody asked for.
That is a second decision; it can be taken later without touching anything decided here, because the
protocol below cannot tell where the rows came from.

## Decision

A query result is a cursor the client names and continues.

The client mints an opaque hash and sends it with the statement. The sidecar answers the first batch and
keeps the `ResultSet` open, registered under that hash; `query` with the same hash and no `sql` returns
the next batch from it, and `done` says when there is nothing left. The hash is echoed in every response
as an assertion channel: appending the rows of one result into another result's grid is the silent
failure this design would otherwise have.

The client names the result rather than the sidecar, so the name exists before the first response and
can address a query that has not answered yet; `cancel {hash}` therefore cancels and closes one result,
while `cancel {}` keeps meaning "whatever is running". Re-using the JSON-RPC request id as the name was
rejected: the envelope's id is transport, and making it application state couples the two.

The sidecar pulls at most 1001 rows per execution - 1000 to hand out, one to reveal that the table has
more. When that window drains, the sidecar **refills**: it re-executes the same statement with a larger
row count and skips what it has already delivered. That is exactly the mechanism of ADR-0014, which stops
being the per-page cost and becomes the once-per-1000-rows cost - one re-execution every five pages at the
default limit of 200, rather than one per page. The window is what bounds memory: with autocommit on,
every driver examined either materialises the result or buffers it, so the row count given before
execution is the only lever over how much arrives.

Whether the opening execution takes the window depends on whether the client named the result. A named one
can be continued, so it opens with the window and the pages after the first come out of rows already in
hand. An unnamed one - a table preview, a completion sample, a probe - asks for the batch and one row
more, because pulling 1000 rows to show 5 would be a straight loss.

Opening a continuable result narrowly was tried first and measured against a Trino `GROUP BY` over a Delta
table: the second page drained the execution, refilled, and so paid the whole statement again - 226s for
the first page and 236s for the second. Opening with the window, that second page costs 4ms. The signal is
the hash: naming a result is the client saying it may ask for more of it.

`offset` leaves the wire. Forward paging is the cursor; the rows already shown stay in the grid's own
state, so going back a page is a redraw, not a request. The statement text is still never rewritten: the
window, the batches and the refill are all JDBC row counts and reads.

A document result (the MongoDB wrapper, ADR-0020) discovers its columns as it reads, so a later batch may
carry a grown `columns` list; the client replaces its own when it does, and a field absent from an earlier
document reads as NULL in that row, which is what it is.

Cursor lifetime, because an open `ResultSet` holds memory on both sides: `cancel {hash}` closes it, the
client closes the one it replaces, a cursor untouched for `cursorIdleSeconds` is closed by the watchdog
that already runs for idle transactions, at most four live cursors per connection are kept (the oldest is
closed first), and shutdown closes them all before the connection goes. Closing touches the connection, so
it happens under the session lock; the cancel that precedes it does not, because `Statement.cancel` is the
one JDBC call defined as safe from another thread.

This supersedes the paging mechanism of ADR-0014. Everything else in that record stands: the row limit per
page, never counting the total, real server-side cancellation, and the documented cost that a boundary
between two executions can show a changed world - which now happens once every window instead of once
every page.

## Consequences

- `protocolVersion` becomes 2: `query` gained `hash`, lost `offset`, and answers `done` where it answered
  `hasMore`; `cancel` gained an optional `hash`.
- Turning a page stops touching the server for five pages at the default limit of 200, and going back
  never touches it at all.
- The sidecar holds up to 1000 rows per open result. The window is counted in rows, not bytes, so a
  result of 1000 very wide rows is a different order of magnitude - a known limitation, not a knob.
- A refill re-executes, so the one place a changed world can still show up is every 1000 rows instead of
  every page.
- `cancel {hash}` waits for the session lock after cancelling, so it answers late while another statement
  holds the connection. It is sent fire-and-forget, and the read loop is never the thing waiting.
- Sorting still re-runs the statement on the server and so opens a new cursor, which is the same cost as
  before.
