# gripd

A standalone JSON-RPC program that speaks JDBC to databases. Neovim is its first client, not its owner:
anything that can pipe NDJSON JSON-RPC 2.0 over stdio can run it. The wire contract lives in
[doc/protocol.md](../doc/protocol.md); the decisions behind it in [doc/adr/](../doc/adr/README.md).

## Running it standalone

No build system (ADR-0004): compile with javac — `-parameters` is required, the server binds request
parameters by name — and pipe frames in:

```sh
javac -encoding UTF-8 -parameters -d build/classes $(find java -name '*.java')
printf '%s\n%s\n' \
  '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":5}}' \
  '{"jsonrpc":"2.0","id":2,"method":"ping"}' \
  | java -cp build/classes neogrip.gripd.Daemon
```

Add a JDBC driver jar to the classpath and a `connect` frame, and every statement and catalog method is
available. Shutdown is the `shutdown` notification or EOF on stdin.

## Layout

| Package | What it is |
| --- | --- |
| `neogrip.dataformat` | `java/lib` - the format library: one `RecordWriter` per format, with the JSON writer, parser and reflective mapper under `json/` and RFC 4180 quoting under `csv/`. Knows nothing of this program (ADR-0033). |
| `neogrip.jsonrpc` | `java/lib` - the RPC library: framing, dispatch, named binding, envelopes, transports, the virtual-thread lane. No contract of its own (ADR-0032). |
| `neogrip.inject` | `java/lib` - the dependency container: classes in, singletons out, constructor-injected by type. |
| `neogrip.gripd` | `java/app` - the program itself: `Daemon` is the composition root and nothing else is constructed by hand. |
| `neogrip.gripd.domain` | the rules that need nothing open: the read-only policy, which spellings are a transaction command, and the failures this program throws (`domain/error`). No JDBC, no libraries. |
| `neogrip.gripd.contract` | the records the wire is made of, with their `@JsonName` spellings. Named by the side that produces them and the side that serializes them, which is why they sit beside the rings rather than inside one. |
| `neogrip.gripd.adapter.jdbc` | everything that speaks to a driver: the session, the execution lane, the connection scope, the statement and cursor units, the idle watchdog, and `catalog/` (the DatabaseMetaData units). |
| `neogrip.gripd.adapter.export` | a result streamed to a file through the format library (ADR-0010). |
| `neogrip.gripd.adapter.rpc` | the wire edge: `Protocol`, `ErrorCodes`, `SqlErrors`, the status notifier, and `handler/` - the annotated functions themselves. |

A Java language server reads `.project` and `.classpath` at the repository root to find these two
source roots. They are editor configuration and nothing else - javac is still the only thing that
compiles this (ADR-0004) - and they exist because a server with no build file to read guesses the roots
by scanning for directories full of `.java` files, which picks the deepest package directory and leaves
every cross-root import unresolvable.

## The programming model

An RPC method is a plain annotated function; the Java method's own name is the wire name, prefixed by a
class-level `@RpcNamespace`. Parameters bind by name from the request's `params`; results are returned —
typed records serialized by `JsonMapper` (components in declaration order, nulls omitted, and
`@JsonName("is_pk")` for wire spellings that are not Java ones), or `RpcResult<T>` where the answer is
polymorphic or empty.
Errors are exceptions and no handler declares one: the JDBC exception is translated where the
connection is used, and `Daemon` maps each failure to its code in one place.

```java
@RpcNamespace("catalog")
public final class CatalogHandlers {
    private final Database db;
    public CatalogHandlers(Database db) { this.db = db; }  // constructor-injected by the builder

    @RpcMethod
    Rows<TableRow> tables(String catalog, String schema, String pattern) {
        return db.tables(catalog, schema, pattern);
    }

    @RpcMethod
    IntrospectSummary introspect(String catalog, String path, int parallelism, long budgetMs,
            boolean details) {
        return db.introspect(catalog, path, parallelism, budgetMs, details);
    }
}
```

Handlers declare nothing about threading - there is nothing to declare.

`Daemon.main` is pure configuration: classes go into the builder, which instantiates them, resolving each
constructor parameter by type from the other components and the library's injectables (`Notifier`).
Components may implement `RpcLifecycle` for per-request and shutdown hooks; shutdown hooks run in reverse
registration order. Everything that can be wrong — a duplicate wire name, an unsupported signature, a
missing dependency, a build without `-parameters` — fails at `build()` with a message naming the
offender.

Adding a method is: declare a record in `gripd/contract/`, write an annotated function, done — the
dispatch, threading, binding and serialization are the library's.

## Threading

Every request runs on its own virtual thread (ADR-0028): the read loop never blocks, so ping and cancel
are always answerable mid-query. The one thing serialized is the shared session connection — a fair lock
inside `Database`, which `cancel` never takes (`Statement.cancel` is the one JDBC call defined as safe
from another thread) and the introspect sweep bypasses by running on sibling connections, one sweep at a
time. EOF drains the in-flight requests (bounded), then the shutdown hooks run: `Database` rolls back an
open transaction — never commits — before `Session` closes the connection.
