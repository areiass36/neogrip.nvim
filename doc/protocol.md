# The neogrip wire protocol

The contract between the Lua plugin and the Java sidecar. This document is the source of truth: a change
here bumps `protocolVersion`, is recorded in an ADR first, and lands in the same commit as both
implementations (`lua/neogrip/rpc/` and `java/neogrip/`).

Current `protocolVersion`: **2**.

## Transport and framing

- JSON-RPC 2.0 over the sidecar process's stdin/stdout (ADR-0001, ADR-0002).
- One JSON object per line, UTF-8, LF-terminated. JSON encoders never emit a raw newline inside a
  document, so content cannot break the framing.
- The sidecar's stdout carries protocol frames and nothing else; logs and driver noise go to stderr. The
  client still skips any stdout line that does not parse as a JSON object, because JDBC drivers
  occasionally print banners there.
- Bulk data (catalog snapshots, exports) never travels in frames: the request names an absolute file path
  and the sidecar writes it with temp-plus-atomic-rename (ADR-0010).

## Ids

- Client requests: monotonically increasing integers, starting at 1 per process.
- Sidecar-initiated requests: strings prefixed `sv-` (`"sv-1"`, `"sv-2"`, ...), so the two id spaces can
  never collide.
- Notifications carry no `id`.

## Lifecycle

1. The client spawns the sidecar with an argv that contains nothing database-related (ADR-0009).
2. The first request must be `initialize`. Anything else before it is answered with error `-32002`.
3. After `initialize`, exactly one `connect` establishes the JDBC connection.
4. Shutdown is the `shutdown` notification followed by closing the sidecar's stdin. EOF makes the sidecar
   drain in-flight work (bounded), close the connection — rolling back any open transaction, never
   committing — and exit (ADR-0003). The client keeps a SIGTERM after 500 ms as a backstop.

## Threading contract (sidecar side)

Every request runs on its own thread, so the read loop never blocks and `ping`/`cancel` are always
answerable while a statement runs (ADR-0028). What is serialized is the shared JDBC connection - the
session (ADR-0012): statements and catalog questions take its lock one at a time, in arrival order;
`cancel` never takes it, which is what lets it reach the running statement. `catalog/introspect` runs one
sweep at a time, outside the lock, on sibling connections of its own.

## Methods (client → sidecar)

### initialize

```json
→ {"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":2,"clientInfo":{"name":"neogrip.nvim"}}}
← {"jsonrpc":"2.0","id":1,"result":{"protocolVersion":2,"sidecarInfo":{"java":"21.0.3"}}}
```

A major-version mismatch is refused with error `-32002` and the sidecar exits.

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
`managed_identity` are carried by the schema and refused by the sidecar with `-32011` until their phase
lands. `transactionIdleSeconds` arms the idle-transaction watchdog (ADR-0013); zero disables it.
`cursorIdleSeconds` is how long an untouched open result is kept before the same watchdog closes it
(ADR-0031); zero disables that sweep.

### Statements

- `query {hash, sql, limit, timeoutSeconds}` → `{hash, columns:[{name,type,table,schema}], rows:[[...]],
  done, elapsedMs}` — at most `limit` rows per batch; cell values are strings, numbers, booleans or null,
  rendered per `java/neogrip/db/Values.java`'s rules. A result is a cursor the client names: see
  [Cursors](#cursors).
- `query {hash, limit}` → `{hash, rows, done, elapsedMs}` — the next batch of the result named `hash`.
  No `sql` is what makes it a continuation rather than a new statement.
- `exec {sql, timeoutSeconds}` → `{updateCount, elapsedMs}`
- A plain `BEGIN`/`COMMIT`/`ROLLBACK` sent as `query` or `exec` is intercepted and mapped to the JDBC
  calls (ADR-0013); the result is `{transaction: true|false}` saying whether the session now has one open.
  Any other spelling passes through untouched.
- `validate {sql}` → `{}` — a server-side prepare, parses but never executes.
- `export {sql, path, format, nullMarker, timeoutSeconds}` → `{rows, path}` — streams to `path`,
  format `csv` or `json`.

### Control

- `ping {}` → `{}`
- `cancel {}` → `{cancelled}` — calls `Statement.cancel()` on whatever is running. Takes no lock, so it
  is answerable while a statement holds the connection.
- `cancel {hash}` → `{cancelled}` — cancels and closes one result (ADR-0031). The cancel itself takes no
  lock either; the close that follows it does, so this answers late while another statement is running.

## Cursors

A `query` carrying `sql` opens a result and the sidecar keeps its `ResultSet` open, registered under the
`hash` the client minted for it (ADR-0031). `query` with the same `hash` and no `sql` returns the next
batch; `done` is true when the result has no more rows, and the sidecar has then already closed it.

- The `hash` is an opaque string the client chooses, and the sidecar never interprets it. It is echoed in
  every response so a client can assert it is appending the right rows to the right result.
- `done: false` means the hash is still valid. A `hash` that is unknown, or already finished, is
  `-32600`; so is opening a second result under a hash that is still live.
- A named result opens with the window: the sidecar pulls at most 1001 rows per execution, 1000 to hand
  out and one to learn the table has more, so the pages after the first cost nothing. A `query` with no
  `hash` asks for `limit + 1` instead, which is what a preview or a sample wants. When the window drains
  the sidecar re-executes the same statement and skips what it already delivered, keeping the same hash.
  The client is not told - a refill is indistinguishable from a continuation.
- A document result (ADR-0020) discovers its columns while reading, so a continuation may carry a grown
  `columns` list. When it does, the client replaces its own; a field absent from an earlier document is
  null in that row.
- `limit: 0` means "everything": no cursor is kept and `done` is true.
- Lifetime: `cancel {hash}`, `cursorIdleSeconds` of no use, at most four live per connection (oldest
  closed first), and all of them on shutdown.

### Catalog

- `catalog/catalogs {}`, `catalog/schemas {catalog?}`, `catalog/tables {catalog?, schema?}`,
  `catalog/columns {catalog?, schema?, table}` → small listings.
- `catalog/details {catalog?, schema?, table}` → keys, indexes, references for one table.
- `catalog/ddl {catalog?, schema?, table}` / `catalog/nativeDdl {...}` → rendered definitions.
- `catalog/snapshot {catalog?, schema}` → `{rows}` — one whole schema (every table with its columns) in a
  single round trip; small enough to ride in-band.
- `catalog/introspect {catalog?, path, parallelism, budgetMs, details}` → `{schemas, tables, columns,
  details, partial, parallel, elapsedMs}` — the deep sweep of the whole catalog, written to `path`
  file-side (ADR-0010), honouring the time budget and the cancel flag.

### shutdown (notification)

```json
→ {"jsonrpc":"2.0","method":"shutdown"}
```

## Messages (sidecar → client)

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
