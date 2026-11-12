-- The cell the cursor is in, and the batch the cursor's position asks for (ADR-0040).
local registry = require("neogrip.grid.registry")

local M = {}

-- Its own namespace so moving the cursor does not repaint the table's highlights.
local CELL_NAMESPACE = vim.api.nvim_create_namespace("neogrip_grid_cell")
local CELL_PRIORITY = 150

--- Underline the cell the cursor is in.
function M.highlight_cell(bufnr)
	local state = registry.states[bufnr]
	if not state then
		return
	end
	vim.api.nvim_buf_clear_namespace(bufnr, CELL_NAMESPACE, 0, -1)
	local line = state.row + 2
	local span = state.spans[line] and state.spans[line][state.column]
	if not span then
		return
	end
	pcall(vim.api.nvim_buf_set_extmark, bufnr, CELL_NAMESPACE, line - 1, span[1], {
		end_col = span[2],
		hl_group = "NGripGridCell",
		priority = CELL_PRIORITY,
	})
end

--- Move the cursor to the current cell.
function M.focus_cell(bufnr, winid)
	local state = registry.states[bufnr]
	if not state then
		return
	end
	local line = state.row + 2
	local span = state.spans[line] and state.spans[line][state.column]
	if span and vim.api.nvim_win_is_valid(winid or 0) then
		pcall(vim.api.nvim_win_set_cursor, winid or 0, { line, span[1] })
	end
	M.highlight_cell(bufnr)
end

--- Put the cursor back on its cell after a redraw, when the window is showing the tab.
function M.refocus(bufnr)
	local winid = registry.find_window(bufnr)
	if winid then
		M.focus_cell(bufnr, winid)
	else
		M.highlight_cell(bufnr)
	end
end

--- Work out which cell the cursor is sitting in after a plain motion.
function M.sync_from_cursor(bufnr, winid)
	local state = registry.states[bufnr]
	if not state then
		return
	end
	local cursor = vim.api.nvim_win_get_cursor(winid or 0)
	local line, column_byte = cursor[1], cursor[2]
	if line <= 2 or line > #state.rows + 2 then
		return
	end
	state.row = line - 2
	local line_spans = state.spans[line] or {}
	for index, span in ipairs(line_spans) do
		if column_byte < span[2] then
			state.column = index
			break
		end
		state.column = index
	end
	M.highlight_cell(bufnr)
end

--- @return any the stored value, not the rendered one
function M.cell_value(bufnr)
	local state = registry.states[bufnr]
	if not state then
		return nil
	end
	local row = state.rows[state.row]
	return row and row[state.column]
end

-- Holding `j` asks once, not per line; see doc/internals.md#grid.
local DEBOUNCE_MS = 120
local pending = {}

--- Ask the result's source for the next batch once the cursor has stopped moving.
--- Without the debounce the batch lands where the cursor was, not where it came to rest.
local function schedule_load(bufnr)
	local state = registry.states[bufnr]
	if not state then
		return
	end
	if pending[bufnr] then
		pending[bufnr]:stop()
	end
	-- A grid can be closed, re-run or sorted inside the debounce, and a stale
	-- batch must not be appended to the result that replaced it.
	local hash = state.result.hash
	pending[bufnr] = vim.defer_fn(function()
		pending[bufnr] = nil
		local current = registry.states[bufnr]
		if not vim.api.nvim_buf_is_valid(bufnr) or not current then
			return
		end
		if current.result.hash ~= hash then
			return
		end
		local source = current.source
		if source and source.load_more then
			source.load_more(current, { quiet = true })
		end
	end, DEBOUNCE_MS)
end

--- Drop a scheduled load: the tab it would have filled is going away.
function M.cancel_load(bufnr)
	if pending[bufnr] then
		pending[bufnr]:stop()
		pending[bufnr] = nil
	end
end

--- Load the next batch when the cursor is within `auto_load_rows` of the last
--- row loaded (ADR-0040). Takes the line so it can be driven without a window (ADR-0023).
--- @param line integer|nil the cursor's buffer line; the window's when absent
--- @return boolean armed whether a load was scheduled
function M.maybe_load_more(bufnr, line)
	local state = registry.states[bufnr]
	if not state then
		return false
	end
	local settings = require("neogrip.config").get()
	local threshold = settings.auto_load_rows or 0
	if threshold <= 0 then
		return false
	end
	local result = state.result
	local auto = state.auto or {}
	-- `limit = 0` means everything in one answer and no cursor kept.
	if auto.loading or auto.exhausted or result.done ~= false or not result.hash then
		return false
	end
	local cap = settings.auto_load_max_rows
	if cap and cap > 0 and #state.rows >= cap then
		return false
	end
	local batch = result.limit or settings.limit or 200
	threshold = math.min(threshold, math.max(1, batch - 1))

	if line == nil then
		local winid = registry.find_window(bufnr)
		if not winid then
			return false
		end
		line = vim.api.nvim_win_get_cursor(winid)[1]
	end
	-- Resting on the blank line or the footer counts as "at the bottom".
	local row = math.min(math.max(line - 2, 1), math.max(#state.rows, 1))
	if #state.rows - row > threshold then
		return false
	end
	schedule_load(bufnr)
	return true
end

--- The ordinal shown in the left gutter for a given buffer line.
--- @return string right-aligned ordinal, or "" for a non-data line
function M.row_number_for(bufnr, lnum)
	local state = registry.states[bufnr]
	if not state then
		return ""
	end
	local row = lnum - 2
	if row < 1 or row > #state.rows then
		return ""
	end
	-- A width floor stops re-widthing mid-scroll (ADR-0040); see doc/internals.md#grid.
	local width = math.max(4, #tostring(#state.rows))
	return ("%" .. width .. "d "):format(row)
end

return M
