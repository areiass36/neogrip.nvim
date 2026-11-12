-- Validation prepares the statement: the server parses it and resolves the names but executes
-- nothing; PostgreSQL even reports the character position.
local classify = require("neogrip.sql.classify")
local config = require("neogrip.config")
local notify = require("neogrip.notify")
local errors = require("neogrip.gripd.errors")
local resolve = require("neogrip.connections.resolve")
local runner = require("neogrip.gripd.runner")
local statement_module = require("neogrip.ui.statement")

local M = {}

local NAMESPACE = vim.api.nvim_create_namespace("neogrip_diagnostics")
local pending = {}

--- A transaction or session command has nothing to validate.
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
	local statement = opts.statement or statement_module.at_cursor(bufnr)
	if not statement then
		return
	end

	local connection = resolve.for_buf(bufnr)
	if not connection then
		if opts.notify then
			notify.send("no connection for this buffer", vim.log.levels.WARN)
		end
		return
	end

	local settings = config.get()

	-- Preparing runs nothing, but it is still traffic to a production server on every save,
	-- so the automatic pass skips production; an explicit :NGripValidate does not.
	if connection.production and not opts.notify then
		return
	end
	if connection.production and opts.notify then
		notify.send(
			("%s is marked production; checking it anyway, nothing is executed"):format(connection.name)
		)
	end

	local checkable, reason = M.checkable(statement.text)
	if not checkable then
		if opts.notify then
			notify.send(reason, vim.log.levels.WARN)
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
				notify.send(err.message, vim.log.levels.ERROR)
			end
		else
			M.clear(bufnr)
			if opts.notify then
				notify.send("the server accepts this statement")
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
