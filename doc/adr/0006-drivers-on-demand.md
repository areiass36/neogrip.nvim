# 0006. JDBC drivers are downloaded on demand, pinned and checksum-verified

- Date: 2026-10-29T13:39:55Z
- Status: Accepted

## Context

Embedding every driver would bloat the plugin, redistribute third-party binaries with mixed licenses, and
force conflicting dependency trees (Netty, Jackson, BouncyCastle) onto one classpath. The MVP already
downloaded one pinned driver jar per engine from Maven Central (and the MongoDB wrapper from its release
page) and put only that jar on the classpath of that connection's process.

## Decision

Drivers are downloaded on first use of the engine that needs them, from Maven Central (or the wrapper's
official release source), with versions pinned in the source and a SHA-256 per jar verified before the jar
ever reaches a classpath. Because one process serves one connection (ADR-0003), each driver loads alone —
there is no shared DriverManager problem and no need for classloader isolation inside one JVM. The jars are
downloaded to the user's machine and never redistributed by this project.

## Consequences

- Offline behavior is explicit: an already-downloaded driver works; a missing one fails with a message
  naming the artifact it could not fetch.
- Version bumps are deliberate chores updating version and checksum together.
- Driver dependencies that are not bundled into the published jar must be resolved the same pinned way if
  an engine ever requires it; so far every targeted driver ships a self-contained jar.
