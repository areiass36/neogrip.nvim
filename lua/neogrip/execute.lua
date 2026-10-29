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

--- @param opts table|nil { bufnr, statement, visual, limit, offset, order_by, descending, on_done }
function M.run(opts)
	opts = opts or {}
	local bufnr = opts.bufnr or vim.api.nvim_get_current_buf()
	local statement = opts.statement or (opts.visual and split.selection(bufnr)) or split.at_cursor(bufnr)

	if not statement or vim.trim(statement.text) == "" then
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

	if refused(connection, statement.text) then
		return
	end

	local settings = config.get()
	local limit = opts.limit or connection.limit or settings.limit
	local offset = opts.offset or 0
	-- No driver wants the terminator, and Trino refuses a statement that
	-- carries one. A statement from the splitter never has it; one typed at
	-- :NGripRun can.
	local sql = vim.trim((statement.text:gsub(";%s*$", "")))
	-- The statement as the user wrote it, kept aside before anything is
	-- wrapped around it below. `rerun` sends this back through here with the
	-- sort it is re-applying, so it has to be the unwrapped text: a statement
	-- that arrived already wrapped would be wrapped again on every page step
	-- and every change of sort, each layer reusing the same alias.
	local base_sql = sql

	if opts.order_by then
		-- Sorting is the server's job so it covers every page, not just the
		-- rows already fetched. Quoting is the schema layer's job once it is
		-- ported; doubled quotes cover the engines in play until then.
		local quoted = '"' .. tostring(opts.order_by):gsub('"', '""') .. '"'
		local schema_ok, schema = pcall(require, "neogrip.schema")
		if schema_ok then
			quoted = schema.quote(connection.driver, opts.order_by)
		end
		sql = ("SELECT * FROM (%s) AS _neogrip_s ORDER BY %s %s"):format(
			sql,
			quoted,
			opts.descending and "DESC" or "ASC"
		)
	end

	-- No LIMIT is spliced into the statement: the driver caps the rows
	-- (setMaxRows) and the runner skips the offset, which works the same
	-- whatever the dialect spells it (ADR-0014).
	local handle
	handle = runner.run({
		connection = connection,
		sql = sql,
		mode = "query",
		limit = limit,
		offset = offset,
	}, function(result, err)
		in_flight[bufnr] = nil
		if err then
			if err.cancelled then
				return neogrip.notify("cancelled")
			end
			neogrip.notify(err.message, vim.log.levels.ERROR)
			diagnostics.from_error(bufnr, statement, err)
			return
		end
		diagnostics.clear(bufnr)
		result.base_sql = base_sql
		result.order_by = opts.order_by
		result.descending = opts.descending
		grid.show(result, { origin_buf = bufnr, statement = statement, focus = opts.focus })
		if opts.on_done then
			opts.on_done(result)
		end
	end)
	in_flight[bufnr] = handle
	start_progress(connection, handle)
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

--- Re-run the grid's statement with a different page or order.
local function rerun(state, changes)
	local result = state.result
	M.run(vim.tbl_extend("force", {
		bufnr = state.origin_buf or vim.api.nvim_get_current_buf(),
		statement = { text = result.base_sql or result.sql, start_line = nil },
		limit = result.limit,
		offset = result.offset or 0,
		order_by = result.order_by,
		descending = result.descending,
		focus = false,
	}, changes))
end

function M.page(state, delta)
	local result = state.result
	local limit = result.limit or config.get().limit
	local offset = (result.offset or 0) + delta * limit
	if offset < 0 then
		return neogrip.notify("already on the first page")
	end
	if delta > 0 and not result.has_more then
		return neogrip.notify("no further rows")
	end
	rerun(state, { offset = offset })
end

function M.sort(state, column, descending)
	rerun(state, { order_by = column, descending = descending, offset = 0 })
end

return M
