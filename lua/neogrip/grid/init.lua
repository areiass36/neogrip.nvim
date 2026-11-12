-- The result window. The rendered text is only a picture of the result:
-- yanking and exporting read the untruncated value out of state.rows.
local neogrip = require("neogrip")
local highlight = require("neogrip.grid.highlight")
local layout = require("neogrip.grid.layout")
local value_module = require("neogrip.value")

local M = {}

M.FILETYPE = "neogrip-grid"

local NAMESPACE = vim.api.nvim_create_namespace("neogrip_grid")
-- Its own namespace so moving the cursor does not repaint the table's highlights.
local CELL_NAMESPACE = vim.api.nvim_create_namespace("neogrip_grid_cell")
local CELL_PRIORITY = 150
local SLOW_MS = 1000
local states = {}
-- Tabs whose query has not answered yet: deliberately no entry in `states`,
-- so nothing renders "no rows" for a result that has not arrived (ADR-0044).
local waiting = {}
-- When the statement in a tab began executing, by the server's word (ADR-0042);
-- nil when nothing is executing in it.
local clocks = {}
-- One window holds every tab; switching is setting its buffer (ADR-0044).
local tabs = {}
local active = 0
-- Never reused: a hidden tab still holds its buffer name and a duplicate name is an error.
local minted = 0
local forget
local paint_strip

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

function M.state(bufnr)
	return states[bufnr or vim.api.nvim_get_current_buf()]
end

--- How long the statement in a tab has been executing, in ms; nil when nothing is.
--- Measured from gripd saying it had begun (ADR-0042), so queue and connect time are not in it.
local function elapsed_of(bufnr)
	local started = clocks[bufnr]
	if not started then
		return nil
	end
	return math.floor((vim.uv.hrtime() - started) / 1e6)
end

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
	local elapsed = elapsed_of(bufnr) or result.elapsed_ms or 0
	return {
		{
			("%s [%s]"):format(connection.name or "?", connection.driver or "?"),
			connection.production and "NGripGridProduction" or "NGripGridConnection",
		},
		{ range .. suffix, "NGripGridCount" },
		{ ("%d ms"):format(elapsed), elapsed >= SLOW_MS and "NGripGridSlow" or "NGripGridElapsed" },
	}
end

local SEPARATOR = "  ·  "

--- Escape '%' so the text is safe inside a statusline-format string.
local function escape(text)
	return (tostring(text):gsub("%%", "%%%%"))
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
	local elapsed = elapsed_of(bufnr)
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
local function footer(bufnr, state)
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
	if waiting[bufnr] then
		return (compose(describe_pending(bufnr, waiting[bufnr])))
	end
	if states[bufnr] then
		return (footer(bufnr, states[bufnr]))
	end
	return ""
end

--- Write the status line into a pending tab's body (ADR-0045), skipping a
--- failed tab and a reused one whose rows are still on screen.
local function paint_pending(bufnr)
	local entry = waiting[bufnr]
	if not entry or entry.failed or states[bufnr] or not vim.api.nvim_buf_is_valid(bufnr) then
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
	local state = states[bufnr]
	if not state or not state.lines or not vim.api.nvim_buf_is_valid(bufnr) then
		return
	end
	local text, segments = footer(bufnr, state)
	local line = #state.rows + 4
	state.lines[line] = text
	vim.bo[bufnr].modifiable = true
	vim.api.nvim_buf_set_lines(bufnr, line - 1, line, false, { text })
	vim.bo[bufnr].modifiable = false
	highlight.paint_line(bufnr, NAMESPACE, line, text, segments)
end

--- Redraw whatever carries a tab's status: the pending body or the footer line.
local function refresh_status(bufnr)
	if states[bufnr] then
		repaint_footer(bufnr)
	elseif waiting[bufnr] then
		paint_pending(bufnr)
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
local function sync_ticker()
	local running = false
	for bufnr in pairs(clocks) do
		if vim.api.nvim_buf_is_valid(bufnr) then
			running = true
		else
			clocks[bufnr] = nil
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
			for bufnr in pairs(clocks) do
				refresh_status(bufnr)
			end
		end)
	)
