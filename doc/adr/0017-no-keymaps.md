# 0017. The plugin defines no keymaps; every action is a documented Lua function or command

- Date: 2026-10-29T13:39:55Z
- Status: Accepted

## Context

The MVP, living inside a personal configuration, mapped a whole `<leader>q` namespace plus around
twenty-five buffer-local keys in the result grid. A public plugin taking that many keys invites collisions,
and even an opt-in default set imposes one person's layout. The author decided the plugin ships zero
keymaps — not even behind a flag.

## Decision

The plugin defines no keymaps anywhere, global or buffer-local, and has no option to enable any. Every
action the MVP bound to a key is a named public function (`require("neogrip.grid.actions").next_column()`
and the rest) or a `:NGrip*` command. The README ships a complete copy-paste recipe — a `FileType`
autocommand on the grid's filetype plus a handful of global maps — reproducing the MVP's layout for anyone
who wants a starting point.

## Consequences

- Zero collision risk and zero hidden behavior; the user's config is the single source of key bindings.
- First-run friction is real: an unmapped grid responds only to normal-mode Vim. The README recipe and the
  `:help` page exist to pay that cost down.
- Grid actions must be designed as a stable public API with names worth documenting, not internal closures.
