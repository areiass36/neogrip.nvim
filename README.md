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

## Commands

| Command | What it does |
| --- | --- |
| `:NGripRun [sql]` | Run a statement, or the one under the cursor |
| `:NGripCancel` | Cancel the running query — a real server-side cancel |
| `:NGripValidate` | Check the statement on the server without running it |
| `:NGripUse <id>` / `:NGripWhich` | Pick the buffer's connection / explain which one applies |
| `:NGripConnections` / `:NGripReload` | List / re-read the connection files |
| `:NGripResults` | Query the current result with SQL (DuckDB views `r1`, `r2`, …, alias `last`) |
| `:NGripCsv <file>` | Query any CSV file with SQL |
| `:NGripExport` / `:NGripKeep [file]` | Export the result (CSV/JSON, page or everything) / keep the page as CSV |
| `:NGripNewQuery` / `:NGripDisconnect[!]` | Open a query buffer / stop the sidecar(s) |
| `:NGripInit` / `:NGripDoctor` | Write a starter project file / check the whole path |

## Keymaps

The plugin defines **no keymaps** — not even behind an option. Every action is a `:NGrip*` command or a
documented Lua function. A complete starting layout, to paste into your config and reshape:

```lua
-- Global, for SQL buffers.
vim.keymap.set("n", "<leader>qq", "<cmd>NGripRun<cr>", { desc = "Run the statement under the cursor" })
vim.keymap.set("n", "<leader>qx", "<cmd>NGripCancel<cr>", { desc = "Cancel the running query" })
vim.keymap.set("n", "<leader>qc", "<cmd>NGripUse<cr>", { desc = "Pick a connection" })
vim.keymap.set("n", "<leader>qr", "<cmd>NGripResults<cr>", { desc = "Query the result with SQL" })

-- Buffer-local, inside the result grid.
vim.api.nvim_create_autocmd("FileType", {
	pattern = "neogrip-grid",
	callback = function(event)
		local actions = require("neogrip.grid.actions")
		local function map(lhs, rhs, desc)
			vim.keymap.set("n", lhs, rhs, { buffer = event.buf, nowait = true, desc = desc })
		end
		map("<Tab>", actions.next_column, "Next column")
		map("<S-Tab>", actions.prev_column, "Previous column")
		map("h", actions.prev_column, "Previous column")
		map("l", actions.next_column, "Next column")
		map("j", actions.down, "Next row")
		map("k", actions.up, "Previous row")
		map("0", actions.first_column, "First column")
		map("$", actions.last_column, "Last column")
		map("gg", actions.first_row, "First row")
		map("G", actions.last_row, "Last row")
		map("y", actions.yank_cell, "Yank cell")
		map("Y", actions.yank_row, "Yank row as CSV")
		map("s", actions.sort_asc, "Sort by this column")
		map("S", actions.sort_desc, "Sort descending")
		map("]p", actions.page_next, "Next page")
		map("[p", actions.page_prev, "Previous page")
		map("gf", actions.follow_fk, "Follow this foreign key")
		map("<CR>", actions.show_document, "Show the whole document (Mongo)")
		map("e", actions.export, "Export")
		map("d", actions.materialise, "Query this result with SQL")
		map("q", actions.close, "Close the grid")
	end,
})
```

A statusline component is available too: `require("neogrip.statusline").component()` renders
`replica [RO][PROD]` for the current buffer — `[PROD]` being the one effect `production: true` has.

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
