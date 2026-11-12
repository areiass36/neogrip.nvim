-- What the result window holds: one entry per tab, and where each tab is on screen.
-- Every other module in grid/ reads its state from here and nothing here draws.
local M = {}

M.states = {}
-- Tabs whose query has not answered yet: deliberately no entry in `states`,
-- so nothing renders "no rows" for a result that has not arrived (ADR-0044).
M.waiting = {}
-- When the statement in a tab began executing, by the server's word (ADR-0042);
-- nil when nothing is executing in it.
M.clocks = {}
-- One window holds every tab; switching is setting its buffer (ADR-0044).
M.tabs = {}

local active = 0
-- Never reused: a hidden tab still holds its buffer name and a duplicate name is an error.
local minted = 0

--- @class neogrip.GridState
--- @field result table
--- @field columns string[]
--- @field rows any[][] every row loaded, in order (ADR-0040)
--- @field batches { first: integer, last: integer }[] where each batch landed
--- @field auto table { loading, exhausted } - the fetch guards for this result
--- @field expired boolean|nil the server no longer has this result open
--- @field spans table
--- @field kinds table what each cell holds, keyed the same way as spans
--- @field layout neogrip.Layout
--- @field row integer current data row, 1-based
--- @field column integer current column, 1-based
--- @field origin_buf integer the query buffer this came from
--- @field source neogrip.grid.Source what fills the tab with more rows

function M.state(bufnr)
	return M.states[bufnr or vim.api.nvim_get_current_buf()]
end

--- How long the statement in a tab has been executing, in ms; nil when nothing is.
--- Measured from gripd saying it had begun (ADR-0042), so queue and connect time are not in it.
function M.elapsed_of(bufnr)
	local started = M.clocks[bufnr]
	if not started then
		return nil
	end
	return math.floor((vim.uv.hrtime() - started) / 1e6)
end

function M.find_window(bufnr)
	for _, winid in ipairs(vim.api.nvim_list_wins()) do
		if vim.api.nvim_win_get_buf(winid) == bufnr then
			return winid
		end
	end
	return nil
end

--- The tab the window is showing, or nil when there is none.
function M.current_buf()
	local bufnr = M.tabs[active]
	if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
		return bufnr
	end
	return nil
end

--- The window the tabs live in, whichever one of them it is showing.
function M.window()
	local current = M.current_buf()
	if current then
		local winid = M.find_window(current)
		if winid then
			return winid
		end
	end
	for _, bufnr in ipairs(M.tabs) do
		local winid = M.find_window(bufnr)
		if winid then
			return winid
		end
	end
	return nil
end

--- Which tab is showing, 1-based, or 0 when there is none.
function M.active_index()
	return active
end

function M.set_active(index)
	active = index
end

--- Put a tab in the list if it is new, and make it the one the window shows.
function M.activate(bufnr)
	for index, tab in ipairs(M.tabs) do
		if tab == bufnr then
			active = index
			return
		end
	end
	M.tabs[#M.tabs + 1] = bufnr
	active = #M.tabs
end

--- Drop a tab from the list, keeping the active index pointing at a tab that exists.
function M.remove(bufnr)
	for index, tab in ipairs(M.tabs) do
		if tab == bufnr then
			table.remove(M.tabs, index)
			if active > index then
				active = active - 1
			elseif active == index then
				active = math.min(index, #M.tabs)
			end
			break
		end
	end
	if #M.tabs == 0 then
		active = 0
	end
end

--- The next number for a tab's buffer name.
function M.mint()
	minted = minted + 1
	return minted
end

-- Enough of the statement to tell two queries apart in `:ls`.
local LABEL_WIDTH = 32

--- The statement, compressed into a label; '/' and '\' are replaced or the
--- buffer name's tail would be cut at the first one inside the SQL.
function M.label_of(text, width)
	width = width or LABEL_WIDTH
	local label = tostring(text or ""):gsub("[/\\]", " "):gsub("%s+", " ")
	label = vim.trim(label)
	if label == "" then
		return "result"
	end
	if vim.fn.strchars(label) > width then
		label = vim.fn.strcharpart(label, 0, width) .. "…"
	end
	return label
end

--- Hand back the cursor of the result a tab is about to stop holding - one of
--- the reclamation paths ADR-0041 requires.
function M.release_replaced(state, result)
	local stale = state and state.result and state.result.hash
	if stale and stale ~= result.hash and state.result.connection then
		require("neogrip.gripd.runner").release(state.result.connection, stale)
	end
end

return M
