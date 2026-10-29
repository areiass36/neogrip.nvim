# 0009. Secrets travel to the sidecar inside the connect request, never in argv or env

- Date: 2026-10-29T13:39:55Z
- Status: Accepted

## Context

A secret must cross from Lua to the sidecar somehow. Command-line arguments are visible to every process on
the machine; environment variables are inherited by children and routinely dumped in diagnostics. The MVP
wrote the password base64-encoded as the first line of stdin, before the protocol started — safe, but a
special pre-protocol step that exists outside the contract, and it only carries one secret.

## Decision

Secrets ride inside the `connect` request's parameters on the stdio pipe — the same confidentiality domain
as the MVP's first stdin line, with no pre-protocol special case. The sidecar's argv contains nothing
database-related at all. Discipline around the channel: the Lua client never logs `connect` parameters; the
Java side never echoes request parameters into responses, exceptions or stderr; every driver message shown
to a user passes through redaction first.

## Consequences

- One uniform path for every current and future secret: password, client secret, token, SSH passphrase.
- The mock sidecar and the real one share the same contract, so tests cover the real transport.
- The protocol layer becomes security-sensitive code: a logging statement in the wrong place is a leak, so
  the no-logging rule is written into `.ai/INSTRUCTIONS.md` and checked in review.
- A live test must verify, by PID, that no secret appears in the sidecar's command line.
