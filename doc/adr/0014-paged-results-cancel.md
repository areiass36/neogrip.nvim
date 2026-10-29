# 0014. Results are paged with a default row limit and queries are cancellable on the server

- Date: 2026-10-29T13:39:55Z
- Status: Accepted

## Context

Loading an unbounded result freezes the editor; paginating by rewriting SQL with `OFFSET` returns
inconsistent pages on a changing table and needs a dialect-specific clause per engine. The MVP's approach:
`setMaxRows(limit + offset + 1)` plus a client-side skip — one extra row reveals whether more exist without
a `count(*)`, with no SQL rewriting.

## Decision

Query results carry at most a configured row limit per page (default recorded in `config.lua`, an open
tuning point), fetched with the MVP's max-rows-plus-one technique. Pages travel as small protocol responses
(ADR-0010 covers everything bigger). Cancellation is real: the sidecar keeps the running `Statement` in an
atomic reference and `cancel` — answered on the read thread, never queued behind the query — calls
`Statement.cancel()` on the server. A configurable timeout cancels the same way; a client-side watchdog
only restarts a process that stopped answering entirely.

## Consequences

- Sorting must re-run the query on the server, or the order would only cover the fetched page.
- `Statement.cancel()` behavior varies by driver; every engine's cancel path gets a live test, including
  the MongoDB wrapper's.
- Paging re-executes the query, so a page boundary can show a changed world; that is the documented cost
  of not holding cursors open, and a cursor-per-result design remains a possible future ADR.
