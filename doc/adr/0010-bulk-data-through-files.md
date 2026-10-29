# 0010. Bulk data moves through files with temp-plus-atomic-rename, never through the protocol

- Date: 2026-10-29T13:39:55Z
- Status: Accepted

## Context

A catalog snapshot of a large database or a full result export can be tens of megabytes. Pushing that
through the line protocol means encoding, splitting, reassembling and holding it all in the editor's
memory. The MVP proved the alternative: the Lua side names a file, the Java side streams into a temp file
beside the target and atomically renames it into place, and the protocol carries only the path and a
summary.

## Decision

Anything bulk — catalog snapshots, CSV/JSON exports — is written by the sidecar directly to a file path
provided in the request, via a temporary file in the same directory followed by an atomic rename (with a
non-atomic fallback where the filesystem refuses). The response carries counts and the path, never the
data. Result pages, by contrast, are small by construction (ADR-0014) and do travel in responses.

## Consequences

- Memory stays flat on both sides regardless of result size; a crashed write never leaves a half file at
  the target path.
- The reader of a snapshot must tolerate the file not existing yet (the write is asynchronous by nature).
- Paths cross the protocol, so they are always absolute and built by the Lua side.
