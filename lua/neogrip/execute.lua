local classify = require("neogrip.sql.classify")
local config = require("neogrip.config")
local notify = require("neogrip.notify")
local diagnostics = require("neogrip.diagnostics")
local protocol = require("neogrip.gripd.protocol")
local grid = require("neogrip.grid")
local resolve = require("neogrip.connections.resolve")
local runner = require("neogrip.gripd.runner")
local split = require("neogrip.sql.split")

local M = {}

local in_flight = {}

--- Flash the range about to run, so a splitter mistake is visible before it executes.
local function flash(bufnr, statement)
	if not statement.start_line then
		return
	end
	pcall(
		vim.hl.range,
		bufnr,
		vim.api.nvim_create_namespace("neogrip_flash"),
		"IncSearch",
		{ statement.start_line - 1, 0 },
		{ statement.end_line - 1, -1 },
		{ timeout = 150 }
	)
end

--- Refuse a write against a read-only connection; gripd refuses as well, since
--- the Lua classifier can be wrong about an exotic statement.
--- @return boolean refused
local function refused(connection, sql)
	local kind = classify.kind(sql)
	local writes = kind == "dml" or kind == "ddl" or kind == "call"
	if writes and connection.readonly then
		notify.send(
			("%s is read-only; this %s was not run"):format(connection.name, kind),
			vim.log.levels.ERROR
		)
		return true
	end
	return false
end

--- Prepare one statement and run it, showing the grid when `show` is set.
--- @param p table { bufnr, connection, statement, limit, order_by, descending, focus, show, label, on_done }
local function execute_statement(p)
	local bufnr, connection = p.bufnr, p.connection
	-- Trino refuses a trailing terminator; see doc/internals.md#runner-and-execute.
	local sql = vim.trim((p.statement.text:gsub(";%s*$", "")))
	-- Kept unwrapped: `rerun` sends this text back through here, and a statement
	-- that arrived already wrapped would be wrapped again on every sort or page step.
	local base_sql = sql

	if p.order_by then
		-- Sorted server-side so the order covers every page, not just the rows fetched.
		local quoted = '"' .. tostring(p.order_by):gsub('"', '""') .. '"'
		local schema_ok, schema = pcall(require, "neogrip.catalog")
		if schema_ok then
			quoted = schema.quote(connection.driver, p.order_by)
		end
		sql = ("SELECT * FROM (%s) AS _neogrip_s ORDER BY %s %s"):format(
			sql,
			quoted,
			p.descending and "DESC" or "ASC"
		)
	end

	-- No LIMIT is spliced in: the driver caps the rows and the result stays an
	-- open cursor (ADR-0014, ADR-0031).
	-- Minted before the request leaves because the runner can answer
	-- synchronously, and the tab addressed by this name must exist by then.
	local hash = runner.hash()
	local tab = nil
	if p.show then
		tab = grid.open_pending({
			-- A sort reuses the tab it re-orders, keeping the rows on screen meanwhile.
			into = p.into,
			hash = hash,
			connection = connection,
			origin_buf = bufnr,
			statement = p.statement,
			label = p.label,
			focus = false,
		})
	end

	local handle
	handle = runner.run({
		connection = connection,
		sql = sql,
		mode = "query",
		limit = p.limit,
		hash = hash,
		on_progress = tab and function(event)
			grid.progress(tab, event)
		end or nil,
	}, function(result, err)
		in_flight[bufnr] = nil
		if err then
			-- The message has been through errors.from_rpc, which keeps any
			-- secret in a driver's text out of a buffer.
			if tab then
				grid.fail(tab, err)
			end
			if err.cancelled then
				return notify.send("cancelled")
			end
			notify.send((p.label and p.label .. ": " or "") .. err.message, vim.log.levels.ERROR)
			diagnostics.from_error(bufnr, p.statement, err)
			return
		end
		diagnostics.clear(bufnr)
		if p.show then
			result.base_sql = base_sql
			result.order_by = p.order_by
			result.descending = p.descending
			grid.show(result, {
				into = tab,
				origin_buf = bufnr,
				statement = p.statement,
				focus = p.focus,
			})
		end
		if p.on_done then
			p.on_done(result)
		end
	end)
	in_flight[bufnr] = handle
	if tab then
		grid.attach_handle(tab, handle)
	end
