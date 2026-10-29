-- The options table: defaults merged once under whatever setup(opts) brought.
-- Callers do config.get() at the point of use and never cache the result, so
-- a reload is visible everywhere immediately.
local M = {}

M.defaults = {
	-- Rows per result page. Large enough that most answers fit on one page,
	-- small enough that a page renders instantly; paging fetches the rest on
	-- demand (ADR-0014). The exact value is an open tuning point.
	limit = 200,

	-- Server-side statement timeout. The sidecar enforces it on the Statement;
	-- a client-side watchdog only catches a process that stopped answering.
	timeout_ms = 30000,
}

local stored = {}
local resolved = nil

function M.setup(opts)
	stored = opts or {}
	resolved = nil
end

function M.get()
	if not resolved then
		resolved = vim.tbl_deep_extend("force", vim.deepcopy(M.defaults), stored)
	end
	return resolved
end

function M.reload()
	resolved = nil
end

return M
