-- The result window.
--
-- A scratch buffer with its own filetype, so editor-wide autocommands leave it
-- alone, and so the user's own FileType autocommand has a hook to put keymaps
-- on - the plugin itself defines none (ADR-0017): every movement and action is
-- a function in neogrip.grid.actions.
--
-- The rendered text is only a picture of the result: yanking and exporting read
-- the untruncated value out of state.rows.
local neogrip = require("neogrip")
local highlight = require("neogrip.grid.highlight")
local layout = require("neogrip.grid.layout")
local value_module = require("neogrip.value")

local M = {}

M.FILETYPE = "neogrip-grid"

local NAMESPACE = vim.api.nvim_create_namespace("neogrip_grid")
-- The current cell gets its own namespace so moving the cursor does not have to
-- repaint the table's highlights.
local CELL_NAMESPACE = vim.api.nvim_create_namespace("neogrip_grid_cell")
local CELL_PRIORITY = 150
-- A query this slow is worth noticing, so the time in the footer says so.
local SLOW_MS = 1000
local states = {}

--- @class neogrip.GridState
--- @field result table
--- @field columns string[]
--- @field rows any[][]
--- @field spans table
--- @field kinds table what each cell holds, keyed the same way as spans
--- @field layout neogrip.Layout
--- @field row integer current data row, 1-based
--- @field column integer current column, 1-based
--- @field origin_buf integer the query buffer this came from

function M.state(bufnr)
	return states[bufnr or vim.api.nvim_get_current_buf()]
end

--- The footer, and the byte span of each part so they can be told apart: which
--- connection answered, how many rows, how long it took.
---
--- An UPDATE or an INSERT has no columns and no rows, only a count of the rows
--- it touched, and this is the only place that count can appear: a window
--- saying "no rows" is a worse answer than the one the server gave.
--- @return string text
--- @return table segments list of { start_byte, end_byte, group }
local function footer(state)
	local result = state.result
	local connection = result.connection or {}
	local offset = result.offset or 0
	local range = ("%d-%d"):format(offset + 1, offset + #state.rows)
	if #state.rows == 0 then
		range = "no rows"
	end
	if #state.columns == 0 and result.update_count then
		local affected = result.update_count
		-- JDBC answers -1 when the driver will not say how many rows a
		-- statement touched, which is not the same as having touched none.
		if affected < 0 then
			range = "statement ran"
		else
			range = ("%d row%s affected"):format(affected, affected == 1 and "" or "s")
		end
	end
	local elapsed = result.elapsed_ms or 0
	local parts = {
		{
			("%s [%s]"):format(connection.name or "?", connection.driver or "?"),
			connection.production and "NGripGridProduction" or "NGripGridConnection",
		},
		{ range .. (result.has_more and " (more)" or ""), "NGripGridCount" },
		{ ("%d ms"):format(elapsed), elapsed >= SLOW_MS and "NGripGridSlow" or "NGripGridElapsed" },
	}
	if state.has_binary then
		parts[#parts + 1] = { "binary column: select encode(col,'hex') to read it", "NGripGridBinary" }
	end

	local SEPARATOR = "  ·  "
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

local function render(bufnr)
	local state = states[bufnr]
	if not state then
		return
	end

	local computed = layout.compute(state.columns, state.rows, {})
	local lines, spans, kinds = layout.render(computed, state.columns, state.rows, {})
	state.layout = computed
	state.spans = spans
	state.kinds = kinds

	-- Which cells are bytes that were never text is already known, from the
	-- same walk that decided every other cell's colour.
	state.has_binary = false
	for _, row_kinds in pairs(kinds) do
		for _, kind in pairs(row_kinds) do
			if kind == "binary" then
				state.has_binary = true
				break
			end
		end
		if state.has_binary then
			break
		end
	end

	local footer_text, footer_segments = footer(state)
	table.insert(lines, "")
	table.insert(lines, footer_text)

	vim.bo[bufnr].modifiable = true
	vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
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
	})

	M.highlight_cell(bufnr)
end

--- Underline the cell the cursor is in, so "which column am I on" is visible
--- in a wide table.
function M.highlight_cell(bufnr)
	local state = states[bufnr]
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
	local state = states[bufnr]
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

--- Work out which cell the cursor is sitting in after a plain motion.
function M.sync_from_cursor(bufnr, winid)
	local state = states[bufnr]
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
	local state = states[bufnr]
	if not state then
		return nil
	end
	local row = state.rows[state.row]
	return row and row[state.column]
end

local function find_window(bufnr)
	for _, winid in ipairs(vim.api.nvim_list_wins()) do
		if vim.api.nvim_win_get_buf(winid) == bufnr then
			return winid
		end
	end
	return nil
end

--- Plain cursor motions still have to know which cell they landed in. This is
--- an autocommand, not a keymap: the no-keymaps rule (ADR-0017) is about keys.
local function attach_cursor_sync(bufnr)
	if vim.b[bufnr].neogrip_grid_attached then
		return
	end
	vim.b[bufnr].neogrip_grid_attached = true
	vim.api.nvim_create_autocmd("CursorMoved", {
		group = vim.api.nvim_create_augroup("NeogripGrid" .. bufnr, { clear = true }),
		buffer = bufnr,
		callback = function()
			M.sync_from_cursor(bufnr)
		end,
	})
