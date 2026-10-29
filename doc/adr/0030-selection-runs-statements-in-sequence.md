# 0030. A selection of several statements runs them in sequence

- Date: 2026-10-29T21:38:10Z
- Status: Accepted

## Context

The statement under the cursor is isolated by the lexer (ADR-0015) and is always a single statement with
no terminator. A visual selection took a different path: it was sent verbatim with only a trailing `;`
stripped. A selection that held more than one statement therefore reached the driver as one string with
an internal `;` still in it.

Most engines tolerate that; Trino does not. It rejects the internal terminator outright with
`mismatched input ';'. Expecting: <EOF>`, pointing at the exact byte of the first `;`. The driver contract
is in fact one statement per call for every engine the plugin targets: JDBC's `executeQuery` runs one
statement, and the subquery the sort wraps around a result (ADR-0014) is only well-formed around one.

So a selection of two statements could not run at all, and the error named a byte offset rather than the
real cause.

## Decision

A unit of execution is always one statement. The lexer already splits a selection into statements
(ADR-0015); `execute.run` now splits whatever text it is about to run and, when there is more than one,
runs them as a sequence against the one connection: each in turn, each as its own call with its terminator
removed, stopping at the first error. This is how a SQL console behaves. Only the last statement's rows
reach the grid, so paging and sorting (ADR-0014) still wrap exactly one statement; the earlier statements
report their row or update counts in a notification. A rerun for a different page or sort carries its own
single statement and stays on the single path untouched.

## Consequences

- A selection of several statements runs, instead of failing on the first internal `;`.
- The grid shows one result, the last. A script of many selects does not open many grids; the earlier
  results are summarised, not displayed. This matches the single-result-buffer model and keeps paging
  unambiguous.
- Execution stops at the first statement that errors, leaving the ones after it unrun, as a console does.
- The sequence is driven one statement at a time through the existing per-connection queue, so cancel,
  the readonly refusal and the transaction interception all apply per statement with no new machinery.
