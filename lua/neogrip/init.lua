local M = {}

M.state_dir = vim.fn.stdpath("state") .. "/neogrip"

-- Artifacts and compiled classes live apart from state, so wiping one never costs the other.
M.data_dir = vim.fn.stdpath("data") .. "/neogrip"

-- SQL NULL as a unique table: nil would leave a hole in a row array and "" is a different value.
M.NULL = setmetatable({}, {
	__tostring = function()
		return "NULL"
	end,
})

--- Notify the user; scheduled because most callers are vim.system callbacks, where vim.notify
--- cannot run directly.
function M.notify(message, level)
	vim.schedule(function()
		vim.notify("[neogrip] " .. message, level or vim.log.levels.INFO)
	end)
end

--- The single entry point; nothing is registered before it runs and downloads stay lazy (ADR-0018).
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
	-- document must register the neogrip:// reader before buffer, whose attach() may open a definition.
	require("neogrip.document").setup()
	require("neogrip.dialect").setup()
	require("neogrip.completion").setup()
	require("neogrip.buffer").setup()
	require("neogrip.grid.highlight").setup()
	require("neogrip.grid.requery").setup()
	require("neogrip.commands").setup()
end

return M
