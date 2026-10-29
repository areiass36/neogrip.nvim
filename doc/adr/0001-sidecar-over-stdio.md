# 0001. The database work runs in a Java sidecar spoken to over stdio

- Date: 2026-10-29T13:39:55Z
- Status: Accepted

## Context

Neovim does not embed a JVM, and JDBC is the one driver interface that covers every targeted engine with a
single API. Loading a JVM into the editor process via FFI/JNI was rejected: a JVM crash would take the
editor with it, and signal and thread ownership between LuaJIT and the JVM is undefined territory. A shared
daemon across Neovim instances was rejected for lifecycle complexity (ADR-0003 covers the per-instance
model).

The predecessor of this plugin — the `lua/db` module in the author's Neovim configuration — shipped this
exact architecture and proved it: a child Java process per connection, the editor talking to it over the
process's own stdin/stdout.

## Decision

All JDBC work happens in a child Java process (the sidecar). The sidecar's stdout is reserved exclusively
for protocol frames; logs, driver banners and diagnostics go to stderr or to files. The channel is
bidirectional: the sidecar can send notifications and requests to the editor (authentication status, input
requests).

## Consequences

- A JVM crash never takes Neovim down; the Lua side fails the pending requests and reports.
- Message framing must be defined precisely (ADR-0002) and drivers that write to stdout must be tolerated
  by the reader.
- Every feature pays one process round trip; bulk data must bypass the pipe (ADR-0010).
- The Lua side must handle sidecar-initiated messages asynchronously.
