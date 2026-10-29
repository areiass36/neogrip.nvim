# 0016. No confirmations for dangerous statements; readonly is layered and production is visible

- Date: 2026-10-29T13:39:55Z
- Status: Accepted

## Context

The MVP guarded dangerous statements interactively: an `UPDATE` or `DELETE` without `WHERE` demanded typing
the connection name, and a `production` connection asked for confirmation. The architectural proposal
decided against confirmations, and the author confirmed that decision for this plugin: confirmations train
the hand to confirm, and the strongest protection was never the dialog.

## Decision

The plugin asks no confirmation for any statement. Protection is layered where it is mechanical, not
interactive: a connection marked `readonly: true` refuses write statements in the Lua classifier outright,
and the sidecar additionally calls `setReadOnly(true)` and refuses writes server-side, because the JDBC
flag alone is only a hint in some drivers. A connection marked `production: true` gets a visible signal —
the statusline component renders it distinctly — and nothing else. The strongest protection remains a
database user with read-only permissions, and the README says so.

## Consequences

- `production: true` has exactly one effect: visibility. Users who want hard protection use `readonly` or
  database-level permissions.
- A mistyped `DELETE` on a writable production connection executes. That is the accepted trade, recorded
  here so nobody rediscovers it as a bug.
- Adding confirmations later is simple if the decision changes; removing them later would not have been.
