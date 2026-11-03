# 0035. The application ring is collapsed: two rings and a contract

- Date: 2026-11-03T16:37:03Z
- Status: Accepted

## Context

ADR-0032 laid out `neogrip.gripd` in three rings - `domain`, `application` (use cases and ports) and
`adapter` - with the rule that domain and application import neither the libraries nor `java.sql`. The
same record also decided, deliberately, that the records going on the wire are the protocol's DTOs and
that a parallel domain hierarchy with 1:1 mappers was not worth forty types for no behavior.

Implementing it showed the two halves cannot both hold. An application ring may not name `java.sql`, so
every operation would reach it through a port; a port has to return something, and the only shapes this
program has are the wire records. So either the application ring names the DTOs - which ADR-0032 puts in
the adapter, making the arrow point outward - or a second set of types exists for it to name, which is
the duplication ADR-0032 rejected.

Measured, the port layer that would have made the arrows literal is about six interfaces and forty
forwarding methods over a single implementation that can never have a second one: one process holds one
JDBC connection (ADR-0003), and there are no Java-level tests to substitute a double into (ADR-0023). It
would be indirection with no reader and no caller.

## Decision

The program has two rings and a contract beside them:

- `gripd/domain` - what needs nothing open: the read-only policy, which spellings are a transaction
  command, the text handling both of those share, and the failures this program throws. No `java.sql`, no
  library imports, nothing from an outer ring. This part of ADR-0032 stands unchanged.
- `gripd/contract` - the records the wire is made of, with their `@JsonName` spellings. Both the side that
  produces them and the side that serializes them name them, which is why they sit beside the rings
  instead of inside one. ADR-0032 placed them in `adapter/rpc/contract`; moving them out of a ring is
  what makes "nothing points outward" true of the rest.
- `gripd/adapter` - everything that speaks to something: `jdbc` (the session, the execution lane, the
  connection scope, the statement and cursor units, the idle watchdog, the catalog units), `export` (a
  result streamed to a file) and `rpc` (the protocol's version and codes, the error translation and the
  annotated handlers).
- There is no `application` ring and no port package. The one port that survives is `domain.Notifications`,
  which is a pure interface the rpc adapter implements, and it earns its place: without it the code that
  rolls back an idle transaction would spell a protocol frame's parameter map.

Everything else ADR-0032 decided is in force: the `java/lib` and `java/app` source roots, the dependency
direction between the libraries and the program, no `SQLException` across a boundary, and the grep that
checks no file under `java/lib` names the program.

## Consequences

- The dependency rule that is checked is the one that matters and is true: the libraries know nothing of
  the program, the domain knows nothing of JDBC or the wire, and no arrow points outward.
- Orchestration - the lane, the scope, the watchdog, the facade the handlers call - sits in
  `adapter/jdbc` and names concrete classes. A reader looking for a use-case layer will not find one; what
  they find is one class per mechanism, which is what this program actually has.
- Introducing a second data store, or Java-level tests with doubles, would mean adding the ports then.
  The forwarding is a mechanical change when a caller for it exists, and nothing in the current layout
  works against it.
- ADR-0032 keeps its status: it is not superseded, because only its ring clause narrowed. A reader of both
  gets the history, which is the point of the log.
