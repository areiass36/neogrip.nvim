# The neogrip wire protocol

The contract between the Lua plugin and the Java sidecar. This document is the source of truth: a change
here bumps `protocolVersion`, is recorded in an ADR first, and lands in the same commit as both
implementations (`lua/neogrip/rpc/` and `java/neogrip/`).

Current `protocolVersion`: **1**.

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

`initialize`, `ping`, `cancel` and `shutdown` are answered on the read thread, so a `cancel` is always
answerable while a statement runs. `connect`, statements and catalog requests run on a single worker;
`catalog/introspect` runs on its own single-thread executor, one sweep at a time. Two statements never
touch the shared JDBC connection concurrently (ADR-0012).

## Methods (client → sidecar)

### initialize

```json
→ {"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":1,"clientInfo":{"name":"neogrip.nvim"}}}
← {"jsonrpc":"2.0","id":1,"result":{"protocolVersion":1,"sidecarInfo":{"java":"21.0.3"}}}
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

### Statements

- `query {sql, limit, offset, timeoutSeconds}` → `{columns:[{name,type,table,schema}], rows:[[...]],
  hasMore, elapsedMs}` — at most `limit` rows per page (ADR-0014); cell values are strings, numbers,
  booleans or null, rendered per `java/neogrip/Values.java`'s rules.
- `exec {sql, timeoutSeconds}` → `{updateCount, elapsedMs}`
- `validate {sql}` → `{}` — a server-side prepare, parses but never executes.
- `export {sql, path, format, nullMarker, timeoutSeconds}` → `{rows, path}` — streams to `path`,
  format `csv` or `json`.

### Control (read thread)

- `ping {}` → `{}`
- `cancel {}` → `{cancelled}` — calls `Statement.cancel()` on whatever is running.

### Catalog

- `catalog/catalogs {}`, `catalog/schemas {catalog?}`, `catalog/tables {catalog?, schema?}`,
  `catalog/columns {catalog?, schema?, table}` → small listings.
- `catalog/details {catalog?, schema?, table}` → keys, indexes, references for one table.
- `catalog/ddl {catalog?, schema?, table}` / `catalog/nativeDdl {...}` → rendered definitions.
- `catalog/snapshot {catalog, path}` → `{tables}` — the full snapshot goes to `path`, file-side.
- `catalog/introspect {catalog, path, parallelism, budgetMs, details}` → `{tables, partial}` — the deep
  sweep, written to `path`, honouring the time budget and the cancel flag.

### shutdown (notification)

```json
→ {"jsonrpc":"2.0","method":"shutdown"}
```

## Messages (sidecar → client)

- Notification `status {phase, message}` — connection progress, authentication steps ("browser opened"),
  token refresh.
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
