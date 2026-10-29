# The neogrip sidecar

A standalone JSON-RPC program that speaks JDBC to databases. Neovim is its first client, not its owner:
anything that can pipe NDJSON JSON-RPC 2.0 over stdio can run it. The wire contract lives in
[doc/protocol.md](../doc/protocol.md); the decisions behind it in [doc/adr/](../doc/adr/README.md).

## Running it standalone

No build system (ADR-0004): compile with javac — `-parameters` is required, the server binds request
parameters by name — and pipe frames in:

```sh
javac -encoding UTF-8 -parameters -d build/classes $(find java -name '*.java')
printf '%s\n%s\n' \
  '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":1}}' \
  '{"jsonrpc":"2.0","id":2,"method":"ping"}' \
  | java -cp build/classes neogrip.app.App
```

Add a JDBC driver jar to the classpath and a `connect` frame, and every statement and catalog method is
available. Shutdown is the `shutdown` notification or EOF on stdin.

## Layout

| Package | What it is |
| --- | --- |
| `neogrip.rpc` | the RPC library: framing, handshake, lanes, envelopes, binding, the codec. Zero imports from the rest — the reason any client can talk to the program. |
| `neogrip.app` | the application shell: `App` (lifecycle as configuration), `Session` (connection control and metadata), and the handler classes. |
| `neogrip.db` | the database logic: `Database` (the lifecycle of everything executed, transactions included), statement/export/transaction units, `types/` (the wire's records), and `catalog/` (the DatabaseMetaData units). |

## The programming model

An RPC method is a plain annotated function; the Java method's own name is the wire name, prefixed by a
class-level `@RpcNamespace`. Parameters bind by name from the request's `params`; results are returned —
typed records serialized by `JsonCodec` (components in declaration order, nulls omitted, `@Json("is_pk")`
for wire spellings that are not Java ones), or `RpcResult<T>` where the answer is polymorphic or empty.
Errors are exceptions: throw `RpcException`, or let a mapped exception (SQLException, Refused) be
translated.

```java
@RpcNamespace("catalog")
final class CatalogHandlers {
    private final Database db;
    CatalogHandlers(Database db) { this.db = db; }        // constructor-injected by the builder

    @RpcMethod
    Rows<TableRow> tables(String catalog, String schema, String pattern) throws SQLException {
        return db.tables(catalog, schema, pattern);
    }

    @RpcMethod
    IntrospectSummary introspect(String catalog, String path, int parallelism, long budgetMs,
            boolean details) throws SQLException, IOException {
        return db.introspect(catalog, path, parallelism, budgetMs, details);
    }
}
```

Handlers declare nothing about threading - there is nothing to declare.

`App.main` is pure configuration: classes go into the builder, which instantiates them, resolving each
constructor parameter by type from the other components and the library's injectables (`Notifier`).
Components may implement `RpcLifecycle` for per-request and shutdown hooks; shutdown hooks run in reverse
registration order. Everything that can be wrong — a duplicate wire name, an unsupported signature, a
missing dependency, a build without `-parameters` — fails at `build()` with a message naming the
offender.

Adding a method is: declare a record in `neogrip/db/types/`, write an annotated function, done — the
dispatch, threading, binding and serialization are the library's.

## Threading

Every request runs on its own virtual thread (ADR-0028): the read loop never blocks, so ping and cancel
are always answerable mid-query. The one thing serialized is the shared session connection — a fair lock
inside `Database`, which `cancel` never takes (`Statement.cancel` is the one JDBC call defined as safe
from another thread) and the introspect sweep bypasses by running on sibling connections, one sweep at a
time. EOF drains the in-flight requests (bounded), then the shutdown hooks run: `Database` rolls back an
open transaction — never commits — before `Session` closes the connection.
