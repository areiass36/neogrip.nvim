-- Nothing is installed anywhere: the user calls component() from their own statusline.
local resolve = require("neogrip.connections.resolve")

local M = {}

--- @return boolean this buffer's connection is marked production
function M.is_production(bufnr)
	local connection = resolve.for_buf(bufnr or vim.api.nvim_get_current_buf())
	return connection ~= nil and connection.production == true
end

--- @return table|nil { name, driver, readonly, production, running } or nil
--- when the buffer has no connection
function M.status(bufnr)
	bufnr = bufnr or vim.api.nvim_get_current_buf()
	local connection = resolve.for_buf(bufnr)
	if not connection then
		return nil
	end
	local runner = require("neogrip.gripd.runner")
	return {
		name = connection.name,
		driver = connection.driver,
		readonly = connection.readonly == true,
		production = connection.production == true,
		running = #runner.active() > 0,
		transaction = runner.in_transaction(connection.id),
	}
end

--- A ready-made string (`replica [RO][PROD] …`), empty outside query and grid buffers.
function M.component()
	local bufnr = vim.api.nvim_get_current_buf()
	local filetype = vim.bo[bufnr].filetype
	if filetype ~= "sql" and filetype ~= "mysql" and filetype ~= "mongodb" and filetype ~= "neogrip-grid" then
		return ""
	end
	local status = M.status(bufnr)
	if not status then
		return "neogrip: no connection"
	end
	local flags = (status.readonly and "[RO]" or "")
		.. (status.production and "[PROD]" or "")
		.. (status.transaction and "[TX]" or "")
	return status.name .. (flags ~= "" and " " .. flags or "") .. (status.running and " …" or "")
end

return M
