# 0029. MongoDB metadata through the wrapper is best-effort

- Date: 2026-10-29T20:30:00Z
- Status: Accepted

## Context

ADR-0025 accepted the DataGrip `mongo-jdbc-driver` wrapper with its maturity flagged as the standing risk,
and the first live CI run against a real mongod made the risk concrete. The wrapper's JDBC
`DatabaseMetaData.getTables` is unusable for sampled collections: it first trips TimSort's
"Comparison method violates its general contract", and with the JVM's legacy merge sort past that
(`-Djava.util.Arrays.useLegacyMergeSort=true`, which the sidecar now sets) it throws
`NumberFormatException: Cannot parse null string`. Listing collections through the wrapper's own script —
`db.getCollectionNames()` — works. But running that script and then a `db.<collection>.find({})` sample on
the same connection in sequence makes the sample come back empty: the script leaves per-session state the
next find does not survive. A `find` run first, with no prior script, samples fine (the live query suite
proves it). The two metadata needs — list collections, sample a collection's fields — cannot both be
satisfied through this wrapper on one connection session.

Everything that is not metadata works: connect, `find` queries and their document rendering, cancellation,
and collection listing. This is squarely the immaturity ADR-0025 anticipated, in one driver the project
does not control and does not redistribute.

## Decision

MongoDB metadata is best-effort. Collection listing uses `db.getCollectionNames()` (reliable). Field
sampling (`columns`) is attempted and used when it answers, but an empty sample is treated as "the wrapper
would not say" rather than an error: the explorer and completion degrade to names without field detail,
the same way they would for any engine that cannot describe a table. The live test suite, whose contract
is already "skip, never fail, when the engine cannot answer" (ADR-0023), notes an empty Mongo sample
rather than failing on it, so a real regression in the SQL engines still turns CI red while the wrapper's
known gap does not.

## Consequences

- The five SQL engines (PostgreSQL, MySQL, SQL Server, SQLite, DuckDB) keep full, asserted metadata in CI.
- MongoDB users get collection listing and querying; field detail appears when the wrapper manages a clean
  sample and is quietly absent when it does not, never as an error in the user's face.
- The limitation is the wrapper's, recorded here and surfaced in the README's limitations; a future ADR can
  supersede this if a better MongoDB JDBC driver appears (the capability flags already keep the Lua side
  from assuming field detail is present).
- `useLegacyMergeSort` is a process-wide JVM setting; it is harmless to the SQL drivers, which do not
  depend on TimSort's contract enforcement.
