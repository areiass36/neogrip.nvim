-- Sweeping a whole database and then answering from the sweep.
--
-- File-backed engines rather than the containers: this needs a real JDBC driver
-- and a real server, but not a network -- the file is the server. So the claim
-- the feature rests on, that after one sweep the explorer answers with nothing
-- running, is checked wherever the JDK and the drivers are, which is anywhere
-- this config has been used once.
--
-- Two of them, because they disagree about what metadata exists: SQLite reports
-- primary keys, indexes and foreign keys, where the DuckDB driver reports none
-- of the three. The sweep has to be right either way, and an engine with
-- nothing to report must not come out looking like a sweep that failed.
local support = require("tests.support")
local check, note = support.check, support.note

if not support.has_jdk() then
	support.describe("live/introspect")
	note("skipped: no JDK available (set NEOGRIP_TEST_JDK)")
	return
end
support.seed_secrets()
local explorer = require("neogrip.explorer")
local icons = require("neogrip.icons")
local sidecar = require("neogrip.sidecar")
local schema = require("neogrip.schema")
local store = require("neogrip.schema.store")

local ENGINES = {
	{
		driver = "sqlite",
		-- SQLite has no schemas at all, so the sweep writes one without a name
		-- and every lookup here passes nil: the one place where "known" and
		-- "named" come apart.
		schema_name = nil,
		reports_keys = true,
		fixture = {
			"CREATE TABLE customers (id INTEGER PRIMARY KEY, email TEXT NOT NULL, tier TEXT DEFAULT 'free')",
			"CREATE TABLE orders (id INTEGER PRIMARY KEY, "
				.. "customer_id INTEGER REFERENCES customers(id), total REAL)",
			"CREATE INDEX orders_by_customer ON orders (customer_id)",
			"CREATE VIEW big_orders AS SELECT * FROM orders WHERE total > 100",
			-- Two names one wildcard apart: getColumns takes a pattern, so
			-- asking about the first used to be answered for the second too.
			"CREATE TABLE fato_cliente (cnpj_raiz TEXT, decisor TEXT)",
			"CREATE TABLE fatoXcliente (zzz TEXT)",
		},
	},
	{
		driver = "duckdb",
		schema_name = "sales",
		reports_keys = false,
		fixture = {
			"CREATE SCHEMA IF NOT EXISTS sales",
			"CREATE TABLE sales.customers ("
				.. "id BIGINT PRIMARY KEY, email VARCHAR NOT NULL, tier VARCHAR DEFAULT 'free')",
			"CREATE TABLE sales.orders ("
				.. "id BIGINT PRIMARY KEY, customer_id BIGINT REFERENCES sales.customers(id), total DECIMAL)",
			"CREATE INDEX orders_by_customer ON sales.orders (customer_id)",
			"CREATE VIEW sales.big_orders AS SELECT * FROM sales.orders WHERE total > 100",
			"CREATE TABLE sales.fato_cliente (cnpj_raiz VARCHAR, decisor VARCHAR)",
			"CREATE TABLE sales.fatoXcliente (zzz VARCHAR)",
		},
	},
}

local java = require("tools.jdk").java()

