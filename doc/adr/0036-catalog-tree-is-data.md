# 0036. The catalog tree is data: six levels and a closed vocabulary

- Date: 2026-11-03T20:24:20Z
- Status: Accepted

## Context

The schema explorer was the plugin's own: `lua/neogrip/explorer/` held about 1700 lines in which one table
of levels carried four different concerns at once - loading data, presenting it, navigating to the level
below, and opening buffers. The data half of that was not reusable, because it downgraded records to
strings on the way out. The tables level received `{name, kind, schema, remarks, columns}` from the server
and answered with:

```lua
{ value = record.name, text = ("%s %s"):format(KIND_ICON[kind], record.name), hint = "12 columns" }
```

`remarks` and the column list were dropped, and a count became text. A different explorer would have had
to re-parse prose the plugin had formatted.

Two further facts shaped this record. The engine knowledge was trapped in the same file: `tree_of` knows
that sqlite and duckdb begin at tables, that mysql and mongodb have a database level, that Trino must
carry the catalog at every level (asked for all catalogs at once it answers with every catalog's schemas
and nothing saying which is which), and that a connection naming its database skips a level. And the two
vocabularies had already drifted apart without anyone noticing: the Java side emitted five kinds from
`Metadata.kind` while the Lua side decorated six, the extra one - `foreign` - being a kind nothing ever
produced.

Alternatives considered. Exposing the record accessors and nothing else (rejected: every client would
reimplement `tree_of`, so engine knowledge would leak into all of them). A level name per engine word -
`catalog` for Trino, `database` for mysql, `collection` for mongo (rejected: the vocabulary would grow per
engine and the client would have to handle words it had never heard). Passing the driver's own
`TABLE_TYPE` through untouched, with the enumerable set from `getTableTypes()` (considered seriously and
rejected: the grouping is what lets one renderer serve eight engines, and a raw string beside it was
decided to be noise the client would not read).

## Decision

The navigation model is data, in six levels that are a closed set:

```
server → instance → namespace → set → object → attribute
```

- Each level's node carries `id`, `level`, `kind`, `name`, `ref`, `expandable`, `source` and `facts`, and
  nothing formatted for a human: no icons, no padding, no "12 columns".
- `kind` per level: `server` is the driver; `instance` is `database` or `catalog`; `namespace` is `schema`;
  `set` is **only** `table`, `view` or `collection`; `object` is `row` or `document`; `attribute` is
  `column` or `field`.
- Everything a driver reports that is not a view or a collection is a `table`, which is the definition of
  that kind: anything selectable that is neither of the other two. Materialized views are views. Foreign,
  partitioned, temporary and system tables, aliases, sequences and indexes are tables. A `TABLE_TYPE` this
  program has never seen is a table.
- The driver's own word is **not** carried to the client. The grouping is the contract.
- What is a property rather than a nature is a fact, not a kind: `is_pk`, `nullable`, `generated`,
  `remarks`, `count`, `sampled`, `truncated`, `reconnects`.
- **Refs are absolute**: every ref carries the whole path - server, instance, namespace, set - whatever
  level its node sits at. No call depends on connection state, which is what answers Trino and what makes
  a scoped re-introspection addressable at all.
- Ids are stable strings built from the ref's segments with the separator percent-encoded, so a table
  named `a/b` cannot break one. They are what a client keys a cache, a diff or an extmark on.
- Listings are ordered by name, by the server. A client that wants another order sorts it itself.
- `shape(connection)` answers which levels this connection actually has, already truncated, with a label
  per level - so a client renders "Collections" for mongo and "Catalogs" for Trino without ever naming an
  engine, and recurses through one `children()` call for every level.
- Rows are in the vocabulary but not in the catalog: the `object` level is served by the named cursor of
  ADR-0031 and is never swept or cached.

## Consequences

- One renderer serves eight engines. Mongo stops being a special shape: in levels it is identical to
  mysql, differing only in kind and label.
- `foreign` and `partitioned` stop being distinguishable, and so do system objects, which the server keeps
  dropping. That information is now gone for good on the client side; recovering it later means a new
  fact, not a new kind.
- The explorer's `KIND_ICON` dies with the explorer (ADR-0037), and with it the drift it represented.
- `tree_of` and `entry_point` move into `shape()`, which is also what `:NGripIntrospect` and `:NGripDoctor`
  come to depend on.
- Adding a level later is a contract change, because the set is closed. Adding a fact is additive.
