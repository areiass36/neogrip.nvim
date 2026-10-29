# 0020. MongoDB enters through a third-party JDBC wrapper behind per-connection capabilities

- Date: 2026-10-29T13:39:55Z
- Status: Accepted

## Context

MongoDB is not SQL and has no official general-purpose JDBC driver. The available SQL-translating wrappers
are few, of mixed licence and maturity, and at least one bundles a GraalVM runtime that cannot share a
classpath (which ADR-0003's process-per-connection model absorbs). Dropping MongoDB was rejected: it is one
of the author's real databases. The MVP already ran a wrapper, which is evidence of feasibility but not of
licence fitness for a public plugin.

## Decision

MongoDB is supported through a third-party JDBC wrapper, isolated behind the same driver interface as every
engine, with the protocol's per-connection `capabilities` object (`sql`, `schemas`, `catalogs`,
`cancellation`, `transactions`) keeping the Lua side from assuming semantics the wrapper lacks. Before the
MongoDB phase starts, a short spike validates the chosen wrapper's licence, maturity, SQL translation and
cancellation behavior; its outcome is recorded as a new ADR naming the wrapper and version, and that ADR is
the go/no-go gate.

## Consequences

- The rest of the plugin never special-cases MongoDB; it reads capabilities.
- Schema-less collections make metadata and completion a sampling problem, handled by the catalog layer's
  document-sampling path rather than `getColumns`.
- If the spike fails every candidate wrapper, MongoDB slips out of scope with only this ADR's successor to
  write — no code to unwind.
