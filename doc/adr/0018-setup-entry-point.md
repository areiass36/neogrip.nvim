# 0018. Configuration is setup(opts) and nothing loads or runs before it

- Date: 2026-10-29T13:39:55Z
- Status: Accepted

## Context

The MVP read its options from `vim.g.db_config`, which suits a personal config where load order is owned by
one person. Public Neovim plugins conventionally expose `setup(opts)`; kvstore.nvim, this plugin's hard
dependency, already does. A `plugin/` directory that registers things at startup was also considered and
rejected: it runs before the user's config and makes "nothing happens until asked" impossible to promise.

## Decision

`require("neogrip").setup(opts)` is the single entry point. It validates the Neovim version, confirms
kvstore.nvim is available, merges `opts` over the defaults in `config.lua`, and registers commands,
autocommands and the `neogrip://` reader — in that order, nothing earlier. There is no `plugin/`
directory and no load-time side effect; requiring a submodule without calling `setup()` does nothing to
the editor. Downloads (JDK, drivers) remain lazy on first connect, never at `setup()`.

## Consequences

- Works identically under lazy.nvim (`opts = {}`), packer or plain `:packadd` + one `setup()` call.
- Every default in `config.lua` carries a comment stating its trade-off, because `setup(opts)` is the
  documented public surface.
- Forgetting `setup()` means no commands exist; the README's install section makes that impossible to miss.