end

--- Whether the clock is running, for the suites.
function M._ticking()
	return ticker ~= nil
end

local function render(bufnr)
	local state = states[bufnr]
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
	local footer_text, footer_segments = footer(bufnr, state)
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

	M.highlight_cell(bufnr)
	return moved
end

--- Underline the cell the cursor is in.
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

-- Holding `j` asks once, not per line; see doc/internals.md#grid.
local DEBOUNCE_MS = 120
local pending = {}

--- Ask for the next batch once the cursor has stopped moving. Without the
--- debounce the batch lands where the cursor was, not where it came to rest.
local function schedule_load(bufnr)
	local state = states[bufnr]
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
		local current = states[bufnr]
		if not vim.api.nvim_buf_is_valid(bufnr) or not current then
			return
		end
		if current.result.hash ~= hash then
			return
		end
		-- Required late to avoid a require cycle with execute.
		require("neogrip.execute").load_more(current, { quiet = true })
	end, DEBOUNCE_MS)
end

--- Load the next batch when the cursor is within `auto_load_rows` of the last
--- row loaded (ADR-0040). Takes the line so it can be driven without a window (ADR-0023).
--- @param line integer|nil the cursor's buffer line; the window's when absent
--- @return boolean armed whether a load was scheduled
function M.maybe_load_more(bufnr, line)
	local state = states[bufnr]
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
		local winid = find_window(bufnr)
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

--- An autocommand, not a keymap: the no-keymaps rule (ADR-0017) is about keys.
--- The group's name carries the buffer number; see doc/internals.md#grid.
local function attach_cursor_sync(bufnr)
	if vim.b[bufnr].neogrip_grid_attached then
		return
	end
	vim.b[bufnr].neogrip_grid_attached = true
	local group = vim.api.nvim_create_augroup("NeogripGrid" .. bufnr, { clear = true })
	vim.api.nvim_create_autocmd("CursorMoved", {
		group = group,
		buffer = bufnr,
		callback = function()
			M.sync_from_cursor(bufnr)
			M.maybe_load_more(bufnr)
		end,
	})
	-- BufWipeout, not only BufDelete; see doc/internals.md#grid.
	vim.api.nvim_create_autocmd({ "BufDelete", "BufWipeout" }, {
		group = group,
		buffer = bufnr,
		callback = function()
			forget(bufnr)
		end,
	})
end

--- Hand back the cursor of the result a tab is about to stop holding - one of
--- the reclamation paths ADR-0041 requires.
local function release_replaced(state, result)
	local stale = state and state.result and state.result.hash
	if stale and stale ~= result.hash and state.result.connection then
		require("neogrip.runner").release(state.result.connection, stale)
	end
end

-- Enough of the statement to tell two queries apart in `:ls`.
local LABEL_WIDTH = 32
-- The strip is tighter: a cell about the size of a file name in the native tab bar.
local STRIP_WIDTH = 18

--- The statement, compressed into a label; '/' and '\' are replaced or the
--- buffer name's tail would be cut at the first one inside the SQL.
local function label_of(text, width)
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

--- A fresh scratch buffer for one tab, unlisted: the strip names the tabs (ADR-0045).
local function new_tab_buffer(label)
	local bufnr = vim.api.nvim_create_buf(false, true)
	vim.bo[bufnr].buftype = "nofile"
	vim.bo[bufnr].bufhidden = "hide"
	vim.bo[bufnr].swapfile = false
	minted = minted + 1
	-- The counter keeps the name unique; the label sits after the last '/' so
	-- the tail of the name is the statement, not the counter.
	vim.api.nvim_buf_set_name(bufnr, ("neogrip://%d/%s"):format(minted, label_of(label)))
	-- Set after the name so a user FileType autocommand sees the finished buffer.
	vim.bo[bufnr].filetype = M.FILETYPE
	return bufnr
