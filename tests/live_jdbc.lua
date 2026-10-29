-- Every database through JDBC: the values that are easy to get wrong, and the
-- process that stays alive between queries.
local support = require("tests.support")
local check, note = support.check, support.note
local neogrip = require("neogrip")
local sidecar = require("neogrip.sidecar")

if not support.has_jdk() then
	support.describe("live/jdbc")
	support.note("skipped: no JDK available (set NEOGRIP_TEST_JDK)")
	return
end
support.seed_secrets()

local connections = support.connections()
local order = { "postgres", "mysql", "mssql", "sqlite", "duckdb", "mongodb" }

for _, driver in ipairs(order) do
	local connection = connections[driver]
	support.describe("live/" .. driver)

	if not support.reachable(connection) then
		note("skipped: nothing listening (tests/containers.sh up)")
	else
		if driver == "duckdb" then
			-- The file has to be created by the same driver that reads it:
			-- DuckDB refuses a file written by another version.
			support.run(
				connection,
				"create or replace table torture as select * from "
					.. "(values (1,NULL,'','a,b','日本語'),(2,NULL,'','x','中文')) t(id,s_null,s_empty,s_comma,cjk)",
				{ mode = "exec" }
			)
		end

		local sql = driver == "mongodb" and "db.orders.find({})" or "select * from torture order by id"
		local result, run_err = support.run(connection, sql, { limit = 10, timeout = 90000 })
		if run_err then
			support.fail("query", run_err.message)
		else
			check("two rows", #result.rows, 2)
			check("the column types come from the driver", #(result.column_types or {}), #result.columns)
			local by_name = {}
			for index, column in ipairs(result.columns) do
				by_name[column] = result.rows[1][index]
			end

			if driver == "mongodb" then
				check("a nested object is summarised", by_name.cust, "{…}")
				check("an array is summarised", by_name.tags, "[2]")
				check("a decimal keeps its digits", by_name.total, 10.5)
				check("false is false, not NULL", result.rows[2][6], false)
			else
				check("NULL is not the empty string", by_name.s_null == neogrip.NULL, true)
				check("and the empty string is a string", by_name.s_empty, "")
				check("a comma inside a value", by_name.s_comma, "a,b")
				check("cjk", by_name.cjk, driver == "postgres" and "日本語テキスト" or "日本語")
			end

			if driver == "postgres" then
				check("a quote inside a value", by_name.s_quote, 'he said "hi"')
				check("a newline inside a value", by_name.s_nl, "li\nnha")
				check("numeric keeps its scale", by_name.n, "8.90")
				check("int8 past 2^53 survives as text", by_name.big, "9007199254740993")
				check("boolean", by_name.flag, true)
				check("timestamptz is ISO 8601", by_name.ts, "2024-03-05T14:30:00Z")
				check("emoji", by_name.emoji, "🚀🔥")
				-- The old client mangled this into replacement characters;
				-- JDBC knows the column is binary, so it arrives as hex.
				check("bytea is readable hex", by_name.b, "01020aff")
				check("and a NULL bytea is still NULL", result.rows[2][9] == neogrip.NULL, true)
			end

			if driver == "mysql" or driver == "mssql" then
				check("decimal keeps its scale", by_name.n, "8.90")
				check("bit becomes a boolean", by_name.flag, true)
			end
		end

		-- The process is reused, which is the whole point of the daemon.
		check("the connection is live", sidecar.is_connected(connection.id), true)
		local info = sidecar.info(connection.id)
		note(("server: %s"):format(tostring(info and info.product)))
		local started = vim.uv.now()
		support.run(
			connection,
			driver == "mongodb" and "db.orders.find({})" or "select 1 as a",
			{ limit = 1 }
		)
		local elapsed = vim.uv.now() - started
		note(("a second query took %d ms"):format(elapsed))
		check("the second query does not pay for a new process", elapsed < 3000, true)

		-- An error is an error, with the server's own code.
		local bad = driver == "mongodb" and "db.orders.find({ $badop: 1 })" or "select nosuchcol from torture"
		local _, bad_err = support.run(connection, bad)
		check("a bad query is reported", bad_err ~= nil, true)
		if bad_err then
			note(("error: %s [%s]"):format(tostring(bad_err.message):sub(1, 70), tostring(bad_err.state)))
		end
	end
end

support.describe("live: paging is the driver's job")
local pg = connections.postgres
if support.reachable(pg) then
	local page = support.run(pg, "select * from torture order by id", { limit = 1 })
	check("one row on the page", #page.rows, 1)
	check("and the driver says there is more", page.has_more, true)
	local second = support.run(pg, "select * from torture order by id", { limit = 1, offset = 1 })
	check("the next page is the next row", second.rows[1][1], 2)
	check("and there is no more", second.has_more, false)
else
	note("skipped")
end
