local lsp = require("neogrip.lsp")
local resolve = require("neogrip.connections.resolve")
local syntax = require("neogrip.ui.syntax")

local M = {}

local scratch_count = 0

local function attach_services(bufnr, connection)
	syntax.attach(bufnr, connection.driver)
	lsp.start(bufnr)
end

--- A scratch query buffer; acwrite plus BufWriteCmd so :w asks where to save instead of failing.
--- @return integer bufnr
function M.new_query(connection, text)
	scratch_count = scratch_count + 1
	local bufnr = vim.api.nvim_create_buf(true, false)
	vim.api.nvim_buf_set_name(bufnr, ("neogrip://query/%d.sql"):format(scratch_count))
	vim.bo[bufnr].buftype = "acwrite"
	vim.bo[bufnr].filetype = connection.driver == "mongodb" and "mongodb" or "sql"
	vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, vim.split(text or "", "\n"))
	vim.bo[bufnr].modified = false

	vim.api.nvim_create_autocmd("BufWriteCmd", {
		buffer = bufnr,
		callback = function()
			vim.ui.input({ prompt = "Save this query as: ", completion = "file" }, function(path)
				if not path or path == "" then
					return
				end
				vim.cmd(("write %s"):format(vim.fn.fnameescape(vim.fn.expand(path))))
				vim.bo[bufnr].modified = false
			end)
		end,
	})

	vim.cmd("vsplit")
	vim.api.nvim_win_set_buf(vim.api.nvim_get_current_win(), bufnr)
	if connection then
		resolve.bind(bufnr, connection.id)
	end
	M.attach(bufnr)
	return bufnr
end

--- Wire the dialect layer and the language server onto a SQL or Mongo buffer.
function M.attach(bufnr)
	if vim.b[bufnr].neogrip_attached then
		return
	end
	vim.b[bufnr].neogrip_attached = true

	local connection = resolve.for_buf(bufnr)
	if connection then
		attach_services(bufnr, connection)
	end
end

--- The connection of the current buffer, for a statusline component.
function M.status()
	local bufnr = vim.api.nvim_get_current_buf()
	local filetype = vim.bo[bufnr].filetype
	if filetype ~= "sql" and filetype ~= "mongodb" and filetype ~= "neogrip-grid" then
		return ""
	end
	local running = #require("neogrip.gripd.runner").active() > 0
	local connection = resolve.for_buf(bufnr)
	if not connection then
		return running and "neogrip: running" or "neogrip: no connection"
	end
	return ("%s%s"):format(connection.name, running and " (running)" or "")
end

function M.setup()
	-- Neovim has no filetype for a mongosh script.
	vim.filetype.add({ extension = { mongodb = "mongodb" } })

	local group = vim.api.nvim_create_augroup("NeogripBuffers", { clear = true })

	-- A buffer bound to another connection needs that engine's dialect and its own server.
	vim.api.nvim_create_autocmd("User", {
		group = group,
		pattern = "NeogripConnectionBound",
		callback = function(args)
			local data = args.data or {}
			if data.buf and data.connection then
				attach_services(data.buf, data.connection)
			end
		end,
	})

	vim.api.nvim_create_autocmd("FileType", {
		group = group,
		pattern = { "sql", "mysql", "plsql", "mongodb" },
		callback = function(args)
			M.attach(args.buf)
		end,
	})
	-- Buffers already open when the plugin loads.
	for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
		if vim.api.nvim_buf_is_loaded(bufnr) then
			local filetype = vim.bo[bufnr].filetype
			if filetype == "sql" or filetype == "mongodb" then
				M.attach(bufnr)
			end
		end
	end
end

return M
