# 0005. A private Temurin JDK is downloaded on first use, pinned and checksum-verified

- Date: 2026-10-29T13:39:55Z
- Status: Accepted

## Context

The user must not have to install Java (a core goal of the proposal). The system `java` cannot be trusted
to exist or to be a usable version. The MVP downloaded Temurin through the Adoptium `binary/latest`
redirect, which is convenient but unverifiable: the artifact behind the URL changes over time, so no
checksum can be pinned against it, and the plugin executes what it downloads.

## Decision

The plugin downloads a Temurin JDK (not a JRE — `javac` is required by ADR-0004) into its own data
directory on first use, exclusively for its own use. The download URL points at an exact pinned release per
target platform, and the archive's SHA-256 is pinned in the source and verified before extraction. A
checksum mismatch aborts with a clear error and deletes the download. Nothing from a downloaded artifact is
executed before its checksum passes.

## Consequences

- Supply-chain exposure drops from "whatever the redirect serves" to "the artifact the maintainer pinned".
- Pinning means periodic version-bump chores, each updating URL and checksum together.
- The plugin works on a machine with no Java installed, at the cost of a ~190 MB first-use download; the
  UI must make the wait visible and requests made before the JDK is ready queue up (per the proposal).
- CI never exercises the download path with the real artifact on every run; a unit test covers the
  checksum logic against a local file, and `doc/manual-checks.md` covers the real download per OS.
