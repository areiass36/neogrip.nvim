# 0024. User commands are prefixed NGrip

- Date: 2026-10-29T13:39:55Z
- Status: Accepted

## Context

The MVP used `:Db*`, too generic for a public plugin sharing a namespace with other database tooling.
`:Neogrip*` matches the plugin name but is long to type; the author chose the contraction.

## Decision

Every user command is PascalCase and prefixed `NGrip`: `:NGripRun`, `:NGripUse`, `:NGripExplore`,
`:NGripDoctor` and so on. Every command carries a `desc` written as a sentence, and completion functions
where a vocabulary exists.

## Consequences

- `:NGr<Tab>` reaches the whole command set with no collision risk.
- Renaming commands later is a breaking change requiring a superseding ADR and a deprecation window.
