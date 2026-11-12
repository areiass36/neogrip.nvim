local paths = require("neogrip.paths")

local M = {}

--- The single entry point; nothing is registered before it runs and downloads stay lazy (ADR-0018).
function M.setup(opts)
	if vim.fn.has("nvim-0.12") ~= 1 then
		error("neogrip needs neovim 0.12 or newer", 0)
	end
	if not pcall(require, "kvstore") then
		error("neogrip needs kvstore.nvim (areiass36/kvstore.nvim); every secret is read from it", 0)
	end

	require("neogrip.config").setup(opts)
	vim.fn.mkdir(paths.state_dir, "p")
	require("neogrip.connections").setup()
	require("neogrip.connections.resolve").setup()
	require("neogrip.gripd.runner").setup()
	require("neogrip.diagnostics").setup()
	-- document must register the neogrip:// reader before buffer, whose attach() may open a definition.
	require("neogrip.ui.document").setup()
	require("neogrip.ui.syntax").setup()
	require("neogrip.lsp.completion").setup()
	require("neogrip.ui.buffer").setup()
	require("neogrip.grid.highlight").setup()
	require("neogrip.grid.requery").setup()
	require("neogrip.commands").setup()
end

return M
