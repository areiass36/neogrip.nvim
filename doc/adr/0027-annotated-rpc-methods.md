# 0027. Sidecar methods are annotated functions returning typed records

- Date: 2026-10-29T15:38:48Z
- Status: Accepted

## Context

The sidecar grew phase by phase into a god class: `Main.java` held the stdio framing, a dispatch switch,
the handshake, the threading lanes, connect, session state, the transaction watchdog and the parameter
helpers, so adding one method meant editing a method set, a read-loop switch and a worker switch.
`Queries.java` and `Catalog.java` hand-wrote JSON-RPC envelopes at every result site, with the matching
brace counted by eye. Alternatives considered: registering methods through an interface implemented once
per method (rejected as too verbose — a class per method), and handlers that receive a reply/output object
(rejected — an output parameter is not how a function answers).

## Decision

An internal RPC library, `neogrip.rpc`, with the idioms of a modern Java web framework and zero imports
from the application:

- A method is a plain Java function annotated `@RpcMethod`; the Java method name is the wire name, a
  class-level `@RpcNamespace("catalog")` prefixes it, and `lane` picks the thread ("read", "worker", or a
  named exclusive lane such as "introspect").
- Request parameters are bound by name into the function's typed signature, which requires compiling with
  `javac -parameters`.
- Handlers return typed domain records (or `Map`/`List`/scalars), with a generic `RpcResult<T>` for the
  polymorphic cases; one `JsonCodec` serializes them reflectively — record components in declaration
  order, nulls omitted, a `@Json("is_pk")` component annotation for wire names that are not Java
  spellings. All JSON is written through one structured writer, `JsonStream`, buffer-backed for in-band
  results (bounded pages by ADR-0014) and file-backed for exports and sweeps (ADR-0010).
- `RpcServer.builder()` receives handler and component CLASSES and instantiates them itself, resolving
  constructor parameters by type (micro-injection, not a framework); components may implement
  `RpcLifecycle` for per-request and shutdown hooks; errors are exceptions, mapped by registered
  exception mappers.
- `App` owns the lifecycle and is pure configuration; `Session` is connection control and metadata only;
  `Database` is an injected component owning the lifecycle of everything executed, transactions included.
  `Queries` and `Catalog` dissolve into `neogrip.db` units along their natural seams.

## Consequences

- The wire contract does not move: protocolVersion stays 1, and the live test suite is the compatibility
  harness for the typed-records switch.
- Adding a method becomes: declare a record, write an annotated function.
- Registration, binding and injection are checked at startup, not compile time: a typo'd signature, a
  duplicate name or a missing dependency fails `build()` with a message naming the offender.
- The build gains a required flag (`-parameters`); a build without it is detected and refused.
- File count grows (~10 → ~40) and blame breaks across the moves.
- In-band results materialize as records before serialization — bounded by the page caps that already
  exist; unbounded data stays file-side.