end

--- The window the tabs live in, whichever one of them it is showing.
local function grid_window()
	local current = M.current_buf()
	if current then
		local winid = find_window(current)
		if winid then
			return winid
		end
	end
	for _, bufnr in ipairs(tabs) do
		local winid = find_window(bufnr)
		if winid then
			return winid
		end
	end
	return nil
end

--- What names a tab in the strip: the statement it ran, or the buffer name's label.
local function tab_label(bufnr)
	local entry = waiting[bufnr]
	local state = states[bufnr]
	local statement = (entry and entry.statement) or (state and state.statement)
	if statement and statement.text then
		return label_of(statement.text, STRIP_WIDTH)
	end
	local name = vim.api.nvim_buf_get_name(bufnr)
	return label_of(name:match("([^/\\]+)$"), STRIP_WIDTH)
end

--- The tab strip for the result window's 'winbar' (ADR-0045), in the native
--- tabline's faces.
--- @param bufnr integer the tab on screen, the one marked active
--- @return string ready for 'winbar'
function M.strip_text(bufnr)
	if #tabs == 0 then
		return ""
	end
	local out = {}
	for index, tab in ipairs(tabs) do
		local group = "NGripGridTab"
		local entry = waiting[tab]
		if tab == bufnr then
			group = "NGripGridTabActive"
		elseif entry and entry.failed then
			group = "NGripGridTabError"
		elseif entry then
			group = "NGripGridTabRunning"
		end
		out[#out + 1] = ("%%#%s# %d %s "):format(group, index, escape(tab_label(tab)))
	end
	return table.concat(out, "") .. "%#NGripGridTabFill#"
end

--- Hang the strip on the result window as a literal string, never a `%!`
--- expression: assigning the option already marks the window for redraw (ADR-0045).
function paint_strip()
	local winid = grid_window()
	if not winid then
		return
	end
	local text = M.strip_text(vim.api.nvim_win_get_buf(winid))
	pcall(vim.api.nvim_set_option_value, "winbar", text, { win = winid, scope = "local" })
end

--- Open the result window if it is not open, and show this tab in it.
local function open_window(bufnr)
	local winid = grid_window()
	if winid then
		if vim.api.nvim_win_get_buf(winid) ~= bufnr then
			vim.api.nvim_win_set_buf(winid, bufnr)
		end
		return winid
	end
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
	return winid
end

--- Put a tab in the list if it is new, and make it the one the window shows.
local function activate(bufnr)
	for index, tab in ipairs(tabs) do
		if tab == bufnr then
			active = index
			paint_strip()
			return
		end
	end
	tabs[#tabs + 1] = bufnr
	active = #tabs
	paint_strip()
end

--- Open a tab for a query that has not answered yet (ADR-0044); the tab must
--- exist before the request leaves because the runner can answer synchronously.
--- `into` reuses a tab instead of opening one, which is what a sort does.
--- @param opts table { into, hash, connection, origin_buf, statement, label, focus }
--- @return integer bufnr
function M.open_pending(opts)
	local bufnr = opts.into
	if not (bufnr and vim.api.nvim_buf_is_valid(bufnr)) then
		bufnr = new_tab_buffer(opts.statement and opts.statement.text or opts.label)
	end
	waiting[bufnr] = {
		hash = opts.hash,
		connection = opts.connection,
		origin_buf = opts.origin_buf,
		statement = opts.statement,
		label = opts.label,
		phase = "sent",
	}
	local winid = open_window(bufnr)
	activate(bufnr)
	-- Attached before any result, so :bd on an abandoned tab still reaches the bookkeeping.
	attach_cursor_sync(bufnr)
	paint_pending(bufnr)
	if opts.focus then
		vim.api.nvim_set_current_win(winid)
	end
	return bufnr
end

--- Whether a tab is still waiting for its answer.
function M.is_pending(bufnr)
	return waiting[bufnr] ~= nil
end

--- Remember the handle, so closing the tab can cancel the request behind it.
function M.attach_handle(bufnr, handle)
	local entry = waiting[bufnr]
	if entry then
		entry.handle = handle
	end
end

--- Where a pending query has got to: a phase from the runner, or gripd saying
--- the statement has begun executing (ADR-0042), which is what starts the clock.
function M.progress(bufnr, event)
	if not event or not (waiting[bufnr] or states[bufnr]) then
		return
	end
	if waiting[bufnr] then
		waiting[bufnr].phase = event.phase
	end
	if event.phase == "executing" then
		-- Restarted: a refill is another execution and its own wait.
		clocks[bufnr] = vim.uv.hrtime()
	end
	sync_ticker()
	refresh_status(bufnr)
	paint_strip()
end

--- The query failed, was refused or was cancelled; the tab stays and says so (ADR-0044).
--- @param err table the translated error - already redacted by errors.from_rpc,
---            because a raw driver message can carry a secret
function M.fail(bufnr, err)
	local entry = waiting[bufnr]
	if not entry or not vim.api.nvim_buf_is_valid(bufnr) then
		return
	end
	clocks[bufnr] = nil
	entry.failed = err and err.cancelled and "cancelled" or "failed"
	entry.handle = nil
	sync_ticker()
	-- A reused tab - a sort whose re-run failed - keeps its rows; only an empty
	-- tab gets the message as its body.
	if not states[bufnr] then
		local message = err and err.message or "the statement did not run"
		vim.bo[bufnr].modifiable = true
		vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, vim.split(message, "\n", { plain = true }))
		vim.bo[bufnr].modifiable = false
	end
	paint_strip()
end

--- Show a result, reusing the window that already holds one.
--- @param context table|nil { into, origin_buf, statement, focus }
--- @return integer bufnr
function M.show(result, context)
	context = context or {}
	local bufnr = context.into
	if not (bufnr and vim.api.nvim_buf_is_valid(bufnr)) then
		bufnr = M.current_buf()
	end
	if not (bufnr and vim.api.nvim_buf_is_valid(bufnr)) then
		bufnr = new_tab_buffer(context.statement and context.statement.text)
	end

	local pending_entry = waiting[bufnr]
	waiting[bufnr] = nil
	clocks[bufnr] = nil
	sync_ticker()
	release_replaced(states[bufnr], result)

	local winid = open_window(bufnr)
	activate(bufnr)

	states[bufnr] = {
		result = result,
		bufnr = bufnr,
		columns = result.columns or {},
		rows = result.rows or {},
		batches = { { first = 1, last = #(result.rows or {}) } },
		auto = {},
		documents = result.documents,
		row = 1,
		column = 1,
		origin_buf = context.origin_buf or (pending_entry and pending_entry.origin_buf),
		statement = context.statement or (pending_entry and pending_entry.statement),
		label = pending_entry and pending_entry.label,
	}
	render(bufnr)
	attach_cursor_sync(bufnr)

	if context.focus ~= false then
		vim.api.nvim_set_current_win(winid)
		M.focus_cell(bufnr, winid)
	end
	return bufnr
end

--- The tab the window is showing, or nil when there is none.
function M.current_buf()
	local bufnr = tabs[active]
	if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
		return bufnr
	end
	return nil
end

--- Every tab, oldest first. A copy: the list is the grid's own.
function M.tabs()
	return vim.list_extend({}, tabs)
end

--- Which tab is showing, 1-based, or 0 when there is none.
function M.active_tab()
	return active
end

function M.refresh(bufnr)
	render(bufnr or M.current_buf())
end

--- Forget a tab: hand its result back and drop every trace of it. Idempotent:
--- one close reaches it directly and again through the buffer autocommands.
function forget(bufnr)
	if not bufnr then
		return
	end
	local state = states[bufnr]
	-- Nothing evicts an open result any more (ADR-0041), so a closed grid would
	-- otherwise hold its cursor until the idle sweep an hour later.
	local result = state and state.result
	if result and result.hash and result.connection then
		require("neogrip.runner").release(result.connection, result.hash)
	end
	-- A tab dismissed before it answered takes its request with it.
	local entry = waiting[bufnr]
	if entry and entry.handle then
		require("neogrip.runner").cancel(entry.handle)
	end
	waiting[bufnr] = nil
	states[bufnr] = nil
	clocks[bufnr] = nil
	sync_ticker()
	if pending[bufnr] then
		pending[bufnr]:stop()
		pending[bufnr] = nil
	end
	for index, tab in ipairs(tabs) do
		if tab == bufnr then
			table.remove(tabs, index)
			if active > index then
				active = active - 1
			elseif active == index then
				active = math.min(index, #tabs)
			end
			break
		end
	end
	if #tabs == 0 then
		active = 0
	end
	paint_strip()
end

--- Show the tab at this index; out of range is a no-op.
function M.goto_tab(index)
	local bufnr = tabs[index]
	if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
		return nil
	end
	active = index
	local winid = grid_window()
	if winid then
		vim.api.nvim_win_set_buf(winid, bufnr)
		paint_strip()
		if states[bufnr] then
			M.focus_cell(bufnr, winid)
		end
	end
	return bufnr
end

--- Step through the tabs, wrapping at each end.
function M.step_tab(delta)
	if #tabs == 0 then
		return nil
	end
	return M.goto_tab((active - 1 + delta) % #tabs + 1)
end

function M.close(bufnr)
	bufnr = bufnr or M.current_buf()
	if not bufnr then
		return
	end
	-- The window is handed its next tab before the buffer goes; only the last
	-- tab lets the window go with it.
	local winid = find_window(bufnr)
	forget(bufnr)
	local neighbour = tabs[active]
	if winid and neighbour and vim.api.nvim_buf_is_valid(neighbour) then
		pcall(vim.api.nvim_win_set_buf, winid, neighbour)
		paint_strip()
	end
	if vim.api.nvim_buf_is_valid(bufnr) then
		pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
	end
end

--- Replace the whole result in place, for a re-run: a different sort, or the
--- same statement asked again.
function M.set_result(bufnr, result)
	local state = states[bufnr]
	if not state then
		return
	end
	release_replaced(state, result)
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
	render(bufnr)
	local winid = find_window(bufnr)
	if winid then
		M.focus_cell(bufnr, winid)
	end
end

--- Append a batch continued from the open cursor (ADR-0040, ADR-0031): rows
--- accumulate and the cursor is never moved.
--- @return integer appended how many rows the batch brought
function M.add_page(bufnr, batch)
	local state = states[bufnr]
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
	clocks[bufnr] = nil
	sync_ticker()
	state.result.done = batch.done
	-- The statement's own time is kept, not this batch's; see doc/internals.md#grid.
	state.last_batch_ms = batch.elapsed_ms
	local moved = render(bufnr)
	-- When the table moved sideways the byte column addresses another cell, so
	-- the cursor is put back on the cell it was in.
	if moved then
		local winid = find_window(bufnr)
		if winid then
			M.focus_cell(bufnr, winid)
		end
	end
	return #rows
end

--- Jump to where a batch began; nothing is fetched and nothing is redrawn.
function M.goto_page(bufnr, index)
	local state = states[bufnr]
	local batch = state and state.batches and state.batches[index]
	if not batch then
		return
	end
	state.row = math.min(batch.first, math.max(#state.rows, 1))
	state.column = math.min(state.column, math.max(#state.columns, 1))
	local winid = find_window(bufnr)
	if winid then
		M.focus_cell(bufnr, winid)
	else
		M.highlight_cell(bufnr)
	end
end

--- The whole document behind a Mongo row; the float has no keymaps (ADR-0017).
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
	-- vim.json has no pretty printer; without jq the document is shown on a single line.
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

--- The ordinal shown in the left gutter for a given buffer line.
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
	-- A width floor stops re-widthing mid-scroll (ADR-0040); see doc/internals.md#grid.
	local width = math.max(4, #tostring(#state.rows))
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
