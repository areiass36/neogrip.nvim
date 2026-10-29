# 0022. Language services are an in-process Lua LSP fed by the swept catalog

- Date: 2026-10-29T13:39:55Z
- Status: Proposed

## Context

The author wants completion, hover and navigation for all targeted engines. A Java LSP server in the
sidecar would need a second channel and a parser per dialect. Neovim 0.12's `vim.lsp.start` accepts a
function as `cmd`, allowing a language server implemented in Lua inside the editor process — which the MVP
already built and ran: definition, hover, references and symbols answered from the introspected catalog
cache, with completion served separately.

This remains the proposal's one decision explicitly left to confirm, so it is recorded as Proposed and the
port of the MVP's `lsp.lua` proceeds under it.

## Decision

Language services run as an in-process LSP server in Lua, one client per connection, fed by catalog
metadata obtained asynchronously from the sidecar and cached. Completion and hover come first; semantic
diagnostics and dialect formatting are out of scope without a real parser.

## Consequences

- Standard LSP means it works with blink.cmp, nvim-cmp and the native completion without adapters.
- Metadata cache invalidation is owned by the schema layer, not the LSP.
- MongoDB's schema-less metadata flows from sampled documents, with weaker answers by nature.
