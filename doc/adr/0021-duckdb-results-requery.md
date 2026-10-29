# 0021. DuckDB is a supported database and the engine behind results requery

- Date: 2026-10-29T13:39:55Z
- Status: Accepted

## Context

The architectural proposal listed six server databases. The MVP additionally shipped DuckDB, and built the
plugin's most distinctive feature on it: any result page can be materialised to CSV and queried again with
SQL (`read_csv` views `r1`, `r2`, ... with a stable `last` alias), results composing into results. For a
plugin whose stated purpose is data manipulation, that feature is the point, and the author confirmed it
stays — including querying standalone CSV files and exporting.

## Decision

DuckDB is a first-class supported driver (file-based, no server), and the requery feature ships: a grid
page exports to a per-PID results directory, registers as a `read_csv` view (`all_varchar = true`, because
a type guess that turns an id into a float is worse than a string) in a per-PID scratch DuckDB file, and
opens a query buffer against a synthetic ephemeral connection that flows through the normal runner and
grid. Scratch and results files are deleted on exit, and a startup garbage collector removes leftovers
whose owning PID is gone or whose age exceeds the retention window.

## Consequences

- DuckDB's driver jar is a required download for the requery feature even for users of other engines; the
  feature degrades with a clear message when it is absent.
- Per-PID scratch files exist because a DuckDB file takes a single writer and its format is tied to the
  driver version; the GC is what keeps the state directory from accumulating corpses.
- Live DuckDB tests need no container, which gives CI real sidecar coverage on all three platforms.
