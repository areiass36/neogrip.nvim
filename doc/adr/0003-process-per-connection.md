# 0003. One sidecar process per connection, started lazily, ended by stdin EOF

- Date: 2026-10-29T13:39:55Z
- Status: Accepted

## Context

The architectural proposal called for one JVM per Neovim instance with a heartbeat to detect editor death.
The MVP shipped one JVM per configured connection instead, and that choice carries a hard technical reason:
each driver jar goes alone onto its process's classpath, because at least one driver (the MongoDB wrapper,
which bundles GraalVM) cannot share a classpath with the others. A heartbeat also adds a timer on both
sides and can false-positive when the machine suspends.

EOF on stdin detects every way the editor can die — including a hard kill — the moment the pipe closes, and
costs nothing.

## Decision

One sidecar process per configured connection, spawned lazily on first use and replaced when the
connection is re-pointed at a different URL. Shutdown is a `shutdown` notification followed by closing the
sidecar's stdin; EOF makes the sidecar drain in-flight work (bounded), close the JDBC connection and exit.
The Lua side keeps a SIGTERM after 500 ms as a backstop. There is no heartbeat.

## Consequences

- Classpath isolation per driver comes for free; so does per-connection crash isolation.
- Memory cost is one JVM per active connection. The flags chosen for startup over throughput
  (`-XX:TieredStopAtLevel=1 -XX:+UseSerialGC`) keep each one small.
- The first statement on each connection pays the JVM startup; the UI must show a connecting state.
- Windows has no reliable SIGTERM; EOF is the dependable signal there, which is exactly why it is the
  primary mechanism.
