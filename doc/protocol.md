# The neogrip wire protocol

The contract between the Lua plugin and gripd, its Java daemon. This document is the source of truth: a change
here bumps `protocolVersion`, is recorded in an ADR first, and lands in the same commit as both
implementations (`lua/neogrip/rpc/` and `java/app/neogrip/gripd/`).

Current `protocolVersion`: **4**.

## Transport and framing

- JSON-RPC 2.0 over gripd process's stdin/stdout (ADR-0001, ADR-0002).
- One JSON object per line, UTF-8, LF-terminated. JSON encoders never emit a raw newline inside a
  document, so content cannot break the framing.
- Gripd's stdout carries protocol frames and nothing else; logs and driver noise go to stderr. The
  client still skips any stdout line that does not parse as a JSON object, because JDBC drivers
  occasionally print banners there.
- Bulk data (catalog snapshots, exports) never travels in frames: the request names an absolute file path
  and gripd writes it with temp-plus-atomic-rename (ADR-0010).

## Ids

- Client requests: monotonically increasing integers, starting at 1 per process.
- Gripd-initiated requests: strings prefixed `sv-` (`"sv-1"`, `"sv-2"`, ...), so the two id spaces can
  never collide.
- Notifications carry no `id`.

## Lifecycle

1. The client spawns gripd with an argv that contains nothing database-related (ADR-0009).
2. The first request must be `initialize`. Anything else before it is answered with error `-32002`.
3. After `initialize`, exactly one `connect` establishes the JDBC connection.
4. Shutdown is the `shutdown` notification followed by closing gripd's stdin. EOF makes gripd
   drain in-flight work (bounded), close the connection — rolling back any open transaction, never
   committing — and exit (ADR-0003). The client keeps a SIGTERM after 500 ms as a backstop.

## Threading contract (gripd side)

Every request runs on its own thread, so the read loop never blocks and `ping`/`cancel` are always
answerable while a statement runs (ADR-0028). What is serialized is the shared JDBC connection - the
session (ADR-0012): statements and catalog questions take its lock one at a time, in arrival order;
`cancel` never takes it, which is what lets it reach the running statement. `catalog/introspect` runs one
sweep at a time, outside the lock, on sibling connections of its own.

## Methods (client → gripd)

### initialize

```json
→ {"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":4,"clientInfo":{"name":"neogrip.nvim"}}}
← {"jsonrpc":"2.0","id":1,"result":{"protocolVersion":4,"gripdInfo":{"java":"21.0.3"}}}
```

A major-version mismatch is refused with error `-32002` and gripd exits.

### connect

```json
→ {"method":"connect","params":{
     "url":"jdbc:postgresql://host:5432/app",
     "properties":{"connectTimeout":"10"},
     "auth":{"type":"password","user":"fulano","password":"..."},
     "readonly":true}}
← {"result":{"product":"PostgreSQL 16.2","driver":"PostgreSQL JDBC Driver 42.7.3",
     "capabilities":{"sql":true,"schemas":true,"catalogs":false,"cancellation":true,"transactions":true}}}
```

The one frame that carries secrets (ADR-0009): the auth object's secret-bearing fields are `password`,
`client_secret`, `token` and `passphrase`, resolved from kvstore key names on the Lua side. Neither side
ever logs or echoes its params. Capabilities are per connection and the client must consult them instead
of assuming SQL semantics (ADR-0020).

Implemented auth types: `none`, `password`, and `token` (a bearer token handed to the driver's
`accessToken` property - SQL Server and Trino both read it). `entra_interactive`, `service_principal` and
`managed_identity` are carried by the schema and refused by gripd with `-32011` until their phase
lands. `transactionIdleSeconds` arms the idle-transaction watchdog (ADR-0013); zero disables it.
`cursorIdleSeconds` is how long an untouched open result is kept before the same watchdog closes it
(ADR-0031); zero disables that sweep.

### Statements

