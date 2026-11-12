-- What a tab says about itself: the status line of a query still running, the footer under
-- the rows once they are here (ADR-0045), and the one timer that keeps either moving.
local highlight = require("neogrip.grid.highlight")
local registry = require("neogrip.grid.registry")

local M = {}

local NAMESPACE = vim.api.nvim_create_namespace("neogrip_grid")
local SLOW_MS = 1000
local SEPARATOR = "  ·  "

--- Which connection answered, how many rows are here and how long the statement
--- took, shared by the footer and by status_text so the two cannot drift apart.
--- @return table parts list of { text, group }
local function describe(bufnr, state)
	local result = state.result
	local connection = result.connection or {}
	local range = ("%d rows"):format(#state.rows)
	if #state.rows == 0 then
		range = "no rows"
	end
	if #state.columns == 0 and result.update_count then
		local affected = result.update_count
		-- An unknown count is not none; see doc/internals.md#grid.
		if affected < 0 then
			range = "statement ran"
		else
			range = ("%d row%s affected"):format(affected, affected == 1 and "" or "s")
		end
	end
	-- `done` stays false on a result whose cursor the server has dropped, so both are asked.
	local more = result.done == false and not state.expired
	local auto = state.auto or {}
	local cap = require("neogrip.config").get().auto_load_max_rows
	local suffix = ""
	if state.expired then
		suffix = " (expired)"
	elseif more and auto.loading then
		suffix = " (more, loading...)"
	elseif more and cap and cap > 0 and #state.rows >= cap then
		-- Paused, not stopped: page_next still loads past the cap (no key named, ADR-0017).
		suffix = " (more, paused)"
	elseif more then
		suffix = " (more)"
	end
	-- A live refill shows how long it has been going, not the last batch's time (ADR-0042).
	local elapsed = registry.elapsed_of(bufnr) or result.elapsed_ms or 0
	return {
		{
			("%s [%s]"):format(connection.name or "?", connection.driver or "?"),
			connection.production and "NGripGridProduction" or "NGripGridConnection",
		},
		{ range .. suffix, "NGripGridCount" },
		{ ("%d ms"):format(elapsed), elapsed >= SLOW_MS and "NGripGridSlow" or "NGripGridElapsed" },
	}
end

--- What a tab that has not answered yet says about itself.
--- @return table parts list of { text, group }
local function describe_pending(bufnr, entry)
	local connection = entry.connection or {}
	local parts = {
		{
			("%s [%s]"):format(connection.name or "?", connection.driver or "?"),
			connection.production and "NGripGridProduction" or "NGripGridConnection",
		},
	}
	if entry.failed then
		parts[#parts + 1] = { entry.failed, "NGripGridSlow" }
		return parts
	end
	local elapsed = registry.elapsed_of(bufnr)
	if not elapsed then
		-- A word, never a number, until the server says it has begun (ADR-0042).
		parts[#parts + 1] = { entry.phase or "sent", "NGripGridElapsed" }
		return parts
	end
	parts[#parts + 1] = { "running", "NGripGridCount" }
	parts[#parts + 1] = {
		("%d ms"):format(elapsed),
		elapsed >= SLOW_MS and "NGripGridSlow" or "NGripGridElapsed",
	}
	return parts
end

--- Join parts into one line, with the byte span of each part so it can be painted.
--- @return string text
--- @return table segments list of { start_byte, end_byte, group }
local function compose(parts)
	local texts, segments, cursor = {}, {}, 0
	for index, part in ipairs(parts) do
		if index > 1 then
			cursor = cursor + #SEPARATOR
		end
		segments[#segments + 1] = { cursor, cursor + #part[1], part[2] }
		cursor = cursor + #part[1]
		texts[#texts + 1] = part[1]
	end
	return table.concat(texts, SEPARATOR), segments
end

--- The footer line and its segments.
--- @return string text
--- @return table segments
function M.footer(bufnr, state)
	local parts = describe(bufnr, state)
	if state.has_binary then
		parts[#parts + 1] = { "binary column: select encode(col,'hex') to read it", "NGripGridBinary" }
	end
	return compose(parts)
end

--- What a tab says about itself right now: the pending status line while the
--- query runs, the footer once rows are here (ADR-0045).
--- @return string
function M.status_text(bufnr)
	if registry.waiting[bufnr] then
		return (compose(describe_pending(bufnr, registry.waiting[bufnr])))
	end
	if registry.states[bufnr] then
		return (M.footer(bufnr, registry.states[bufnr]))
	end
	return ""
end

--- Write the status line into a pending tab's body (ADR-0045), skipping a
--- failed tab and a reused one whose rows are still on screen.
function M.paint_pending(bufnr)
	local entry = registry.waiting[bufnr]
	if not entry or entry.failed or registry.states[bufnr] or not vim.api.nvim_buf_is_valid(bufnr) then
		return
	end
	local text, segments = compose(describe_pending(bufnr, entry))
	vim.bo[bufnr].modifiable = true
	vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { text })
	vim.bo[bufnr].modifiable = false
	highlight.paint_line(bufnr, NAMESPACE, 1, text, segments)
end

--- Rewrite only the footer line, never a render (ADR-0040, ADR-0045); see doc/internals.md#grid.
local function repaint_footer(bufnr)
	local state = registry.states[bufnr]
	if not state or not state.lines or not vim.api.nvim_buf_is_valid(bufnr) then
		return
	end
	local text, segments = M.footer(bufnr, state)
	local line = #state.rows + 4
	state.lines[line] = text
	vim.bo[bufnr].modifiable = true
	vim.api.nvim_buf_set_lines(bufnr, line - 1, line, false, { text })
	vim.bo[bufnr].modifiable = false
	highlight.paint_line(bufnr, NAMESPACE, line, text, segments)
end

--- Redraw whatever carries a tab's status: the pending body or the footer line.
function M.refresh(bufnr)
	if registry.states[bufnr] then
		repaint_footer(bufnr)
	elseif registry.waiting[bufnr] then
		M.paint_pending(bufnr)
	end
end

-- Fast enough to read as moving; the cost per tick is one option assignment per window.
local TICK_MS = 100
local ticker = nil

--- Stop the clock: the timer is closed as well as stopped (ADR-0045).
local function stop_ticking()
	if ticker then
		ticker:stop()
		ticker:close()
		ticker = nil
	end
end

--- Keep one timer for the module while any tab is executing, and none when none is.
function M.sync_clock()
	local running = false
	for bufnr in pairs(registry.clocks) do
		if vim.api.nvim_buf_is_valid(bufnr) then
			running = true
		else
			registry.clocks[bufnr] = nil
		end
	end
	if not running then
		return stop_ticking()
	end
	if ticker then
		return
	end
	ticker = vim.uv.new_timer()
	-- Its own augroup, created with clear, so repeated starts keep one autocmd
	-- and never collide with the per-buffer cursor-sync groups (ADR-0040).
	vim.api.nvim_create_autocmd("VimLeavePre", {
		group = vim.api.nvim_create_augroup("NeogripGridClock", { clear = true }),
		callback = stop_ticking,
	})
	ticker:start(
		TICK_MS,
		TICK_MS,
		vim.schedule_wrap(function()
			for bufnr in pairs(registry.clocks) do
				M.refresh(bufnr)
			end
		end)
	)
end

--- Whether the clock is running, for the suites.
function M.ticking()
	return ticker ~= nil
end

return M
