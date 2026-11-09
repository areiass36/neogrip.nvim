-- From a command to a result: pick the statement, resolve the connection,
-- refuse what must be refused, page it, run it, show it.
--
-- There are no confirmations here (ADR-0016): readonly refuses mechanically,
-- production is a statusline signal, and the strongest protection is a
-- read-only database user.
local classify = require("neogrip.sql.classify")
local config = require("neogrip.config")
local neogrip = require("neogrip")
local diagnostics = require("neogrip.diagnostics")
local protocol = require("neogrip.rpc.protocol")
local grid = require("neogrip.grid")
local resolve = require("neogrip.resolve")
local runner = require("neogrip.runner")
local split = require("neogrip.sql.split")

local M = {}

local in_flight = {}

--- Flash the statement that is about to run. Seeing the range is the cheapest
--- protection against a splitter mistake sending more than you meant.
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

--- The one mechanical refusal: a write against a connection that says it is
--- read-only never runs. Gripd refuses as well, because the Lua
--- classifier can be wrong about an exotic statement.
--- @return boolean refused
local function refused(connection, sql)
	local kind = classify.kind(sql)
	local writes = kind == "dml" or kind == "ddl" or kind == "call"
	if writes and connection.readonly then
		neogrip.notify(
			("%s is read-only; this %s was not run"):format(connection.name, kind),
			vim.log.levels.ERROR
		)
		return true
	end
	return false
end

