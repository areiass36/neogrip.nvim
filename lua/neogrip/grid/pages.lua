-- The batches a result accumulates (ADR-0040) and the places in it a reader can jump to.
local cursor = require("neogrip.grid.cursor")
local registry = require("neogrip.grid.registry")
local render = require("neogrip.grid.render")
local status = require("neogrip.grid.status")

local M = {}

--- Replace the whole result in place, for a re-run: a different sort, or the
--- same statement asked again.
function M.set_result(bufnr, result)
	local state = registry.states[bufnr]
	if not state then
		return
	end
	registry.release_replaced(state, result)
	state.result = result
	state.columns = result.columns or {}
	state.rows = result.rows or {}
	state.batches = { { first = 1, last = #(result.rows or {}) } }
	state.auto = {}
	state.expired = nil
	state.lines = nil
	state.drawn = nil
	state.layout = nil
	state.documents = result.documents
	state.row = 1
	state.column = math.min(state.column, math.max(#state.columns, 1))
	render.draw(bufnr)
	local winid = registry.find_window(bufnr)
	if winid then
		cursor.focus_cell(bufnr, winid)
	end
end

--- Append a batch continued from the open cursor (ADR-0040, ADR-0031): rows
--- accumulate and the cursor is never moved.
--- @return integer appended how many rows the batch brought
function M.add_page(bufnr, batch)
	local state = registry.states[bufnr]
	if not state then
		return 0
	end
	local rows = batch.rows or {}
	local first = #state.rows + 1
	for _, row in ipairs(rows) do
		state.rows[#state.rows + 1] = row
	end
	-- A batch that brought nothing is not a place in the result, so it is not recorded as one.
	if #rows > 0 then
		state.batches[#state.batches + 1] = { first = first, last = #state.rows }
	end
	-- Kept index-aligned with state.rows (ADR-0040): holes mean "no document behind this row".
	if state.documents and batch.documents then
		for index, document in ipairs(batch.documents) do
			state.documents[first + index - 1] = document
		end
	end
	if batch.columns and #batch.columns > #state.columns then
		state.columns = batch.columns
		state.result.column_types = batch.column_types
		state.result.column_tables = batch.column_tables
		state.result.column_schemas = batch.column_schemas
	end
	registry.clocks[bufnr] = nil
	status.sync_clock()
	state.result.done = batch.done
	-- The statement's own time is kept, not this batch's; see doc/internals.md#grid.
	state.last_batch_ms = batch.elapsed_ms
	local moved = render.draw(bufnr)
	-- When the table moved sideways the byte column addresses another cell, so
	-- the cursor is put back on the cell it was in.
	if moved then
		local winid = registry.find_window(bufnr)
		if winid then
			cursor.focus_cell(bufnr, winid)
		end
	end
	return #rows
end

--- Jump to where a batch began; nothing is fetched and nothing is redrawn.
function M.goto_page(bufnr, index)
	local state = registry.states[bufnr]
	local batch = state and state.batches and state.batches[index]
	if not batch then
		return
	end
	state.row = math.min(batch.first, math.max(#state.rows, 1))
	state.column = math.min(state.column, math.max(#state.columns, 1))
	cursor.refocus(bufnr)
end

return M
