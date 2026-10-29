-- Checking a statement on the server, and pointing at the right place.
--
-- With JDBC this is one mechanism for every engine: preparing a statement
-- makes the server parse it, resolve the names and describe the result,
-- without running it. The envelopes the old command line clients needed -
-- PREPARE inside a rolled-back transaction, EXPLAIN kept away from ANALYZE,
-- and SQL Server's dangerous SET NOEXEC - are all gone.
local support = require("tests.support")
local check, note = support.check, support.note

if not support.has_jdk() then
	support.describe("live/diagnostics")
	note("skipped: no JDK available (set NEOGRIP_TEST_JDK)")
	return
end
support.seed_secrets()
local diagnostics = require("neogrip.diagnostics")

local connections = support.connections()

support.describe("diagnostics: what is worth sending")
check("a select is", diagnostics.checkable("select 1"), true)
check("a write is too", diagnostics.checkable("insert into t values (1)"), true)
check("so is ddl", diagnostics.checkable("create table z(a int)"), true)
check("a transaction command is not", diagnostics.checkable("begin"), false)
check("nor a session one", diagnostics.checkable("set search_path to x"), false)

for _, driver in ipairs({ "postgres", "mysql", "mssql", "sqlite", "duckdb" }) do
	local connection = connections[driver]
	support.describe("live/diagnostics: " .. driver)
	if not support.reachable(connection) then
		note("skipped: nothing listening (tests/containers.sh up)")
	else
		local connections_module = require("neogrip.connections")
		local saved_get = connections_module.get
		connections_module.get = function(id)
			return id == connection.id and connection or saved_get(id)
		end

		local table_name = driver == "mssql" and "dbo.torture" or "torture"
		local bufnr = vim.api.nvim_create_buf(false, true)
		vim.bo[bufnr].filetype = "sql"
		vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {
			"select id, nosuchcol",
			("  from %s;"):format(table_name),
		})
		vim.api.nvim_set_current_buf(bufnr)
		require("neogrip.resolve").bind(bufnr, connection.id)

		diagnostics.validate({ bufnr = bufnr })
		support.wait(function()
			return #vim.diagnostic.get(bufnr) > 0
		end, 60000)
		local list = vim.diagnostic.get(bufnr)
		check("a diagnostic appears", #list > 0, true)
		if #list > 0 then
			local item = list[1]
			note(("line %d col %d-%d: %s"):format(item.lnum + 1, item.col, item.end_col, item.message))
			check("the message names the column", item.message:find("nosuchcol") ~= nil, true)
			local text = vim.api.nvim_buf_get_lines(bufnr, item.lnum, item.lnum + 1, false)[1]
			check("and the mark covers it", text:sub(item.col + 1, item.end_col), "nosuchcol")
		end

		-- Nothing ran: the table is untouched and a good statement clears it.
		vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { ("select id from %s;"):format(table_name) })
		diagnostics.validate({ bufnr = bufnr })
		support.wait(function()
			return #vim.diagnostic.get(bufnr) == 0
		end, 30000)
		check("a good statement clears it", #vim.diagnostic.get(bufnr), 0)
		connections_module.get = saved_get
	end
end

support.describe("live/diagnostics: postgres reports the exact position")
local pg = connections.postgres
if support.reachable(pg) then
	local _, err = support.run(pg, "select id, nosuchcol from torture", { mode = "validate" })
	check("it fails", err ~= nil, true)
	if err then
		note(
			("state=%s position=%s :: %s"):format(
				tostring(err.state),
				tostring(err.position),
				err.message:sub(1, 50)
			)
		)
		check("with a SQLState", err.state, "42703")
		check("and a character position", type(err.position), "number")
	end
else
	note("skipped")
end

support.describe("live/diagnostics: production is not probed on save")
if support.reachable(pg) then
	local production = vim.tbl_extend("force", pg, { id = "test-pg-prod", production = true })
	local connections_module = require("neogrip.connections")
	local saved_get = connections_module.get
	connections_module.get = function(id)
		return id == production.id and production or saved_get(id)
	end
	local bufnr = vim.api.nvim_create_buf(false, true)
	vim.bo[bufnr].filetype = "sql"
	vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "select nosuchcol from torture;" })
	vim.api.nvim_set_current_buf(bufnr)
	require("neogrip.resolve").bind(bufnr, production.id)

	-- The automatic pass (no notify) leaves a production server alone.
	diagnostics.validate({ bufnr = bufnr })
	vim.wait(2000, function()
		return #vim.diagnostic.get(bufnr) > 0
	end, 50)
	check("nothing was checked on save", #vim.diagnostic.get(bufnr), 0)

	-- Asking explicitly does check it, and says that it is production.
	local messages = {}
	local original = vim.notify
	vim.notify = function(message)
		messages[#messages + 1] = message
	end
	diagnostics.validate({ bufnr = bufnr, notify = true })
	support.wait(function()
		return #vim.diagnostic.get(bufnr) > 0
	end, 30000)
	vim.notify = original
	local warned = false
	for _, message in ipairs(messages) do
		if message:find("production") then
			warned = true
		end
	end
	check("asking explicitly says it is production", warned, true)
	check("and does report the error", #vim.diagnostic.get(bufnr) > 0, true)
	connections_module.get = saved_get
else
	note("skipped")
end
