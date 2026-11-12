-- The result window: one tab per query (ADR-0044), opened before the answer and
-- forgotten when it closes. What each tab holds lives in grid/registry.lua; this is
-- the lifecycle and the facade the rest of the plugin calls.
local cursor = require("neogrip.grid.cursor")
local notify = require("neogrip.notify")
local pages = require("neogrip.grid.pages")
local registry = require("neogrip.grid.registry")
local render = require("neogrip.grid.render")
local status = require("neogrip.grid.status")
local strip = require("neogrip.grid.strip")
local value_module = require("neogrip.codec.value")

local M = {}

M.FILETYPE = "neogrip-grid"

--- A fresh scratch buffer for one tab, unlisted: the strip names the tabs (ADR-0045).
local function new_tab_buffer(label)
	local bufnr = vim.api.nvim_create_buf(false, true)
	vim.bo[bufnr].buftype = "nofile"
	vim.bo[bufnr].bufhidden = "hide"
	vim.bo[bufnr].swapfile = false
	-- The counter keeps the name unique; the label sits after the last '/' so
	-- the tail of the name is the statement, not the counter.
	vim.api.nvim_buf_set_name(bufnr, ("neogrip://%d/%s"):format(registry.mint(), registry.label_of(label)))
	-- Set after the name so a user FileType autocommand sees the finished buffer.
	vim.bo[bufnr].filetype = M.FILETYPE
	return bufnr
end

--- Open the result window if it is not open, and show this tab in it.
local function open_window(bufnr)
	local winid = registry.window()
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

--- Show this tab in the window and mark it in the strip.
local function activate(bufnr)
	registry.activate(bufnr)
	strip.paint()
end

--- Forget a tab: hand its result back and drop every trace of it. Idempotent:
--- one close reaches it directly and again through the buffer autocommands.
local function forget(bufnr)
	if not bufnr then
		return
	end
	local state = registry.states[bufnr]
	-- Nothing evicts an open result any more (ADR-0041), so a closed grid would
	-- otherwise hold its cursor until the idle sweep an hour later.
	local result = state and state.result
	if result and result.hash and result.connection then
		require("neogrip.gripd.runner").release(result.connection, result.hash)
	end
	-- A tab dismissed before it answered takes its request with it.
	local entry = registry.waiting[bufnr]
	if entry and entry.handle then
		require("neogrip.gripd.runner").cancel(entry.handle)
	end
	registry.waiting[bufnr] = nil
	registry.states[bufnr] = nil
	registry.clocks[bufnr] = nil
	status.sync_clock()
	cursor.cancel_load(bufnr)
	registry.remove(bufnr)
	strip.paint()
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
			cursor.sync_from_cursor(bufnr)
			cursor.maybe_load_more(bufnr)
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

--- @class neogrip.grid.Source what a tab asks for rows it does not hold yet
--- @field load_more fun(state: table, opts: table|nil): boolean
--- @field page fun(state: table, delta: integer)
--- @field sort fun(state: table, column: string, descending: boolean)

--- Open a tab for a query that has not answered yet (ADR-0044); the tab must
--- exist before the request leaves because the runner can answer synchronously.
--- `into` reuses a tab instead of opening one, which is what a sort does.
--- @param opts table { into, hash, connection, origin_buf, statement, label, focus, source }
--- @return integer bufnr
function M.open_pending(opts)
	local bufnr = opts.into
	if not (bufnr and vim.api.nvim_buf_is_valid(bufnr)) then
		bufnr = new_tab_buffer(opts.statement and opts.statement.text or opts.label)
	end
	registry.waiting[bufnr] = {
		hash = opts.hash,
		source = opts.source,
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
	status.paint_pending(bufnr)
	if opts.focus then
		vim.api.nvim_set_current_win(winid)
	end
	return bufnr
end

--- Whether a tab is still waiting for its answer.
function M.is_pending(bufnr)
	return registry.waiting[bufnr] ~= nil
end

--- Remember the handle, so closing the tab can cancel the request behind it.
function M.attach_handle(bufnr, handle)
	local entry = registry.waiting[bufnr]
	if entry then
		entry.handle = handle
	end
end

--- Where a pending query has got to: a phase from the runner, or gripd saying
--- the statement has begun executing (ADR-0042), which is what starts the clock.
function M.progress(bufnr, event)
	if not event or not (registry.waiting[bufnr] or registry.states[bufnr]) then
		return
	end
	if registry.waiting[bufnr] then
		registry.waiting[bufnr].phase = event.phase
	end
	if event.phase == "executing" then
		-- Restarted: a refill is another execution and its own wait.
		registry.clocks[bufnr] = vim.uv.hrtime()
	end
	status.sync_clock()
	status.refresh(bufnr)
	strip.paint()
end

--- The query failed, was refused or was cancelled; the tab stays and says so (ADR-0044).
--- @param err table the translated error - already redacted by errors.from_rpc,
---            because a raw driver message can carry a secret
function M.fail(bufnr, err)
	local entry = registry.waiting[bufnr]
	if not entry or not vim.api.nvim_buf_is_valid(bufnr) then
		return
	end
	registry.clocks[bufnr] = nil
	entry.failed = err and err.cancelled and "cancelled" or "failed"
	entry.handle = nil
	status.sync_clock()
	-- A reused tab - a sort whose re-run failed - keeps its rows; only an empty
	-- tab gets the message as its body.
	if not registry.states[bufnr] then
		local message = err and err.message or "the statement did not run"
		vim.bo[bufnr].modifiable = true
		vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, vim.split(message, "\n", { plain = true }))
		vim.bo[bufnr].modifiable = false
	end
	strip.paint()
