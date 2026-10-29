# 0008. Connections live in .nvim/database.json, schema version 2

- Date: 2026-10-29T13:39:55Z
- Status: Accepted

## Context

The MVP's project file (`.nvim/databases.json`) grew organically: flat fields, a `password_source` union,
no room for authentication modes beyond a password, and Trino's catalog/schema distinction squeezed into
`database`. The proposal defined a v2 schema with structured fields.

## Decision

Connections are described in `.nvim/database.json` (project scope) and in a global file under the plugin's
state directory, with the project file winning on id collision. Schema version 2:

```json
{
  "version": 2,
  "default": "replica",
  "connections": [
    {
      "id": "replica",
      "name": "Transactional (replica)",
      "driver": "postgres",
      "host": "db.example.com",
      "port": 5432,
      "database": "app",
      "catalog": null,
      "schema": null,
      "readonly": true,
      "production": true,
      "ssl": { "mode": "require" },
      "options": { "connectTimeout": "10" },
      "auth": {
        "type": "password",
        "user": "fulano",
        "password": { "kvstore": "replica-password" }
      }
    }
  ]
}
```

`auth.type` is one of `password`, `entra_interactive`, `service_principal`, `managed_identity`, `token`
(ADR-0011). Every secret-bearing field must be a `{ "kvstore": "<key>" }` reference (ADR-0007). `options`
passes driver properties through verbatim. Decoded JSON is whitelisted field by field into a fresh table,
never passed through raw. The plugin warns when the project file is not gitignored and refuses to create
one until it is, because hosts and user names are themselves sensitive.

## Consequences

- Trino's catalog/schema and every planned auth mode have a first-class place from day one.
- The MVP's file name (`databases.json`) is read with a deprecation warning for one migration window.
- Schema changes from here on require a version bump and a migration note.
