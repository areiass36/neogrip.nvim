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
-- Tabs whose query has not answered yet (ADR-0044). A pending tab deliberately
-- has no entry in `states`: rendering one would draw a header with no columns
-- and "no rows", which reads as "the query returned nothing" - a worse lie than
-- an empty window. The winbar is the whole message until rows arrive.
local waiting = {}
-- When the statement in a tab began executing, by the server's word (ADR-0042),
-- or nil when nothing is executing in it. One table for both cases a clock can
-- run in: a tab waiting for its first answer, and one whose window drained and
-- made gripd re-execute - the slowest wait there is.
local clocks = {}
-- The result buffers, in the order they were opened, and which of them the
-- window is showing (ADR-0044). One window holds all of them; switching is
-- setting its buffer.
local tabs = {}
local active = 0
-- Never reused, because a hidden tab the user has not deleted still holds its
-- buffer name and a duplicate name is an error.
local minted = 0
-- Declared up here because the BufDelete autocommand is attached before the
-- definition and has to reach it.
local forget
-- Declared up here because the winbar is painted above, and the strip it draws
-- names every tab, so a change to one tab repaints whichever tab is on screen.
local find_window
local grid_window

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

--- How long the statement in a tab has been executing, in ms.
---
--- Measured from the moment gripd said it had begun (ADR-0042), so the queue,
--- the connect and a first-use compile of gripd are not in it. Nil when nothing
--- is executing, which is what keeps a number off the screen that would be
--- counting the wrong thing.
local function elapsed_of(bufnr)
	local started = clocks[bufnr]
	if not started then
		return nil
	end
	return math.floor((vim.uv.hrtime() - started) / 1e6)
end