end

--- Show a result, reusing the window that already holds one.
--- @param context table|nil { into, origin_buf, statement, focus, source }
--- @return integer bufnr
function M.show(result, context)
	context = context or {}
	local bufnr = context.into
	if not (bufnr and vim.api.nvim_buf_is_valid(bufnr)) then
		bufnr = registry.current_buf()
	end
	if not (bufnr and vim.api.nvim_buf_is_valid(bufnr)) then
		bufnr = new_tab_buffer(context.statement and context.statement.text)
	end

	local pending_entry = registry.waiting[bufnr]
	registry.waiting[bufnr] = nil
	registry.clocks[bufnr] = nil
	status.sync_clock()
	registry.release_replaced(registry.states[bufnr], result)

	local winid = open_window(bufnr)
	activate(bufnr)

	registry.states[bufnr] = {
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
		source = context.source or (pending_entry and pending_entry.source),
	}
	render.draw(bufnr)
	attach_cursor_sync(bufnr)

	if context.focus ~= false then
		vim.api.nvim_set_current_win(winid)
		cursor.focus_cell(bufnr, winid)
	end
	return bufnr
end

--- Every tab, oldest first. A copy: the list is the grid's own.
function M.tabs()
	return vim.list_extend({}, registry.tabs)
end

function M.refresh(bufnr)
	render.draw(bufnr or registry.current_buf())
end

--- Show the tab at this index; out of range is a no-op.
function M.goto_tab(index)
	local bufnr = registry.tabs[index]
	if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
		return nil
	end
	registry.set_active(index)
	local winid = registry.window()
	if winid then
		vim.api.nvim_win_set_buf(winid, bufnr)
		strip.paint()
		if registry.states[bufnr] then
			cursor.focus_cell(bufnr, winid)
		end
	end
	return bufnr
end

--- Step through the tabs, wrapping at each end.
function M.step_tab(delta)
	if #registry.tabs == 0 then
		return nil
	end
	return M.goto_tab((registry.active_index() - 1 + delta) % #registry.tabs + 1)
end

function M.close(bufnr)
	bufnr = bufnr or registry.current_buf()
	if not bufnr then
		return
	end
	-- The window is handed its next tab before the buffer goes; only the last
	-- tab lets the window go with it.
	local winid = registry.find_window(bufnr)
	forget(bufnr)
	local neighbour = registry.tabs[registry.active_index()]
	if winid and neighbour and vim.api.nvim_buf_is_valid(neighbour) then
		pcall(vim.api.nvim_win_set_buf, winid, neighbour)
		strip.paint()
	end
	if vim.api.nvim_buf_is_valid(bufnr) then
		pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
	end
end

--- The whole document behind a Mongo row; the float has no keymaps (ADR-0017).
function M.show_document(bufnr)
	local state = registry.states[bufnr]
	if not state or not state.documents then
		notify.send("no document behind this row", vim.log.levels.WARN)
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

--- The 'statuscolumn' entry point: reads the line and window being drawn.
function M.row_label()
	local winid = vim.g.statusline_winid
	local bufnr = winid and winid > 0 and vim.api.nvim_win_get_buf(winid) or vim.api.nvim_get_current_buf()
	return cursor.row_number_for(bufnr, vim.v.lnum)
end

-- The facade: one name per thing the rest of the plugin asks of the result window.
M.state = registry.state
M.current_buf = registry.current_buf
M.active_tab = registry.active_index
M.status_text = status.status_text
M.strip_text = strip.text
M._ticking = status.ticking
M.highlight_cell = cursor.highlight_cell
M.focus_cell = cursor.focus_cell
M.sync_from_cursor = cursor.sync_from_cursor
M.cell_value = cursor.cell_value
M.maybe_load_more = cursor.maybe_load_more
M.row_number_for = cursor.row_number_for
M.set_result = pages.set_result
M.add_page = pages.add_page
M.goto_page = pages.goto_page
M.display = value_module.display

return M
