# 0039. The catalog is part of the name on Trino, not part of the connection

- Date: 2026-11-04T18:45:00Z
- Status: Accepted

## Context

ADR-0036 made every ref absolute — the whole path at every level — and gave as the reason that this is
"what resolves Trino's ambiguity". ADR-0036 also put `reconnects` among the facts a level can carry, and
`tree.shape()` sets it on the `instance` level of every engine that has one.

Both of those are right for PostgreSQL and SQL Server and wrong together for Trino, which the live suite
measured as soon as Trino became a fixture:

```
ref:     { server, instance = "tpch", namespace = "tiny", set = "nation" }
name:    "tiny"."nation"
runs?    NO: line 1:15: Catalog must be specified when session catalog is not set
```

A SQL name has at most three parts, and they are exactly the tree's `instance.namespace.set`. Where the
connection pins the instance, two parts are the whole name and the third is redundant; where it does not,
the third is required. Which engine is which is not a style question:

- **PostgreSQL** cannot query across databases at all. Walking into another one means opening a second
  connection pointed at it, and after that two-part names are correct. `reconnects = true` is the honest
  label, and qualifying with the catalog would be at best redundant and at worst a `cross-database
  references are not implemented` error.
- **MySQL and MariaDB** report the database as a catalog and have no schema layer, so the plugin already
  puts the database in the namespace slot and already emits `` `db`.`table` ``. Nothing to change.
- **Trino** addresses catalogs in SQL and queries across them in one session. That is the reason the engine
  exists. Reconnecting per catalog would throw away the capability, and the name is the only place the
  choice can land.

So `reconnects = true` on Trino's instance level is advice that cannot be followed usefully, and dropping
the instance from the name leaves a client with a tree that walks correctly and a statement that does not
run. Nothing in the plugin reads `reconnects` — it is written in four places and consumed nowhere, because
the client draws the explorer (ADR-0037) — which is why the flag being wrong was invisible.

## Decision

The catalog is part of a qualified name where the engine addresses catalogs in SQL, and part of the
connection everywhere else.

- `schema.qualify` takes an optional fourth argument, the catalog, and emits three parts for Trino and two
  for everyone else. Absent, it falls back to `schema.catalog_of(connection)`, so the nine existing call
  sites keep their behavior and a Trino connection that names its catalog keeps working as before.
- `schema.select_statement` and `sql.statement.for_set` pass a catalog through, and `tree.qualified_name`
  and `tree.statement` supply the one the ref carries. The ref was already absolute; this is what makes
  that worth something.
- Trino's `instance` level no longer claims `reconnects`. Walking into a catalog changes the names the tree
  writes, not the connection underneath it.
- `reconnects` gets the documentation it never had: it means the connection has to be reopened pointed at
  that instance before anything in it can be queried, and it is a hint for the client, not a thing the
  plugin does.

A `select` on the engines that pin the instance is byte-for-byte what it was; this is deliberately not a
general "always qualify fully" change, because on PostgreSQL that is an error rather than a longer name.

## Consequences

- A Trino connection with no catalog in its connection file now generates runnable SQL from the tree, which
  is the configuration the instance level exists for.
- A client that was reconnecting per Trino catalog on the strength of `reconnects` keeps working — it just
  no longer has to, and `shape()` stops telling it to.
- `schema.qualify` grew a parameter. It is optional and last, so every existing caller is unchanged, but
  the paths that rebuild SQL from a result rather than from a ref — `grid/actions.lua` for requery and cell
  edits, `render.lua` for DDL, `document.lua` for its header — only qualify fully when the connection names
  the catalog. They have no ref to take one from. On a catalog-less Trino connection those paths still emit
  two-part names; closing that needs the result metadata to carry the catalog, which is a separate change.
- The engine-by-engine reasoning above now has exactly one home. Adding an engine means answering one
  question: does a query name the catalog, or does the connection?
