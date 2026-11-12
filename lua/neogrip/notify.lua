local M = {}

--- Scheduled because most callers run inside a vim.system callback, where vim.notify cannot.
--- @param message string
--- @param level integer|nil a vim.log.levels value; INFO when absent
function M.send(message, level)
	vim.schedule(function()
		vim.notify("[neogrip] " .. message, level or vim.log.levels.INFO)
	end)
end

return M
