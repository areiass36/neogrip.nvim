# 0011. Authentication is a structured auth object with five modes

- Date: 2026-10-29T13:39:55Z
- Status: Accepted

## Context

User plus password does not cover the author's real connections: Azure SQL wants Entra ID (interactive with
MFA, service principal, or managed identity), Trino wants a bearer token, and some databases are only
reachable through an SSH tunnel. Each mode needs different fields and a different flow, and guessing
between them from flat fields is how credentials end up in the wrong place.

## Decision

`auth` is an object with a `type` discriminator: `password`, `entra_interactive`, `service_principal`,
`managed_identity`, `token`. SSH tunnelling is an orthogonal `ssh` block implemented inside the sidecar
with a pinned, checksummed SSH library, verifying `known_hosts` by default. The schema (ADR-0008) and the
protocol's `connect` request carry all modes from day one; implementation lands in phases — password first,
Entra interactive and token next, service principal after, managed identity last (it only works inside
Azure). Interactive flows report progress through sidecar `status` notifications; the browser flow is
documented as unavailable in headless or remote sessions, with device code as a possible later addition.

## Consequences

- Adding a mode never changes the schema shape, only the accepted `type` values.
- Token expiry on a live connection needs its own decision when the token mode lands; recorded as open.
- Which Entra modes the SQL Server driver supports natively must be confirmed before that phase starts.
- The sidecar holds tokens and tunnels per configured connection and reuses them for extra connections
  (ADR-0012), so interactive logins do not multiply.