for _, engine in ipairs(ENGINES) do
	support.describe("live/introspect: " .. engine.driver)
	local jar = require("tools.jdbc").jar(engine.driver)
	if not java or not jar then
		note("skipped: no JDK or no driver yet (both download on first use)")
	else
		local file =
			vim.fs.normalize(("%s/db/introspect-test.%s"):format(vim.fn.stdpath("state"), engine.driver))
		pcall(vim.fn.delete, file)
		local connection = {
			id = ("__test_introspect_%s__"):format(engine.driver),
			name = engine.driver .. " introspect test",
			driver = engine.driver,
			file = file,
			password_source = { kind = "none" },
			options = {},
			client = engine.driver,
			scope = "global",
		}
		local where = engine.schema_name

		local broken = false
		for _, sql in ipairs(engine.fixture) do
			local _, fixture_err = support.run(connection, sql, { mode = "exec" })
			if fixture_err then
				support.fail("fixture", ("%s -- %s"):format(sql, fixture_err.message))
				broken = true
				break
			end
		end

		-- The catalog the explorer would open on, so what is swept is what it
		-- then reads.
		local catalog = explorer.entry_point(connection).context.catalog
		schema.invalidate(connection)
		local summary = nil
		if not broken then
			check("nothing is swept to begin with", store.stat(connection, catalog), nil)
			local err
			summary, err = support.sync(function(done)
				schema.introspect(connection, catalog, {}, function(result, sweep_err)
					done(result, sweep_err)
				end)
			end, 120000)
			check("the sweep ran", err, nil)
		end

		if summary then
			note(
				("%d schemas, %d tables, %d columns, %d definitions in %d ms"):format(
					summary.schemas,
					summary.tables,
					summary.columns,
					summary.details,
					summary.elapsed_ms
				)
			)
			check("it found the tables", summary.tables >= 3, true)
			check("and their columns", summary.columns >= 8, true)
			check("and collected the definitions", summary.details >= 3, true)
			check("none of it was cut short", summary.partial, false)
			-- A file takes one writer, so no second connection is opened to it:
			-- the sequential fallback is the path under test here.
			check("on one connection, because a file takes one writer", summary.parallel, false)
			check("written where the store looks", vim.fn.filereadable(store.path(connection, catalog)), 1)

			local stat = store.stat(connection, catalog)
			check("the store reports it", stat ~= nil, true)
			check("with the counts the sweep reported", stat.tables, summary.tables)
			check("and when it was taken", stat.age_seconds < 300, true)
			note("product: " .. tostring(stat.product))

			local tables = {}
			for _, record in ipairs(store.tables(connection, catalog, where) or {}) do
				tables[record.name] = record
			end
			check("every table is in it", tables.customers ~= nil and tables.orders ~= nil, true)
			check("typed as tables", tables.customers and tables.customers.kind, "table")
			check("and a view known to be a view", tables.big_orders and tables.big_orders.kind, "view")

			local columns = {}
			for _, column in ipairs(store.columns(connection, catalog, where, "customers") or {}) do
				columns[column.name] = column
			end
			check(
				"every column of a table",
				columns.id ~= nil and columns.email ~= nil and columns.tier ~= nil,
				true
			)
			check("with its type", (columns.email or {}).type ~= nil, true)
			check("and whether it may be null", (columns.email or {}).nullable, false)

			local details = store.details(connection, catalog, where, "customers") or {}
			check("a definition is there", details.rows ~= nil, true)
			check("with the columns in it", #(details.rows or {}), 3)

			local orders = store.details(connection, catalog, where, "orders") or {}
			if engine.reports_keys then
				-- The definition is what the preview and <CR> both draw, and one
				-- cached without its key would be silently wrong.
				check("the primary key, as the per-table path reports it", details.primary_key, { "id" })
				check("flagged on the column as well", (columns.id or {}).is_pk, true)
				check("the indexes", #(orders.indexes or {}) >= 1, true)
				check("the foreign keys", #(orders.foreign_keys or {}) >= 1, true)
				check(
					"naming the table they point at",
					((orders.foreign_keys or {})[1] or {}).table,
					"customers"
				)
				check(
					"and the inbound reference on the other side of it",
					#(details.referenced_by or {}) >= 1,
					true
				)
			else
				-- Nothing to report is an answer: db/explorer/detail.lua writes
				-- that in the buffer rather than leaving the sections out.
				note(
					("this driver reports %d keys, %d indexes, %d foreign keys"):format(
						#(details.primary_key or {}),
						#(orders.indexes or {}),
						#(orders.foreign_keys or {})
					)
				)
			end

			-- A name is a name, not a pattern. An underscore matches any
			-- single character in JDBC metadata, so a definition could quietly
			-- carry another table's columns -- on a warehouse, where every
			-- name has one, that is what the explorer showed.
			local narrow = support.sync(function(done)
				schema.details(connection, where, "fato_cliente", function(answer, failure)
					done(answer, failure)
				end, catalog)
			end, 60000)
			local named = {}
			for _, column in ipairs((narrow or {}).rows or {}) do
				named[#named + 1] = column.name
			end
			table.sort(named)
			check("a table's definition carries only its own columns", named, { "cnpj_raiz", "decisor" })

			-- The point of the whole thing: stop the process and ask again.
			sidecar.disconnect(connection.id)
			check("the process can be stopped", sidecar.is_connected(connection.id), false)

			local offline = nil
			schema.columns(connection, where, "orders", function(records)
				offline = records
			end, catalog)
			check("the columns still answer, synchronously", offline ~= nil and #offline, 3)
			check(
				"and so does a definition",
				schema.details_ready(connection, catalog, where, "orders") ~= nil,
				true
			)

			local entries = nil
			explorer.levels.tables.load(
				{ connection = connection, catalog = catalog, schema = where },
				function(list)
					entries = list
				end
			)
			check("the explorer's table level answers too", entries ~= nil and #entries >= 3, true)
			local by_name = {}
			for _, entry in ipairs(entries or {}) do
				by_name[entry.value] = entry
			end
			check(
				"a table wears the table icon",
				by_name.customers and by_name.customers.text:find(icons.table, 1, true) ~= nil,
				true
			)
			check(
				"and a view the branch icon",
				by_name.big_orders and by_name.big_orders.text:find(icons.branch, 1, true) ~= nil,
				true
			)
			check("none of which reopened the process", sidecar.is_connected(connection.id), false)

			-- Asked again it replaces what it found before, and told to skip the
			-- definitions it skips them.
			local second, second_err = support.sync(function(done)
				schema.introspect(
					connection,
					catalog,
					{ parallelism = 1, details = false },
					function(result, sweep_err)
						done(result, sweep_err)
					end
				)
			end, 120000)
			check("a second sweep replaces the first", second_err, nil)
			check("finding the same tables", second and second.tables, summary.tables)
			check("and skipping the definitions it was told to skip", second and second.details, 0)
			check(
				"so a definition costs a round trip again",
				schema.details_ready(connection, catalog, where, "orders"),
				nil
			)
		end

		-- The driver holds the file open until its process is really gone, and
		-- a delete before then fails quietly and leaves the fixture in the
		-- state directory.
		sidecar.disconnect(connection.id)
		vim.wait(5000, function()
			return not sidecar.is_connected(connection.id)
		end, 50)
		vim.wait(250, function()
			return false
		end)
		schema.invalidate(connection)
		for _, leftover in ipairs({ file, file .. ".wal" }) do
			pcall(vim.fn.delete, leftover)
		end
	end
end