--- Prepare one statement and run it, showing the grid when `show` is set.
--- Pulled out of M.run so a multi-statement selection can drive it once per
--- statement in sequence.
--- @param p table { bufnr, connection, statement, limit, order_by, descending, focus, show, label, on_done }
local function execute_statement(p)
	local bufnr, connection = p.bufnr, p.connection
	-- No driver wants the terminator, and Trino refuses a statement that
	-- carries one. A statement from the splitter never has it; one typed at
	-- :NGripRun can.
	local sql = vim.trim((p.statement.text:gsub(";%s*$", "")))
	-- The statement as the user wrote it, kept aside before anything is
	-- wrapped around it below. `rerun` sends this back through here with the
	-- sort it is re-applying, so it has to be the unwrapped text: a statement
	-- that arrived already wrapped would be wrapped again on every page step
	-- and every change of sort, each layer reusing the same alias.
	local base_sql = sql

	if p.order_by then
		-- Sorting is the server's job so it covers every page, not just the
		-- rows already fetched. Quoting is the schema layer's job once it is
		-- ported; doubled quotes cover the engines in play until then.
		local quoted = '"' .. tostring(p.order_by):gsub('"', '""') .. '"'
		local schema_ok, schema = pcall(require, "neogrip.schema")
		if schema_ok then
			quoted = schema.quote(connection.driver, p.order_by)
		end
		sql = ("SELECT * FROM (%s) AS _neogrip_s ORDER BY %s %s"):format(
			sql,
			quoted,
			p.descending and "DESC" or "ASC"
		)
	end

	-- No LIMIT is spliced into the statement: the driver caps the rows
	-- (setMaxRows) and the result stays open as a cursor, which works the same
	-- whatever the dialect spells it (ADR-0014, ADR-0031).
	-- Minted here rather than left to the runner, because the tab has to exist
	-- before the request leaves and the tab is addressed by this name. The
	-- runner answers synchronously when the process is gone, so opening the tab
	-- afterwards would open it after the answer had already been handled.
	local hash = runner.hash()
	local tab = nil
	if p.show then
		tab = grid.open_pending({
			-- A sort hands back the tab it is re-ordering, so the rows already
			-- on screen stay readable while the new order is fetched.
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
			-- The tab keeps the window it opened and says what happened. The
			-- message has already been through errors.from_rpc, which is what
			-- keeps a driver's text - and any secret in it - out of a buffer.
			if tab then
				grid.fail(tab, err)
			end
			if err.cancelled then
				return neogrip.notify("cancelled")
			end
			neogrip.notify((p.label and p.label .. ": " or "") .. err.message, vim.log.levels.ERROR)
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

--- Run several statements against one connection one after another. The driver
--- takes a single statement per call - Trino rejects even two separated by a
--- ';' with "mismatched input ';'" - so a selection that holds more than one is
--- a sequence, exactly as a SQL console runs it: each in turn, stopping at the
--- first error, and each one in its own tab.
---
--- That last part supersedes ADR-0030's clause that only the last statement's
--- rows reach the grid, and the notification that summarised the others goes
--- with it: a tab says everything that line said and stays put (ADR-0044).
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
			-- Every statement gets a tab; only the last one takes the window,
			-- so the cursor does not jump once per statement.
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

	-- A buffer that is only comments has no statement to run; sending it would
	-- make the server answer with its own "no statements" error, which reads
	-- as a failure rather than as "there was nothing here".
	if not statement or classify.strip_leading_comments(statement.text) == "" then
		neogrip.notify("no statement under the cursor", vim.log.levels.WARN)
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

	-- A selection can hold several statements; one from the cursor or from a
	-- rerun (sorting) is always a single one. Splitting here is cheap and
	-- leaves the single case untouched, since a lone statement splits into one
	-- part. More than one is run as a sequence. The guards keep a rerun - which
	-- carries its own single base_sql - on the single path no matter what.
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
		neogrip.notify("nothing is running")
		return
	end
	for _, running in ipairs(active) do
		runner.cancel(running)
	end
end

--- Re-run the grid's statement, which is how a different sort is applied: the
--- order has to be the server's to cover every page, so it opens a new result.
local function rerun(state, changes)
	local result = state.result
	M.run(vim.tbl_extend("force", {
		bufnr = state.origin_buf or vim.api.nvim_get_current_buf(),
		statement = { text = result.base_sql or result.sql, start_line = nil },
		limit = result.limit,
		order_by = result.order_by,
		descending = result.descending,
		focus = false,
		-- The same rows in another order is the same query to the reader, so it
		-- replaces this tab instead of opening one per sort click (ADR-0044).
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
---
--- The one fetch path: `]p` and the cursor nearing the last row both arrive
--- here, so the guards that stop a motion-driven trigger from queueing one
--- request per motion live in a single place rather than at each caller.
---
--- `loading` is what the queue cannot do for us: the runner serializes per
--- connection, but `result.done` is only true once an answer lands, so without
--- this every motion would pass the same check and enqueue again.
--- @param opts table|nil { quiet, track, on_done = fun(appended: integer) }
--- @return boolean asked whether a request actually went out
function M.load_more(state, opts)
	opts = opts or {}
	-- state.bufnr is always set by show, and with tabs a fallback to whichever
	-- tab is active could address a different one than this state belongs to.
	local bufnr = state and state.bufnr
	if not bufnr then
		return false
	end
	state.auto = state.auto or {}
	local auto = state.auto
	local result = state.result

	local function refuse(message, level)
		if not opts.quiet then
			neogrip.notify(message, level)
		end
		return false
	end

	if auto.loading then
		return false
	end
	-- Said again on the manual path and stayed quiet about on the automatic
	-- one, which is the whole difference between the two: a reader who presses
	-- the key is owed an answer, and one who is scrolling is not owed it on
	-- every motion.
	if state.expired then
		return refuse("the result expired; run the statement again for more rows", vim.log.levels.ERROR)
	end
	if auto.exhausted or result.done ~= false or not result.hash then
		return refuse("no further rows")
	end

	auto.loading = true
	-- So the footer says so. A render that reuses its lines rewrites the footer
	-- line and nothing else, so this costs a width measurement.
	grid.refresh(bufnr)
	local handle = runner.run({
		connection = result.connection,
		hash = result.hash,
		mode = "next",
		limit = result.limit or config.get().limit,
		-- A continuation that drains the window makes gripd re-execute the
		-- statement, which announces itself like any other execution (ADR-0042).
		-- That is the slowest wait there is - ADR-0031 measured 226s on a Trino
		-- refill - so it is the one that most needs a clock.
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
			-- The result is gone from the server: evicted, swept for being
			-- idle, or cancelled. Matched on the code because the message is a
			-- Java string literal with its own opposite three words away, and
			-- doc/protocol.md pins the code. The code is a general refusal
			-- there, but the registry's is the only one reachable from a
			-- continuation, which is why this lives here and not in errors.lua.
			if err.rpc_code == protocol.ERRORS.invalid_request then
				state.expired = true
				auto.exhausted = true
				grid.refresh(bufnr)
				-- Said even when quiet: nothing is re-run (ADR-0040), so the
				-- reader has to be told why the rows stopped coming. Once,
				-- which the latch above gives for free.
				neogrip.notify(
					"the result expired; the rows loaded are still here - "
						.. "run the statement again for more",
					vim.log.levels.ERROR
				)
				return
			end
			return refuse(err.message, vim.log.levels.ERROR)
		end
		local appended = grid.add_page(bufnr, batch)
		-- A batch that claims there is more and brings nothing would be asked
		-- for again on the next motion, forever. No server does that today;
		-- the latch is what keeps it a bug rather than a loop.
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
	-- Only the manual path is cancellable. `in_flight` is keyed by the query
	-- buffer and read by M.cancel, so tracking an automatic continuation would
	-- let :NGripCancel in the SQL file send `cancel {hash}` and destroy the
	-- cursor the reader is scrolling through.
	if opts.track then
		in_flight[state.origin_buf or bufnr] = handle
	end
	return true
end

--- Move a batch. Backwards is a cursor jump and forwards usually is too: the
--- rows are all on screen already (ADR-0040), and past the last batch it is
--- the next batch of the cursor gripd still holds (ADR-0031). Nothing re-runs
--- the statement, so no boundary can show a changed world.
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
		return neogrip.notify("already on the first page")
	end
	if (state.batches or {})[target] then
		return grid.goto_page(bufnr, target)
	end
	if delta < 0 then
		return neogrip.notify("already on the first page")
	end

	M.load_more(state, {
		track = true,
		on_done = function(appended)
			-- Asked for by hand, so the cursor goes to what arrived.
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
