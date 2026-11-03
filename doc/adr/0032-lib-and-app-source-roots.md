# 0032. The Java tree is a lib root and an app root with one dependency direction

- Date: 2026-11-03T15:12:40Z
- Status: Accepted

## Context

ADR-0027 gave the Java side an internal RPC library with zero imports from the application, and that half
held: `neogrip.rpc` imports nothing of ours. The other half did not. Measured on the tree this record
replaces - 40 files, 3699 lines - fourteen imports cross the boundary in the wrong direction:

- `db/Database.java` imports `neogrip.app.Session`, so the layer that executes statements depends on the
  shell that hosts it, and reads the live connection out of it through a lazy `bind()` with ten `volatile`
  fields.
- `db/Errors.java`, `db/Cursors.java` and `db/catalog/Introspect.java` import `RpcException` and `Wire`
  only to name an error code.
- `db/Exports.java` and `db/catalog/Introspect.java` import `JsonCodec` and `JsonStream` only to write
  JSON into a file, which is how writing a file came to depend on the transport.
- `db/types/Types.java` imports the `Json` annotation, so the records the domain returns carry a
  serialization concern.

`Wire` itself carries the application inside the library: `PROTOCOL_VERSION`, `SQL_ERROR`, `AUTH_ERROR`,
`READONLY_REFUSED` and `CANCELLED` are facts about this program, and `RpcServer` hard-codes the
`initialize` handshake and calls `System.exit(1)` - a library killing its host's process.

Alternatives considered: JPMS `module-info.java`, which would have the compiler enforce the boundary
(rejected - `--module-source-path` and one output tree per module fight the single javac-on-first-use
compile of ADR-0004); one source root with ring-named packages (rejected - that is exactly today's
`neogrip.app`/`neogrip.db`, and a package named after a ring is what let `neogrip.app.Session` accumulate
JDBC); packages literally named `lib.*` and `app.*` so the ring shows in every import (rejected - a
package named after a layer says nothing about what it is, and a library extracted later would have to be
renamed, which is the opposite of the goal).

## Decision

Two source roots under `java/`, and one direction of dependency.

- `java/lib/` holds what any program could use: `neogrip.jsonrpc` (framing, dispatch, binding, envelopes,
  transports), `neogrip.dataformat` (ADR-0033) and `neogrip.inject` (the constructor-injection container
  extracted from `RpcServer.Builder`).
- `java/app/` holds this program: `neogrip.gripd` (ADR-0034), in three rings - `domain`, `application`
  (use cases and ports), `adapter` (`jdbc`, `export`, `rpc`).
- The arrows: `gripd` → `jsonrpc` → `dataformat`; `inject` depends on nothing; **nothing imports
  `neogrip.gripd`**. Inside the app, `domain` and `application` import neither the libraries nor
  `java.sql`; only `adapter` does.
- A port never leaks `SQLException`: the JDBC adapter translates it into an unchecked domain exception
  carrying SQLState, vendor code and position, and the RPC adapter turns that into the error envelope.
- The records that go on the wire are the protocol's DTOs and live in `adapter/rpc/contract` with their
  `@JsonName` spellings. A parallel domain hierarchy with 1:1 mappers was rejected: forty types for no
  behavior, and the wire deliberately mixes `camelCase` and `snake_case`, so no global naming strategy
  replaces the annotation.
- `lib` and `app` are a directory convention, not compiler configuration. One `javac` invocation still
  receives every file and writes one `-d` tree, now with two package roots.
- The boundary is checked by grep, in CI and in review: no file under `java/lib` may contain
  `import neogrip.gripd.`, and no file under `domain` or `application` may import a library package.

## Consequences

- "A program any JSON-RPC client can run" stops being a comment and becomes structural: the library has
  no way to name this application.
- `Database` dissolves along its seams - execution lane, cursor registry, idle watchdog, use cases - and
  the lazy `bind()` with its ten `volatile` fields disappears, because a connection scope is built at
  connect and replaced whole.
- Handlers stop declaring `throws SQLException, IOException`.
- The file count grows again (~40 → ~60) and blame breaks across the moves, as it did in ADR-0027.
- The boundary is a convention: a determined import still compiles. The grep is the guard, and it is only
  as good as the CI step that runs it.
- ADR-0027's programming model does not move - annotated functions, named binding, typed records,
  classes into the builder. This record changes where things live and which way the arrows point.
