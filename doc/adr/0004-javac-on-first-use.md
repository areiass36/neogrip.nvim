# 0004. The sidecar is compiled with javac on first use from sources in the repo

- Date: 2026-10-29T13:39:55Z
- Status: Accepted

## Context

The architectural proposal (its ADR-003 and ADR-015) called for a Gradle build producing a jar and a
jlink-minimised runtime published per platform in releases. That buys small downloads and a reproducible
binary, at the cost of a build system, a release pipeline per OS, and a CI that must produce five runtimes
before the first user can run anything.

The MVP took the other path: plain `.java` sources, compiled with `javac` into a classes directory on first
use, no jar, no build system. The sources are small (around three thousand lines), compile in seconds, and
the plugin already owns a JDK (ADR-0005) so `javac` is guaranteed present.

## Decision

The Java sources ship in the repository under `java/neogrip/` and are compiled by the plugin with `javac`
on first use (and recompiled when sources are newer than the compiled classes, or when the protocol
version stamp changes). There is no Gradle, no jar and no jlink. This supersedes the build and
distribution parts of the original proposal's ADR-003 and ADR-015. The quality bar for Java code is
`javac -Xlint:all -Werror` compiling clean, enforced in CI.

## Consequences

- No release pipeline is needed before the plugin is usable; `git clone` is the distribution.
- The downloaded artifact is a full JDK (~190 MB) instead of a trimmed runtime; ADR-0005 records that
  trade. A jlink-based distribution can supersede this later without touching the protocol.
- There is no dependency resolution on the Java side, so every Java capability must be written against the
  JDK's standard library or an explicitly pinned, checksummed jar (ADR-0006 covers drivers; the same rule
  covers any future library such as an SSH client).
- Users on the same machine pay one compile per plugin update, measured in seconds.