--- The three things said about a result: which connection answered, how many
--- rows are here, and how long the statement took.
---
--- Shared by the footer and the winbar so the two cannot drift apart. The
--- footer adds a fourth part of its own; the winbar has no room for a sentence.
---
--- An UPDATE or an INSERT has no columns and no rows, only a count of the rows
--- it touched, and this is the only place that count can appear: a window
--- saying "no rows" is a worse answer than the one the server gave.
--- @return table parts list of { text, group }
local function describe(bufnr, state)
	local result = state.result
	local connection = result.connection or {}
	-- A count, not a range: rows accumulate, so the first one on screen is
	-- always row one and the only interesting number is how many are here.
	local range = ("%d rows"):format(#state.rows)
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
	-- `done` stays false on a result whose cursor the server has dropped, which
	-- is true of the cursor and a lie about the rows - so the footer asks both.
	local more = result.done == false and not state.expired
	local auto = state.auto or {}
	local cap = require("neogrip.config").get().auto_load_max_rows
	local suffix = ""
	if state.expired then
		suffix = " (expired)"
	elseif more and auto.loading then
		suffix = " (more, loading...)"
	elseif more and cap and cap > 0 and #state.rows >= cap then
		-- Paused, not stopped: page_next still loads past the cap. No key is
		-- named here because the plugin maps none (ADR-0017).
		suffix = " (more, paused)"
	elseif more then
		suffix = " (more)"
	end
	-- A refill is executing right now, so the number that matters is how long it
	-- has been going, not how long the last batch took. The footer is where a
	-- finished time belongs; this is the only live one (ADR-0042).
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

--- What separates one part from the next, in the footer and in the winbar.
local SEPARATOR = "  ·  "

--- Make a value safe to put in a statusline-format string. A per cent in a
--- connection name would otherwise be read as the start of an item.
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
		-- A word and never a number: until the server says it has begun, any
		-- number on screen would be counting something the reader did not ask
		-- about (ADR-0043).
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

--- The winbar of a result window (ADR-0043).
---
--- For a result, says what the footer says, which is worth saying twice because
--- the footer sits after the last row: in a result read by scrolling it is
--- thousands of lines away, while this stays on screen. For a query still
--- running, it is the only thing on screen.
---
--- Pure on purpose, so a suite asserts it with no window at all - the way
--- row_number_for is already asserted.
--- @return string ready for 'winbar'
function M.winbar_text(bufnr)
	local parts
	if waiting[bufnr] then
		parts = describe_pending(bufnr, waiting[bufnr])
	elseif states[bufnr] then
		parts = describe(bufnr, states[bufnr])
	else
		return ""
	end
	local out = {}
	for _, part in ipairs(parts) do
		out[#out + 1] = ("%%#%s#%s"):format(part[2], escape(part[1]))
	end
	local text = table.concat(out, "%#NGripGridFooter#" .. SEPARATOR)
	local strip = M.tab_strip(bufnr)
	if strip ~= "" then
		text = strip .. "%#NGripGridFooter#" .. SEPARATOR .. text
	end
	return text
end

--- The tab strip: one number per tab, the one on screen marked.
---
--- Numbers and not statement text, because a label wide enough to tell two
--- queries apart leaves no room for the clock, and the number is what
--- grid.actions.goto_tab takes. Empty while there is only one tab: a strip of
--- one says nothing a reader does not already know.
--- @return string
function M.tab_strip(bufnr)
	if #tabs < 2 then
		return ""
	end
	local out = {}
	for index, tab in ipairs(tabs) do
		local group = "NGripGridTab"
		local entry = waiting[tab]
		if entry and entry.failed then
			group = "NGripGridTabError"
		elseif entry then
			group = "NGripGridTabRunning"
		elseif tab == bufnr then
			group = "NGripGridTabActive"
		end
		out[#out + 1] = ("%%#%s#%s%d"):format(group, tab == bufnr and "▸" or " ", index)
	end
	return table.concat(out, "")
end

--- Put the winbar on a result window.
---
--- Set as a literal string rather than a `%!` expression, and set per window
--- rather than globally: 'winbar' is global-local, and an expression would have
--- to be told to re-evaluate, which only :redrawstatus! reaches reliably and
--- which would re-evaluate every other window's statusline too (ADR-0043).
local function paint_winbar(winid, bufnr)
	pcall(vim.api.nvim_set_option_value, "winbar", M.winbar_text(bufnr), { win = winid, scope = "local" })
end

--- Redraw the winbar after something about a tab changed.
---
--- The result window is repainted whatever tab it is showing, because the strip
--- names every tab: a query finishing in a hidden tab changes the bar in front
--- of the reader. A window showing the tab that changed is repainted too, for
--- the case where it is not the result window.
function M.refresh_winbar(bufnr)
	local painting = {}
	local grid_win = grid_window()
	if grid_win then
		painting[grid_win] = vim.api.nvim_win_get_buf(grid_win)
	end
	if bufnr then
		for _, winid in ipairs(vim.api.nvim_list_wins()) do
			if vim.api.nvim_win_get_buf(winid) == bufnr then
				painting[winid] = bufnr
			end
		end
	end
	for winid, buffer in pairs(painting) do
		paint_winbar(winid, buffer)
	end
end

-- Fast enough to read as moving, slow enough that the cost is one option
-- assignment per window per tick and nothing else.
local TICK_MS = 100
local ticker = nil

--- Stop the clock and let go of the timer.
---
--- Closed as well as stopped, which the autoload debounce does not do and the
--- runner's watchdog does not even do the first half of (ADR-0043).
local function stop_ticking()
	if ticker then
		ticker:stop()
		ticker:close()
		ticker = nil
	end
end

--- Keep one timer for the module while any tab is executing, and none when
--- none is. One per tab would be a handle per query for the same redraw.
local function sync_ticker()
	local running = false
	for bufnr in pairs(clocks) do
		if vim.api.nvim_buf_is_valid(bufnr) then
			running = true
		else
			-- A buffer that went while its statement was executing: the answer
			-- can no longer land anywhere, so neither can its clock.
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
	ticker:start(
		TICK_MS,
		TICK_MS,
		vim.schedule_wrap(function()
			for bufnr in pairs(clocks) do
				M.refresh_winbar(bufnr)
			end
		end)
	)
end

--- Whether the clock is running. For the suites: a timer that outlives the
--- queries it was drawing is the failure this feature can have.
function M._ticking()
	return ticker ~= nil
end

--- The footer, and the byte span of each part so they can be told apart.
--- @return string text
--- @return table segments list of { start_byte, end_byte, group }
local function footer(bufnr, state)
	local parts = describe(bufnr, state)
	if state.has_binary then
		parts[#parts + 1] = { "binary column: select encode(col,'hex') to read it", "NGripGridBinary" }
	end

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
	-- Whether every line already drawn just moved sideways. A batch that widens
	-- a column shifts every byte span on every row before it, and the cursor's
	-- byte column then points at a different cell than it did - so the caller
	-- has to put the cursor back on the cell rather than leave it on the byte.
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
	-- Reuse what is already drawn when the table did not move sideways. A result
	-- read by scrolling re-renders on every batch, and a whole render measured
	-- 23 ms at 200 rows but 1091 ms at 10 000 and 1983 ms at 20 000 (eight
	-- columns: 425 ms of layout.render and 275 ms of highlight.paint at 10 000).
	-- Rendering and painting only the rows the batch brought holds a batch at
	-- 35-45 ms whatever is already held, which is what makes scrolling a long
	-- result possible at all rather than merely correct.
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

	-- Which cells are bytes that were never text is already known, from the same
	-- walk that decided every other cell's colour. Once true it stays true, so
	-- a reused render only has to look at the rows it just added.
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

	-- The blank and the footer sit immediately after the rows, so appending
	-- rows overwrites exactly where they were and nothing stale is left behind.
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
		-- Only the tail moved: the rows the batch brought, and the blank and
		-- footer that were sitting where they now go. Writing the whole array
		-- back was the last part of a batch whose cost still grew with the
		-- result; with this, a batch costs the same at twenty thousand rows as
		-- at four hundred.
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
	-- The winbar says the same three things as the footer, so it moves when
	-- they do: a batch that lands changes the count and the time.
	M.refresh_winbar(bufnr)
	return moved
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

function find_window(bufnr)
	for _, winid in ipairs(vim.api.nvim_list_wins()) do
		if vim.api.nvim_win_get_buf(winid) == bufnr then
			return winid
		end
	end
	return nil
end

-- Long enough that holding `j` asks once rather than once per line, short
-- enough that the rows are there by the time the eye arrives. The same 120 ms
-- the dialect module settled on for the same reason.
local DEBOUNCE_MS = 120
local pending = {}

--- Ask for the next batch once the cursor has stopped moving.
---
--- The debounce is not only politeness: it is what makes the in-flight guard
--- sufficient rather than merely safe. Without it the first motion fires a
--- request and the next forty are swallowed by that guard, so the batch lands
--- relative to where the cursor was instead of where it came to rest.
local function schedule_load(bufnr)
	local state = states[bufnr]
	if not state then
		return
	end
	if pending[bufnr] then
		pending[bufnr]:stop()
	end
	-- The result this was armed for. A grid can be closed, re-run or sorted
	-- inside the debounce, and the batch of a result nobody is looking at any
	-- more must not be appended to the one that replaced it.
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
		-- Required late: execute requires this module, so a require at the top
		-- would close the circle.
		require("neogrip.execute").load_more(current, { quiet = true })
	end, DEBOUNCE_MS)
end

--- Load the next batch when the cursor is within `auto_load_rows` of the last
--- row loaded (ADR-0040).
---
--- Takes the line rather than reading the window, so it can be driven with no
--- window at all, which is what makes it testable (ADR-0023). Separate from
--- sync_from_cursor because that one returns early past the last row, and
--- parking on the footer is precisely the case this has to answer.
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
	-- `limit = 0` means everything in one answer and no cursor kept, so a
	-- finished or unnamed result is checked before the threshold is worked out.
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
	-- The blank line and the footer sit past the last row, and resting there is
	-- "I am at the bottom" rather than nowhere, so they clamp up to it.
	local row = math.min(math.max(line - 2, 1), math.max(#state.rows, 1))
	if #state.rows - row > threshold then
		return false
	end
	schedule_load(bufnr)
	return true
end

--- Plain cursor motions still have to know which cell they landed in, and are
--- also what says the reader is near the end. This is an autocommand, not a
--- keymap: the no-keymaps rule (ADR-0017) is about keys.
---
--- Both hang off the one group. A second augroup of the same name created with
--- clear would delete this one, and the symptom - the cell highlight stops
--- following the cursor - names nothing that would lead anyone back here.
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
	vim.api.nvim_create_autocmd("BufDelete", {
		group = group,
		buffer = bufnr,
		callback = function()
			-- :bd in the result window has to leave the strip honest, so this
			-- is the same bookkeeping close does and not just the timer.
			forget(bufnr)
		end,
	})
end

--- Hand back the cursor of the result a tab is about to stop holding.
---
--- One of the four reclamation paths ADR-0041 requires, and it lives in the grid
--- rather than in execute because the grid is what knows a result is being
--- replaced: a sort reuses its tab, and the result it replaces is not coming
--- back, so gripd can let that cursor go now instead of an hour from now.
local function release_replaced(state, result)
	local stale = state and state.result and state.result.hash
	if stale and stale ~= result.hash and state.result.connection then
		require("neogrip.runner").release(state.result.connection, stale)
	end
end

--- A fresh scratch buffer for one tab.
local function new_tab_buffer()
	local bufnr = vim.api.nvim_create_buf(false, true)
	vim.bo[bufnr].buftype = "nofile"
	vim.bo[bufnr].bufhidden = "hide"
	vim.bo[bufnr].swapfile = false
	minted = minted + 1
	vim.api.nvim_buf_set_name(bufnr, ("neogrip://result/%d"):format(minted))
	-- The filetype is set after the name so a user FileType autocommand
	-- sees the finished buffer.
	vim.bo[bufnr].filetype = M.FILETYPE
	return bufnr
end

--- The window the tabs live in, whichever one of them it is showing.
function grid_window()
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
			return
		end
	end
	tabs[#tabs + 1] = bufnr
	active = #tabs
end

--- Open a tab for a query that has not answered yet (ADR-0044).
---
--- The window appears now and the rows arrive into this same buffer later. The
--- caller has to mint the result's name before the request leaves, because the
--- runner can answer synchronously - a dead process does - and there would
--- otherwise be no tab for the answer to land in.
--- `into` reuses a tab instead of opening one, which is what a sort does: the
--- rows already on screen stay readable while the new order is fetched, and the
--- clock runs over them.
--- @param opts table { into, hash, connection, origin_buf, statement, label, focus }
--- @return integer bufnr
function M.open_pending(opts)
	local bufnr = opts.into
	if not (bufnr and vim.api.nvim_buf_is_valid(bufnr)) then
		bufnr = new_tab_buffer()
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
	M.refresh_winbar(bufnr)
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
--- Reaches a tab waiting for its first answer and one whose refill is running,
--- which is why the clock is keyed by buffer rather than kept on either.
function M.progress(bufnr, event)
	if not event or not (waiting[bufnr] or states[bufnr]) then
		return
	end
	if waiting[bufnr] then
		waiting[bufnr].phase = event.phase
	end
	if event.phase == "executing" then
		-- Restarted rather than kept, because a refill is another execution of
		-- the same statement and its own wait.
		clocks[bufnr] = vim.uv.hrtime()
	end
	sync_ticker()
	M.refresh_winbar(bufnr)
end

--- The query failed, was refused or was cancelled. The tab stays and says so:
--- the window is already open, and one that vanishes leaves the reader with
--- nothing to look at and a renumbered strip (ADR-0044).
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
	-- A tab that was reused - a sort whose re-run failed - still holds the rows
	-- the reader was looking at, and they are not what went wrong. The winbar
	-- carries the word; only an empty tab gets the message as its body.
	if not states[bufnr] then
		local message = err and err.message or "the statement did not run"
		vim.bo[bufnr].modifiable = true
		vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, vim.split(message, "\n", { plain = true }))
		vim.bo[bufnr].modifiable = false
	end
	M.refresh_winbar(bufnr)
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
		bufnr = new_tab_buffer()
	end

	local pending_entry = waiting[bufnr]
	waiting[bufnr] = nil
	clocks[bufnr] = nil
	sync_ticker()
	-- Reusing a tab - which is what a sort does - replaces what it held.
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

--- Forget a tab: hand its result back and drop every trace of it.
---
--- Idempotent because it is reached twice for one close - directly, and again
--- through BufDelete once the buffer is gone.
function forget(bufnr)
	if not bufnr then
		return
	end
	local state = states[bufnr]
	-- Hand the result back. Nothing evicts an open one any more (ADR-0041),
	-- so a closed grid would otherwise hold a statement on the server until
	-- the idle sweep reached it an hour later.
	local result = state and state.result
	if result and result.hash and result.connection then
		require("neogrip.runner").release(result.connection, result.hash)
	end
	-- A tab dismissed before it answered takes its request with it: leaving the
	-- statement running would cost the reader a cursor they just closed.
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
				-- Every tab after the one that went shifted down by one.
				active = active - 1
			elseif active == index then
				-- The window was showing it: the next tab takes its place, or
				-- the one before it when the last tab went.
				active = math.min(index, #tabs)
			end
			break
		end
	end
	if #tabs == 0 then
		active = 0
	end
end

--- Show the tab at this index. Out of range is a no-op, so a mapping that
--- names a tab the reader does not have does nothing rather than erroring.
function M.goto_tab(index)
	local bufnr = tabs[index]
	if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
		return nil
	end
	active = index
	local winid = grid_window()
	if winid then
		vim.api.nvim_win_set_buf(winid, bufnr)
		M.refresh_winbar(bufnr)
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
	-- The window is handed its next tab before the buffer goes, so closing one
	-- of several leaves the window in place showing a neighbour; only the last
	-- tab lets the window go with it.
	local winid = find_window(bufnr)
	forget(bufnr)
	local neighbour = tabs[active]
	if winid and neighbour and vim.api.nvim_buf_is_valid(neighbour) then
		pcall(vim.api.nvim_win_set_buf, winid, neighbour)
		M.refresh_winbar(neighbour)
	end
	if vim.api.nvim_buf_is_valid(bufnr) then
		pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
	end
end

--- Replace the whole result in place, for a re-run: a different sort, or the
--- same statement asked again. The rows already fetched belong to the result
--- that is being replaced, so they go with it, and so do its fetch guards.
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
	-- A different result, so nothing drawn for the last one can be reused.
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

--- Append a batch continued from the open cursor (ADR-0040, ADR-0031).
---
--- The rows accumulate: this never replaces what is on screen, and it never
--- moves the cursor, because the batch it is appending is usually one the
--- reader did not ask for by hand. The shape only arrives again when a document
--- result grew its own columns, which is the one case where a later batch can
--- widen the table.
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
	-- A batch that brought nothing is not a place in the result, so it is not
	-- recorded as one; the caller decides whether that means the end.
	if #rows > 0 then
		state.batches[#state.batches + 1] = { first = first, last = #state.rows }
	end
	-- Kept index-aligned with state.rows even though the runner does not carry
	-- documents yet (ADR-0040): the day it does, accumulation is already right,
	-- and a batch that brings none leaves holes that show_document reads as "no
	-- document behind this row", which is what they are.
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
	-- The refill, if there was one, is over.
	clocks[bufnr] = nil
	sync_ticker()
	state.result.done = batch.done
	-- The query's own time is kept, not replaced by this batch's. A batch is a
	-- continuation of the same cursor and usually costs a few milliseconds, so
	-- overwriting turned "this statement took 1420 ms" into "3 ms" the moment
	-- the reader scrolled - and the statement's cost is what the number is for.
	state.last_batch_ms = batch.elapsed_ms
	local moved = render(bufnr)
	-- The cursor stays on the row it was on. When the table moved sideways its
	-- byte column now addresses another cell, so it is put back on the cell it
	-- was in rather than left where the bytes fell.
	if moved then
		local winid = find_window(bufnr)
		if winid then
			M.focus_cell(bufnr, winid)
		end
	end
	return #rows
end

--- Jump to where a batch began. Nothing is fetched and nothing is redrawn: the
--- rows are all on screen already, so this moves the cursor and no more.
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
	-- Four digits minimum, so the table does not shift sideways while it is
	-- being read: the width came straight from the row count, which re-widthed
	-- the whole gutter at row 100 and again at 1000, and rows accumulate now
	-- (ADR-0040), so that is twice in one scroll instead of once per result. A
	-- result worth scrolling reaches four digits anyway.
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