- `query {hash, sql, limit, timeoutSeconds}` → `{hash, columns:[{name,type,table,schema}], rows:[[...]],
  done, elapsedMs}` — at most `limit` rows per batch; cell values are strings, numbers, booleans or null,
  rendered per `java/app/neogrip/gripd/adapter/jdbc/Values.java`'s rules. A result is a cursor the client names: see
  [Cursors](#cursors).
- `query {hash, limit}` → `{hash, rows, done, elapsedMs}` — the next batch of the result named `hash`.
  No `sql` is what makes it a continuation rather than a new statement.
- `exec {sql, timeoutSeconds}` → `{updateCount, elapsedMs}`
- A plain `BEGIN`/`COMMIT`/`ROLLBACK` sent as `query` or `exec` is intercepted and mapped to the JDBC
  calls (ADR-0013); the result is `{transaction: true|false}` saying whether the session now has one open.
  Any other spelling passes through untouched.
- `validate {sql}` → `{}` — a server-side prepare, parses but never executes.
- `export {sql, path, format, nullMarker, timeoutSeconds}` → `{rows, path}` — streams to `path`,
  format `csv` (the default when absent) or `json`; any other name is refused.

### Control

- `ping {}` → `{}`
- `cancel {}` → `{cancelled}` — calls `Statement.cancel()` on whatever is running. Takes no lock, so it
  is answerable while a statement holds the connection.
- `cancel {hash}` → `{cancelled}` — cancels and closes one result (ADR-0031). The cancel itself takes no
  lock either; the close that follows it does, so this answers late while another statement is running.

## Cursors

A `query` carrying `sql` opens a result and gripd keeps its `ResultSet` open, registered under the
`hash` the client minted for it (ADR-0031). `query` with the same `hash` and no `sql` returns the next
batch; `done` is true when the result has no more rows, and gripd has then already closed it.

- The `hash` is an opaque string the client chooses, and gripd never interprets it. It is echoed in
  every response so a client can assert it is appending the right rows to the right result.
- `done: false` means the hash is still valid. A `hash` that is unknown, or already finished, is
  `-32600`; so is opening a second result under a hash that is still live.
- A named result opens with the window: gripd pulls at most 1001 rows per execution, 1000 to hand
  out and one to learn the table has more, so the pages after the first cost nothing. A `query` with no
  `hash` asks for `limit + 1` instead, which is what a preview or a sample wants. When the window drains
  gripd re-executes the same statement and skips what it already delivered, keeping the same hash.
  The client is not told - a refill is indistinguishable from a continuation.
- A document result (ADR-0020) discovers its columns while reading, so a continuation may carry a grown
  `columns` list. When it does, the client replaces its own; a field absent from an earlier document is
  null in that row.
- `limit: 0` means "everything": no cursor is kept and `done` is true.
- Lifetime: `cancel {hash}`, `cursorIdleSeconds` of no use, and all of them on shutdown. There is no cap
  on how many are live per connection (ADR-0041): a client that stops closing holds one open statement
  each until the sweep reaches them, and nothing evicts on its behalf.

### Catalog

- `catalog/catalogs {after?, limit?}`, `catalog/schemas {catalog?, after?, limit?}`,
  `catalog/tables {catalog?, schema?, pattern?, after?, limit?}`,
  `catalog/columns {catalog?, schema?, table}` → small listings.
- The three name listings are **ordered by name** and **paged by keyset** (ADR-0038): `limit` is the page
  size (500 when absent), `after` is the last name the client received, and the answer carries
  `truncated: true` when a page was cut. Paging is stateless on the server — the ordering is what makes
  resuming exact. `catalog/columns` is not paged: columns have a declared position and keep it.
- A driver that reports its databases as **catalogs** — MySQL and MariaDB, where `catalog/schemas` answers
  nothing at all — has the `schema` of a `catalog/tables` request read as its catalog when the request
  carries no catalog. The client keeps one namespace slot per engine and puts the database in it; MySQL's
  own `getTables` ignores a schema argument, which surfaced as a listing of the `sys` views instead of the
  two tables in the database asked for.
- A listed table's `kind` is one of exactly three (ADR-0036): `table`, `view` or `collection`. A
  materialized view is a `view`; everything else selectable - foreign, partitioned, temporary, system, an
  alias, a sequence, a type no driver here has reported before - is a `table`. The engine's own
  `TABLE_TYPE` is not carried.
- A collection has no columns, so `catalog/columns` answers its **sampled fields** instead: fifty
  documents from each end of the collection, deduplicated by `_id` (ADR-0038). Each field carries `count`
  - in how many of the sampled documents it appeared with that type - and `sample_size`, how many
  documents were actually read. A field holding two types is reported once per type. This is a sample and
  not a schema: a field only present in documents the windows did not reach is not listed.
- `catalog/counts {catalog?, schema}` → `{counts}` — a map of set name to approximate row count for one
  namespace, in one statement (ADR-0038). A set the engine keeps no estimate for is absent rather than
  zero, and an engine that keeps none at all - sqlite, duckdb, trino, the Mongo wrapper - answers `{}`:
  nothing here runs `count(*)` on a client's behalf. PostgreSQL answers nothing for a table that has never
  been analysed, because `reltuples` is -1 there and that is not an estimate.
- `catalog/details {catalog?, schema?, table}` → keys, indexes, references for one table.
- `catalog/ddl {catalog?, schema?, table}` / `catalog/nativeDdl {...}` → rendered definitions.
- `catalog/snapshot {catalog?, schema}` → `{rows}` — one whole schema (every table with its columns) in a
  single round trip; small enough to ride in-band.
- `catalog/introspect {catalog?, schema?, path, parallelism, budgetMs, details}` → `{schemas, tables, columns,
  details, partial, parallel, elapsedMs}` — the deep sweep of the whole catalog, written to `path`
  file-side (ADR-0010), honouring the time budget and the cancel flag.
- `schema` scopes that sweep to one namespace (ADR-0038): what it writes is a snapshot holding that
  schema alone, which the client folds into the catalog it already has instead of replacing it - for a
  manual re-introspection after a migration. A name nothing matches sweeps nothing and says so in the
  counts, which is how a dropped schema reports itself. Without `schema`, the whole catalog is swept into
  one file exactly as before.

### shutdown (notification)

```json
→ {"jsonrpc":"2.0","method":"shutdown"}
```

## Messages (gripd → client)

- Notification `status {phase, message}` — connection progress, authentication steps ("browser opened"),
  and the idle-transaction watchdog's rollback notice.
- Notification `log {level, message}` — sparse; never anything derived from `connect` params.
- Request `input {prompt, secret}` → `{value}` — reserved for authentication flows that need user input
  (device code). The client answers asynchronously.

## Errors

Standard JSON-RPC error objects: `{code, message, data?}`. Driver detail rides in `data` with the fields
`state` (SQLState), `vendorCode`, `position` (0-based character offset into the statement, when the server
reports one) and `line` (1-based, when that is all the server gives).

| Code | Meaning |
| --- | --- |
| -32700 | parse error |
| -32600 | invalid request |
| -32601 | method not found |
| -32002 | protocol version mismatch |
| -32010 | SQL error (driver detail in `data`) |
| -32011 | authentication error |
| -32012 | statement refused: connection is readonly |
| -32013 | statement cancelled |

Client-side synthetic errors (never sent on the wire): `-32098` client closed, `-32099` process exited.
