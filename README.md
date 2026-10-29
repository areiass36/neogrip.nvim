# neogrip.nvim

Turn Neovim into a SQL and data-manipulation client: pick which database a file runs against, run the
statement under the cursor, read the result in a grid, and query that result again with SQL — on macOS,
Windows and Linux, with no Java to install.

> **Status: under construction.** The architecture is decided and recorded in [doc/adr/](doc/adr/README.md);
> the implementation is landing in phases. Nothing below is usable yet unless the feature's tests exist.

## How it works

A Lua plugin in the editor talks JSON-RPC over stdio to a small Java sidecar, which speaks JDBC to the
databases. The plugin downloads its own pinned, checksum-verified JDK and driver jars on first use and
compiles the sidecar from the sources in this repository — nothing to install, nothing on your PATH.

Planned engines: PostgreSQL, MySQL, SQL Server, Azure SQL, Trino, MongoDB and DuckDB — DuckDB doubling as
the engine that lets you re-query any result (or any CSV) with SQL.

## Requirements

- Neovim 0.12 or newer.
- [kvstore.nvim](https://github.com/areiass36/kvstore.nvim) — every secret (passwords, tokens) is read
  from it and from nowhere else. Register a secret with `:KVStore <key>` before connecting.

## Install

With lazy.nvim:

```lua
{
  "areiass36/neogrip.nvim",
  dependencies = { "areiass36/kvstore.nvim" },
  opts = {},
}
```

`require("neogrip").setup(opts)` is the single entry point; the plugin does nothing before it is called.

## Keymaps

The plugin defines **no keymaps** — not even behind an option. Every action is a `:NGrip*` command or a
documented Lua function, and this section will carry a complete copy-paste recipe reproducing a sensible
layout once the grid API lands.

## What this is not

- It does not confirm dangerous statements. A connection marked `readonly: true` refuses writes in layers,
  and `production: true` is a visible signal — nothing more. The strongest protection is a database user
  with read-only permissions.
- It does not store secrets. kvstore.nvim does, and the connection file holds only key names.

## Development

```bash
stylua --check .
luacheck lua tests
nvim --headless -u tests/minimal.lua -l tests/run.lua unit
```

Architecture decisions live in [doc/adr/](doc/adr/README.md). Contributors using an AI assistant should
create their own pointer file containing the single line `@.ai/INSTRUCTIONS.md` (for example `CLAUDE.md`,
which is gitignored).

## License

[MIT](LICENSE)
