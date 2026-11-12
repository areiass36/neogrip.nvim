-- Drawing a result into its tab. The rendered text is only a picture of the result:
-- yanking and exporting read the untruncated value out of state.rows.
local cursor = require("neogrip.grid.cursor")
local highlight = require("neogrip.grid.highlight")
local layout = require("neogrip.grid.layout")
local registry = require("neogrip.grid.registry")
local status = require("neogrip.grid.status")

local M = {}

local NAMESPACE = vim.api.nvim_create_namespace("neogrip_grid")

--- @return boolean|nil moved whether the columns changed width, which moves every byte span
function M.draw(bufnr)
	local state = registry.states[bufnr]
	if not state then
		return
	end

	local computed = layout.compute(state.columns, state.rows, {})
	-- A batch that widens a column shifts every byte span, so the caller has to
	-- put the cursor back on its cell rather than leave it on the byte.
	local moved = false
	local previous = state.layout and state.layout.widths or nil
	if previous == nil or #previous ~= #computed.widths then
		moved = true
	else
		for index, width in ipairs(computed.widths) do
			if previous[index] ~= width then
				moved = true
				break
			end
		end
	end
	-- Reuse what is already drawn; see doc/internals.md#grid.
	local drawn = state.drawn or 0
	local reuse = not moved and state.lines ~= nil and drawn > 0 and #state.rows >= drawn
	local lines, spans, kinds
	if reuse then
		lines, spans, kinds = state.lines, state.spans, state.kinds
		if #state.rows > drawn then
			local tail_lines, tail_spans, tail_kinds =
				layout.render(computed, state.columns, state.rows, { from = drawn + 1 })
			for line, text in pairs(tail_lines) do
				lines[line] = text
			end
			for line, row_spans in pairs(tail_spans) do
				spans[line] = row_spans
			end
			for line, row_kinds in pairs(tail_kinds) do
				kinds[line] = row_kinds
			end
		end
	else
		lines, spans, kinds = layout.render(computed, state.columns, state.rows, {})
		state.has_binary = false
	end
	state.layout = computed
	state.spans = spans
	state.kinds = kinds

	-- has_binary stays true once set, so a reused render only scans the rows it just added.
	if not state.has_binary then
		local scan_from = reuse and (drawn + 1) or 1
		for row = scan_from, #state.rows do
			for _, kind in pairs(kinds[row + 2] or {}) do
				if kind == "binary" then
					state.has_binary = true
					break
				end
			end
			if state.has_binary then
				break
			end
		end
	end

	-- The blank and the footer sit immediately after the rows, so appending overwrites them.
	local footer_text, footer_segments = status.footer(bufnr, state)
	local last = #state.rows + 2
	lines[last + 1] = ""
	lines[last + 2] = footer_text
	for index = last + 3, #lines do
		lines[index] = nil
	end
	state.lines = lines
	state.drawn = #state.rows

	vim.bo[bufnr].modifiable = true
	if reuse then
		-- Only the tail is written back: writing the whole array kept the cost
		-- of a batch growing with the result.
		local tail = {}
		for index = drawn + 3, #lines do
			tail[#tail + 1] = lines[index]
		end
		vim.api.nvim_buf_set_lines(bufnr, drawn + 2, -1, false, tail)
	else
		vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
	end
	vim.bo[bufnr].modifiable = false

	local sorted_column = nil
	for index, column in ipairs(state.columns) do
		if state.result.order_by and tostring(column) == state.result.order_by then
			sorted_column = index
			break
		end
	end

	highlight.paint(bufnr, NAMESPACE, {
		lines = lines,
		spans = spans,
		kinds = kinds,
		rows = #state.rows,
		sorted_column = sorted_column,
		footer = { line = #lines, segments = footer_segments },
		from = reuse and (drawn + 1) or 1,
	})

	cursor.highlight_cell(bufnr)
	return moved
end

return M
