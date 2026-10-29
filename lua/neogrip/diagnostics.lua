-- Checking a statement against the server without running it.
--
-- JDBC makes this simple in a way the command line clients never were:
-- preparing a statement sends the text to the server, which parses it,
-- resolves the names and describes the result - and executes nothing. No
-- PREPARE inside a rolled-back transaction, no EXPLAIN that has to be kept
-- away from ANALYZE, and no SQL Server special case where SET NOEXEC ON would
-- have run the statement for real.
--
-- PostgreSQL even reports the character position, so the mark lands on the
-- offending name rather than on the line.
local classify = require("neogrip.sql.classify")
local config = require("neogrip.config")
local neogrip = require("neogrip")
local errors = require("neogrip.errors")
local resolve = require("neogrip.resolve")
local runner = require("neogrip.runner")
local split = require("neogrip.sql.split")

local M = {}

local NAMESPACE = vim.api.nvim_create_namespace("neogrip_diagnostics")
local pending = {}

--- Statements that are not worth sending: a transaction or session command
--- has nothing to validate, and preparing one is not meaningful.
--- @return boolean checkable, string|nil reason
function M.checkable(sql)
	local kind = classify.kind(sql)
	if kind == "tx" or kind == "session" then
		return false, "transaction and session statements are not checked"
	end
	return true, nil
end

function M.clear(bufnr)
	vim.diagnostic.reset(NAMESPACE, bufnr)
end

--- Put a client error on the map.
function M.from_error(bufnr, statement, err)
	local line, from, to = errors.locate(err, statement, bufnr)
	local message = err.message or "error"
	if err.state or err.code then
		message = ("%s [%s]"):format(message, err.state or tostring(err.code))
	end
	vim.diagnostic.set(NAMESPACE, bufnr, {
		{
			lnum = line,
			col = from,
			end_lnum = line,
			end_col = to,
			severity = vim.diagnostic.severity.ERROR,
			source = "neogrip",
			message = message,
		},
	})
end

--- @param opts table|nil { bufnr, statement, notify }
function M.validate(opts)
	opts = opts or {}
	local bufnr = opts.bufnr or vim.api.nvim_get_current_buf()
	local statement = opts.statement or split.at_cursor(bufnr)
	if not statement then
		return
	end

	local connection = resolve.for_buf(bufnr)
	if not connection then
		if opts.notify then
			neogrip.notify("no connection for this buffer", vim.log.levels.WARN)
		end
		return
	end

	local settings = config.get()

	-- Preparing a statement runs nothing, so checking against production is
	-- safe. It is still traffic to a production server on every save, so the
	-- automatic pass skips it; asking explicitly (:NGripValidate) does not.
	if connection.production and not opts.notify then
		return
	end
	if connection.production and opts.notify then
		neogrip.notify(
			("%s is marked production; checking it anyway, nothing is executed"):format(connection.name)
		)
	end

	local checkable, reason = M.checkable(statement.text)
	if not checkable then
		if opts.notify then
			neogrip.notify(reason, vim.log.levels.WARN)
		end
		return
	end

	runner.run({
		connection = connection,
		sql = statement.text,
		mode = "validate",
		limit = 0,
		background = true,
		timeout_ms = math.min(settings.timeout_ms, 10000),
	}, function(_, err)
		if err and not err.cancelled then
			M.from_error(bufnr, statement, err)
			if opts.notify then
				neogrip.notify(err.message, vim.log.levels.ERROR)
			end
		else
			M.clear(bufnr)
			if opts.notify then
				neogrip.notify("the server accepts this statement")
			end
		end
	end)
end

function M.setup()
	local group = vim.api.nvim_create_augroup("NeogripDiagnostics", { clear = true })
	vim.api.nvim_create_autocmd("BufWritePost", {
		group = group,
		pattern = { "*.sql", "*.mongodb" },
		callback = function(args)
			if not config.get().validate_on_save then
				return
			end
			-- Debounced: saving twice in a row should not open two processes.
			if pending[args.buf] then
				pending[args.buf]:stop()
			end
			pending[args.buf] = vim.defer_fn(function()
				pending[args.buf] = nil
				M.validate({ bufnr = args.buf })
			end, 200)
		end,
	})
	vim.api.nvim_create_autocmd("BufDelete", {
		group = group,
		callback = function(args)
			pending[args.buf] = nil
		end,
	})
end

return M