end

--- Show a result, reusing the window that already holds one.
--- @return integer bufnr
function M.show(result, context)
	context = context or {}
	local bufnr = M.current_buf()
	local winid

	if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
		winid = find_window(bufnr)
	else
		bufnr = vim.api.nvim_create_buf(false, true)
		vim.bo[bufnr].buftype = "nofile"
		vim.bo[bufnr].bufhidden = "hide"
		vim.bo[bufnr].swapfile = false
		vim.api.nvim_buf_set_name(bufnr, "neogrip://result")
		-- The filetype is set after the name so a user FileType autocommand
		-- sees the finished buffer.
		vim.bo[bufnr].filetype = M.FILETYPE
	end

	if not winid then
		local origin = vim.api.nvim_get_current_win()
		vim.cmd("botright split")
		winid = vim.api.nvim_get_current_win()
		vim.api.nvim_win_set_height(winid, math.max(10, math.floor(vim.o.lines * 0.4)))
		vim.api.nvim_win_set_buf(winid, bufnr)
		vim.wo[winid].wrap = false
		vim.wo[winid].number = false
		vim.wo[winid].relativenumber = false
		vim.wo[winid].cursorline = false
		if require("neogrip.config").get().row_numbers then
			vim.wo[winid].statuscolumn = "%!v:lua.require'neogrip.grid'.row_label()"
		end
		vim.api.nvim_set_current_win(origin)
	end

	states[bufnr] = {
		result = result,
		columns = result.columns or {},
		rows = result.rows or {},
		documents = result.documents,
		row = 1,
		column = 1,
		origin_buf = context.origin_buf,
		statement = context.statement,
	}
	M.buf = bufnr
	render(bufnr)
	attach_cursor_sync(bufnr)

	if context.focus ~= false then
		vim.api.nvim_set_current_win(winid)
		M.focus_cell(bufnr, winid)
	end
	return bufnr
end

function M.current_buf()
	if M.buf and vim.api.nvim_buf_is_valid(M.buf) then
		return M.buf
	end
	return nil
end

function M.refresh(bufnr)
	render(bufnr or M.current_buf())
end

function M.close(bufnr)
	bufnr = bufnr or M.current_buf()
	if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
		states[bufnr] = nil
		pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
	end
	M.buf = nil
end

--- Replace the rows in place, for paging and sorting.
function M.set_result(bufnr, result)
	local state = states[bufnr]
	if not state then
		return
	end
	state.result = result
	state.columns = result.columns or {}
	state.rows = result.rows or {}
	state.documents = result.documents
	state.row = 1
	state.column = math.min(state.column, math.max(#state.columns, 1))
	render(bufnr)
	local winid = find_window(bufnr)
	if winid then
		M.focus_cell(bufnr, winid)
	end
end

--- The whole document behind a Mongo row, which the grid flattens. The float
--- has no keymaps (ADR-0017): close it like any window.
function M.show_document(bufnr)
	local state = states[bufnr]
	if not state or not state.documents then
		neogrip.notify("no document behind this row", vim.log.levels.WARN)
		return
	end
	local document = state.documents[state.row]
	if not document then
		return
	end
	local ok, encoded = pcall(vim.json.encode, document)
	if not ok then
		return
	end
	-- vim.json has no pretty printer. jq is the nicest way to get one and is
	-- often around; without it the document is shown on a single line.
	local pretty = { encoded }
	if vim.fn.executable("jq") == 1 then
		local formatted = vim.system({ "jq", "." }, { stdin = encoded, text = true }):wait()
		if formatted.code == 0 then
			pretty = vim.split(formatted.stdout or encoded, "\n", { trimempty = true })
		end
	end
	local float = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_buf_set_lines(float, 0, -1, false, pretty)
	vim.bo[float].filetype = "json"
	vim.bo[float].modifiable = false
	vim.bo[float].bufhidden = "wipe"
	vim.api.nvim_open_win(float, true, {
		relative = "editor",
		row = 1,
		col = 2,
		width = vim.o.columns - 4,
		height = vim.o.lines - 6,
		border = "rounded",
		title = " document ",
		title_pos = "center",
		style = "minimal",
	})
end

--- The ordinal shown in the left gutter for a given buffer line, pure so the
--- test can check it without a window: the first two lines are the header and
--- the rule, the data rows are 1..N below them, and the trailing blank and
--- footer get nothing.
--- @return string right-aligned ordinal, or "" for a non-data line
function M.row_number_for(bufnr, lnum)
	local state = states[bufnr]
	if not state then
		return ""
	end
	local row = lnum - 2
	if row < 1 or row > #state.rows then
		return ""
	end
	local width = #tostring(#state.rows)
	return ("%" .. width .. "d "):format(row)
end

--- The 'statuscolumn' entry point: reads the line and window being drawn.
function M.row_label()
	local winid = vim.g.statusline_winid
	local bufnr = winid and winid > 0 and vim.api.nvim_win_get_buf(winid) or vim.api.nvim_get_current_buf()
	return M.row_number_for(bufnr, vim.v.lnum)
end

M.display = value_module.display

return M