end

--- Run statements in sequence, one tab each, stopping at the first error: the
--- driver takes one statement per call (see doc/internals.md#runner-and-execute),
--- and the tabs supersede ADR-0030's last-only clause (ADR-0044).
local function run_sequence(bufnr, connection, outer, parts, opts)
	local total = #parts
	local function step(index)
		local part = parts[index]
		local label = ("statement %d/%d"):format(index, total)
		if refused(connection, part.text) then
			return
		end
		local last = index == total
		execute_statement({
			bufnr = bufnr,
			connection = connection,
			statement = {
				text = part.text,
				start_line = outer.start_line,
				end_line = outer.end_line,
			},
			limit = opts.limit,
			-- Only the last statement takes the window, so the cursor jumps once.
			focus = last and opts.focus or false,
			show = true,
			label = label,
			on_done = function(result)
				if last then
					if opts.on_done then
						opts.on_done(result)
					end
				else
					step(index + 1)
				end
			end,
		})
	end
	step(1)
end

--- @param opts table|nil { bufnr, statement, visual, limit, order_by, descending, on_done }
function M.run(opts)
	opts = opts or {}
	local bufnr = opts.bufnr or vim.api.nvim_get_current_buf()
	local statement = opts.statement or (opts.visual and split.selection(bufnr)) or split.at_cursor(bufnr)

	-- Comment-only text would make the server answer with its own "no
	-- statements" error, which reads as a failure.
	if not statement or classify.strip_leading_comments(statement.text) == "" then
		notify.send("no statement under the cursor", vim.log.levels.WARN)
		return
	end

	local connection, _ = resolve.for_buf(bufnr)
	if not connection then
		return resolve.pick(bufnr, function()
			M.run(opts)
		end)
	end

	flash(bufnr, statement)

	local settings = config.get()
	local limit = opts.limit or connection.limit or settings.limit

	-- The guards keep a rerun, which carries its own single base_sql, on the
	-- single path no matter what.
	local parts = split.statements(statement.text, vim.b[bufnr].neogrip_dialect)
	if #parts > 1 and not opts.statement and not opts.order_by then
		return run_sequence(bufnr, connection, statement, parts, {
			limit = limit,
			focus = opts.focus,
			on_done = opts.on_done,
		})
	end

	if refused(connection, statement.text) then
		return
	end

	execute_statement({
		bufnr = bufnr,
		connection = connection,
		statement = statement,
		limit = limit,
		order_by = opts.order_by,
		descending = opts.descending,
		focus = opts.focus,
		show = true,
		into = opts.into,
		on_done = opts.on_done,
	})
end

function M.cancel(bufnr)
	bufnr = bufnr or vim.api.nvim_get_current_buf()
	local handle = in_flight[bufnr]
	if handle then
		runner.cancel(handle)
		return
	end
	local active = runner.active()
	if #active == 0 then
		notify.send("nothing is running")
		return
	end
	for _, running in ipairs(active) do
		runner.cancel(running)
	end
end

--- Re-run the grid's statement with a different server-side sort.
local function rerun(state, changes)
	local result = state.result
	M.run(vim.tbl_extend("force", {
		bufnr = state.origin_buf or vim.api.nvim_get_current_buf(),
		statement = { text = result.base_sql or result.sql, start_line = nil },
		limit = result.limit,
		order_by = result.order_by,
		descending = result.descending,
		focus = false,
		-- A re-sort replaces the tab instead of opening one per click (ADR-0044).
		into = state.bufnr,
	}, changes))
end

--- Which batch the cursor is sitting in, 1-based.
local function current_batch(state)
	local batches = state.batches or {}
	for index, batch in ipairs(batches) do
		if state.row >= batch.first and state.row <= batch.last then
			return index
		end
	end
	return math.max(#batches, 1)
end

--- Fetch the next batch of the open result and append it (ADR-0040).
--- `loading` latches because `result.done` only updates once an answer lands;
--- without it every cursor motion would enqueue another request.
--- @param opts table|nil { quiet, track, on_done = fun(appended: integer) }
--- @return boolean asked whether a request actually went out
function M.load_more(state, opts)
	opts = opts or {}
	-- A fallback to the active tab could address a different one than this state's.
	local bufnr = state and state.bufnr
	if not bufnr then
		return false
	end
	state.auto = state.auto or {}
	local auto = state.auto
	local result = state.result

	local function refuse(message, level)
		if not opts.quiet then
			notify.send(message, level)
		end
		return false
	end

	if auto.loading then
		return false
	end
	-- A reader who pressed the key is owed an answer; one who is scrolling is not.
	if state.expired then
		return refuse("the result expired; run the statement again for more rows", vim.log.levels.ERROR)
	end
	if auto.exhausted or result.done ~= false or not result.hash then
		return refuse("no further rows")
	end

	auto.loading = true
	-- So the footer says so; a reusing render rewrites only the footer line.
	grid.refresh(bufnr)
	local handle = runner.run({
		connection = result.connection,
		hash = result.hash,
		mode = "next",
		limit = result.limit or config.get().limit,
		-- A continuation that drains the window re-executes the statement
		-- (ADR-0042), the wait that most needs a clock; see
		-- doc/internals.md#runner-and-execute.
		on_progress = function(event)
			grid.progress(bufnr, event)
		end,
	}, function(batch, err)
		auto.loading = false
		if opts.track then
			in_flight[state.origin_buf or bufnr] = nil
		end
		if err then
			if err.cancelled then
				return refuse("cancelled")
			end
			-- The result is gone from the server. Matched on the code, which
			-- doc/protocol.md pins; the registry's refusal is the only one
			-- reachable from a continuation.
			if err.rpc_code == protocol.ERRORS.invalid_request then
				state.expired = true
				auto.exhausted = true
				grid.refresh(bufnr)
				-- Said even when quiet: nothing is re-run (ADR-0040), so the
				-- reader must be told why the rows stopped.
				notify.send(
					"the result expired; the rows loaded are still here - "
						.. "run the statement again for more",
					vim.log.levels.ERROR
				)
				return
			end
			return refuse(err.message, vim.log.levels.ERROR)
		end
		local appended = grid.add_page(bufnr, batch)
		-- An empty batch claiming more rows would otherwise be requested again
		-- on every motion, forever.
		if appended == 0 and batch.done == false then
			auto.exhausted = true
		end
		if batch.done ~= false then
			auto.exhausted = true
		end
		if opts.on_done then
			opts.on_done(appended)
		end
	end)
	-- Only the manual path is cancellable: tracking an automatic continuation
	-- would let :NGripCancel destroy the cursor the reader is scrolling through.
	if opts.track then
		in_flight[state.origin_buf or bufnr] = handle
	end
	return true
end

--- Move a batch: a cursor jump within loaded rows (ADR-0040), or past the last
--- batch the next page of the cursor gripd still holds (ADR-0031).
function M.page(state, delta)
	if not state then
		return
	end
	local bufnr = state.bufnr
	if not bufnr then
		return
	end

	local target = current_batch(state) + delta
	if target < 1 then
		return notify.send("already on the first page")
	end
	if (state.batches or {})[target] then
		return grid.goto_page(bufnr, target)
	end
	if delta < 0 then
		return notify.send("already on the first page")
	end

	M.load_more(state, {
		track = true,
		on_done = function(appended)
			if appended > 0 then
				grid.goto_page(bufnr, #state.batches)
			end
		end,
	})
end

function M.sort(state, column, descending)
	rerun(state, { order_by = column, descending = descending })
end

return M
