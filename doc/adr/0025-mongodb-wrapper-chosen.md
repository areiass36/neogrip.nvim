# 0025. The MongoDB wrapper is DataGrip's mongo-jdbc-driver 1.21

- Date: 2026-10-29T18:30:00Z
- Status: Accepted

## Context

ADR-0020 gated MongoDB support on a spike validating a concrete wrapper. The candidates were MongoDB's own
JDBC driver (requires the Atlas SQL interface, which a plain mongod does not have), the commercial wrappers
(licence unfit for a dependency of an MIT plugin), and JetBrains' DataGrip driver — the one DataGrip itself
ships, which translates a mongosh-like script language rather than SQL and talks to a plain mongod.

Checked against the source repository on 2026-10-29: licence Apache-2.0, not archived, last pushed
2026-08-17, latest release v1.21 (2025-11-17) — the exact artifact pinned in
`lua/neogrip/bootstrap/jdbc.lua` with its SHA-256. The predecessor MVP ran this wrapper against a real
mongod, including the document-spreading result path (`java/neogrip/Documents.java`), which is evidence of
functional maturity. It bundles a GraalVM JavaScript engine, which is exactly why ADR-0003's
process-per-connection classpath isolation exists.

## Decision

MongoDB ships through `mongo-jdbc-standalone-1.21.jar` (Apache-2.0), pinned and checksum-verified. The
connection's capabilities object keeps the Lua side honest about what it is (`sql` describes the script
dialect the wrapper accepts, `schemas` false); columns come from sampling documents, not `getColumns`.

## Consequences

- The gate in ADR-0020 is passed; the MongoDB path in the drivers table is live.
- `Statement.cancel()` behavior on the wrapper remains observed only through the live suite when the mongo
  container is up (CI's live job); a driver that will not cancel falls back to killing the process.
- The wrapper's ~40 MB download (GraalVM inside) is the price of talking to a plain mongod.
- A wrapper release is a deliberate bump: version and checksum together, licence re-checked.
