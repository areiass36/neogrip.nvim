# 0012. Each configured connection has one shared JDBC connection, with extras on demand

- Date: 2026-10-29T13:39:55Z
- Status: Accepted

## Context

A JDBC `Connection` is not safe for concurrent statements, and session state — `USE`, `SET`, temporary
tables, an open transaction — lives in the connection. A pool would discard that session identity; a single
connection would serialise everything behind the user's longest query.

## Decision

The main JDBC connection is the session. When a statement arrives while it is busy, the sidecar opens a
disposable extra connection from the same URL, properties and credentials (reusing token and tunnel,
ADR-0011). Extras do not share session state with the main connection, are capped per configured
connection, and close after an idle timeout — both knobs configurable, with conservative defaults on
`production` connections so the plugin cannot exhaust a server's connection limit.

## Consequences

- A long query never blocks a quick lookup, and catalog introspection runs beside user statements.
- Statements run on extras do not see uncommitted changes from an open transaction on the session
  (ADR-0013 makes that visible).
- The cap and idle-timeout values are configuration with defaults, not hardcoded; their defaults are an
  open tuning point recorded in the backlog.
