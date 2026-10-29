# 0002. Messages are JSON-RPC 2.0, one object per line

- Date: 2026-10-29T13:39:55Z
- Status: Accepted

## Context

The predecessor MVP used an asymmetric wire format: tab-separated fields with base64-encoded free-form
parts inbound, one JSON object per line outbound. It worked, but it is a private dialect: two parsers to
document, no standard error object, and no natural shape for sidecar-initiated requests.

Two framings were considered for JSON-RPC: LSP-style `Content-Length` headers and newline-delimited JSON
(NDJSON). `Content-Length` is byte-exact but requires an incremental header parser on both sides. NDJSON
needs only a line splitter — which the MVP's consume loop already is — and JSON encoders never emit a raw
newline inside a document, so the framing cannot be broken by content.

## Decision

The protocol is JSON-RPC 2.0 over stdio, one JSON object per line, UTF-8, LF-terminated. Client request ids
are monotonically increasing integers; sidecar-initiated request ids are strings prefixed `sv-` so the two
id spaces cannot collide; notifications carry no id. The first message must be `initialize` carrying the
protocol version; a major-version mismatch is refused with error `-32002`. The reader skips lines that are
not JSON objects, because JDBC drivers occasionally print banners to stdout despite ADR-0001's rule.
`doc/protocol.md` is the versioned source of truth for methods, shapes and error codes.

## Consequences

- Requests are now JSON, so the Java side needs a JSON reader, not just a writer. The no-dependency rule
  (ADR-0004) means a small hand-written parser with its own tests.
- Standard error objects give every failure the same shape; driver-specific fields ride in `error.data`.
- The MVP's base64-avoids-escaping trick is gone; correctness now rests on the JSON parsers being right,
  which the test suite must earn.
- A 30-line mock sidecar can fake the whole contract for unit tests.
