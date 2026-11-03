# 0038. Protocol 4: the catalog answers a client-built tree

- Date: 2026-11-03T20:26:00Z
- Status: Accepted

## Context

ADR-0036 made the navigation model data and ADR-0037 removed the plugin's explorer, which leaves the wire
answering a tree somebody else draws. Five things the catalog does today do not survive that change.

The kinds are a normalization the client no longer wants spelled its way (ADR-0036 closes the set at
three). Listings are **silently truncated**: `Snapshot.LIMIT = 500` caps catalogs, schemas and tables, and
nothing in the answer says a name was left out - in a tree that reads as missing data rather than as a
page. Listings come back in whatever order the driver used, so two refreshes can disagree. There is no way
to ask how many rows a table has, which is the decoration every explorer wants on a node. A collection's
fields come from `MongoFields.SAMPLE_SIZE = 100` documents read in natural order - `setMaxRows(100)` over
`find({})` - so the sample is biased toward the oldest documents and a field that only appears late does
not exist as far as this program is concerned. And `introspect` sweeps a whole instance into one file, so
re-reading one schema after a migration means re-reading all of them.

## Decision

Protocol version 4, with six changes.

- **Kinds collapse to three.** `Metadata.kind` answers `table`, `view` or `collection` and nothing else,
  per ADR-0036; the driver's own `TABLE_TYPE` is not carried. Materialized views become views; everything
  else selectable becomes a table.
- **Listings are ordered by name** by the server, in `Listings.catalogs/schemas/tables` and
  `Metadata.schemaNames`.
- **Listings page by keyset.** The three listings take an optional `after`, and `Rows<T>` gains
  `truncated`. `Snapshot.LIMIT` becomes a page size rather than a ceiling. There is no cursor state on the
  server: the ordering above is what makes "resume from the last name I received" exact and free.
- **`catalog/counts`** answers a map of set name to approximate row count for one namespace, in one query:
  `pg_class.reltuples`, `information_schema.TABLES.TABLE_ROWS`, `sys.dm_db_partition_stats`. Engines with
  no cheap estimate - sqlite, duckdb, trino, mongodb - answer an empty map rather than an error, and
  nothing runs `count(*)` on their behalf. There is no capability flag: the call is always there and
  answers what it can.
- **A collection is sampled at both ends**: fifty documents from the start and fifty from the end instead
  of the first hundred, so a field introduced late is seen. The answer carries `sampled` and `sample_size`,
  because a sampled field list is not a schema and a client must be able to say so. Whether both ends are
  reachable depends on the JDBC wrapper of ADR-0025 accepting `sort` and `limit` in its script; if it does
  not, the implementation keeps the head-only sample and records the refusal where the code reads.
- **Introspect takes a scope.** `catalog/introspect` accepts an optional `schema` and `table`; with them it
  sweeps that branch only and writes a partial snapshot the editor merges into what it already has.
  Without them it sweeps the whole instance into one file exactly as before, so ADR-0010 is untouched and
  the automatic sweep does not change at all. The scoped form exists for a manual re-introspection.

## Consequences

- A tree can be walked to the end: a schema with six hundred tables is six hundred names across two pages
  instead of five hundred and silence.
- Row counts arrive late and in batches, so a tree never blocks on them, and on four of eight engines they
  simply never arrive - the client shows no number rather than a wrong one.
- `foreign`, `partitioned` and `matview` stop being visible as such. That is the cost ADR-0036 accepted.
- Every client and every class tree must agree on 4: a plugin speaking 3 is refused at `initialize`, which
  is the protection ADR-0034 bought.
- The partial sweep introduces a second shape of snapshot file, which the editor's store has to merge
  rather than load. `store.merge_details` is the precedent that already does this for one table's details.
- Mongo's `count` per field now means "in how many of about a hundred documents from both ends", which is
  a different number than before for the same data. Nothing reads it as an absolute, but it is a changed
  answer to the same question.
