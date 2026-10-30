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

--- Say something only if the query is still running two seconds in. Tied to
--- the handle, not to "is anything running": another connection's query
--- finishing is not news about this one.
local function start_progress(connection, handle)
	vim.defer_fn(function()
		if not handle.done then
			neogrip.notify(("running on %s... (:NGripCancel cancels)"):format(connection.name))
		end
	end, 2000)
end

--- The one mechanical refusal: a write against a connection that says it is
--- read-only never runs. The sidecar refuses as well, because the Lua
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
	local handle
	handle = runner.run({
		connection = connection,
		sql = sql,
		mode = "query",
		limit = p.limit,
	}, function(result, err)
		in_flight[bufnr] = nil
		if err then
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
			-- The grid is about to hold a different result, and the one it held
			-- is not coming back: the sidecar can let that cursor go now rather
			-- than wait for its idle sweep (ADR-0031).
			local previous_buf = grid.current_buf()
			local previous = previous_buf and grid.state(previous_buf)
			local stale = previous and previous.result and previous.result.hash
			if stale and stale ~= result.hash then
				runner.release(connection, stale)
			end
			grid.show(result, { origin_buf = bufnr, statement = p.statement, focus = p.focus })
		end
		if p.on_done then
			p.on_done(result)
		end
	end)
	in_flight[bufnr] = handle
	start_progress(connection, handle)
end

--- One line describing what a statement did, for the ones in a sequence whose
--- result does not reach the grid.
local function summarise(label, result)
	if result.rows_written then
		return ("%s: wrote %d rows"):format(label, result.rows_written)
	end
	if result.update_count and result.update_count >= 0 then
		return ("%s: %d rows affected"):format(label, result.update_count)
	end
	return ("%s: %d rows%s"):format(label, #(result.rows or {}), result.done == false and "+" or "")
end

--- Run several statements against one connection one after another. The driver
--- takes a single statement per call - Trino rejects even two separated by a
--- ';' with "mismatched input ';'" - so a selection that holds more than one is
--- a sequence, exactly as a SQL console runs it: each in turn, stopping at the
--- first error, with only the last one's rows shown in the grid.
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
			focus = last and opts.focus or false,
			show = last,
			label = label,
			on_done = function(result)
				if last then
					if opts.on_done then
						opts.on_done(result)
					end
				else
					neogrip.notify(summarise(label, result))
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
	}, changes))
end

--- Move a page. Backwards is always a redraw and forwards usually is too: a
--- page already fetched never left the editor, and the one after it is the next
--- batch of the cursor the sidecar still holds (ADR-0031). Nothing re-runs the
--- statement, so no page boundary can show a changed world.
function M.page(state, delta)
	if not state then
		return
	end
	local bufnr = state.bufnr or grid.current_buf()
	if not bufnr then
		return
	end

	local target = (state.page or 1) + delta
	if target < 1 then
		return neogrip.notify("already on the first page")
	end
	if state.pages[target] then
		return grid.goto_page(bufnr, target)
	end
	if delta < 0 then
		return neogrip.notify("already on the first page")
	end

	local result = state.result
	if result.done ~= false or not result.hash then
		return neogrip.notify("no further rows")
	end

	local handle = runner.run({
		connection = result.connection,
		hash = result.hash,
		mode = "next",
		limit = result.limit or config.get().limit,
	}, function(batch, err)
		in_flight[state.origin_buf or bufnr] = nil
		if err then
			if err.cancelled then
				return neogrip.notify("cancelled")
			end
			return neogrip.notify(err.message, vim.log.levels.ERROR)
		end
		grid.add_page(bufnr, batch)
	end)
	in_flight[state.origin_buf or bufnr] = handle
end

function M.sort(state, column, descending)
	rerun(state, { order_by = column, descending = descending })
end

return M
