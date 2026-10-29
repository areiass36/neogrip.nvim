# 0019. The minimum supported Neovim version is 0.12

- Date: 2026-10-29T13:39:55Z
- Status: Accepted

## Context

kvstore.nvim, the hard dependency that owns every secret (ADR-0007), refuses to run below Neovim 0.12, so
no lower floor is reachable in practice. 0.12 also covers everything the ported code uses without
shimming: `vim.system`, `vim.glob.to_lpeg`, `vim.hl.range`, and `vim.lsp.start` with a function `cmd` for
the planned in-process language server (ADR-0022).

## Decision

The minimum supported Neovim version is 0.12. `setup()` checks it and fails with a clear message. No API
introduced after 0.12 is used, and no API deprecated in 0.12 is used.

## Consequences

- Users on older Neovim cannot use the plugin; given the dependency, that was already true.
- Raising the floor again is an "ask first" change recorded by a superseding ADR.
