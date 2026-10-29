-- A SQL and data-manipulation client in the editor: pick which database a file
-- runs against, run the statement under the cursor, read the result in a grid,
-- and query that result again with SQL.
--
-- The pieces, in the order setup() wires them (growing as phases land):
--
--   config       the defaults and the user's setup(opts) table
--   rpc          the JSON-RPC client the sidecar is spoken through
--   bootstrap    the pinned JDK and driver downloads
--   connections  the two config levels (global, project) and resolution
--   secrets      every secret, from kvstore.nvim at connect time
--   sidecar      one Java process per connection
--   runner       statements queued per connection, cancelled on the server
--   grid         the result buffer; actions are the user's to map
--   commands     the :NGrip* commands
local M = {}

M.state_dir = vim.fn.stdpath("state") .. "/neogrip"

-- Downloaded artifacts (JDK, driver jars) and compiled sidecar classes live
-- here, apart from state, so wiping one never costs the other.
M.data_dir = vim.fn.stdpath("data") .. "/neogrip"

-- SQL NULL. A unique table rather than nil (which would leave a hole in a row
-- array) and rather than "" (which is a different value, and saying otherwise
-- turns a correct "where x is null" into a wrong one).
M.NULL = setmetatable({}, {
	__tostring = function()
		return "NULL"
	end,
})

--- Every message the plugin shows the user. Scheduled because most callers are
--- vim.system callbacks, where vim.notify is not allowed to run directly.
function M.notify(message, level)
	vim.schedule(function()
		vim.notify("[neogrip] " .. message, level or vim.log.levels.INFO)
	end)
end

--- The single entry point. Nothing is registered and nothing runs before this
--- is called (ADR-0018); downloads stay lazy on first connect, never here.
function M.setup(opts)
	if vim.fn.has("nvim-0.12") ~= 1 then
		error("neogrip needs neovim 0.12 or newer", 0)
	end
	if not pcall(require, "kvstore") then
		error("neogrip needs kvstore.nvim (areiass36/kvstore.nvim); every secret is read from it", 0)
	end

	require("neogrip.config").setup(opts)
	vim.fn.mkdir(M.state_dir, "p")
	require("neogrip.connections").setup()
	require("neogrip.resolve").setup()
	require("neogrip.runner").setup()
	require("neogrip.diagnostics").setup()
	-- document registers the neogrip:// reader and must come before buffer:
	-- attach() may open a definition the moment a SQL buffer resolves.
	require("neogrip.document").setup()
	require("neogrip.dialect").setup()
	require("neogrip.completion").setup()
	require("neogrip.buffer").setup()
	require("neogrip.grid.highlight").setup()
	require("neogrip.grid.requery").setup()
	require("neogrip.commands").setup()
end

return M
