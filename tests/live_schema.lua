-- The catalog of every engine, and the SELECT generated for a set.
local support = require("tests.support")
local check, note = support.check, support.note

if not support.has_jdk() then
	support.describe("live/schema")
	note("skipped: no JDK available (set NEOGRIP_TEST_JDK)")
	return
end
support.seed_secrets()
local schema = require("neogrip.schema")

local connections = support.connections()
local targets = {
	{ driver = "postgres", schema_name = "public", table_name = "torture" },
	{ driver = "mysql", schema_name = "testdb", table_name = "torture" },
	{ driver = "mariadb", schema_name = "testdb", table_name = "torture" },
	{ driver = "mssql", schema_name = "dbo", table_name = "torture" },
	{ driver = "sqlite", schema_name = nil, table_name = "torture" },
	{ driver = "duckdb", schema_name = "main", table_name = "torture" },
	-- A collection is a set like any other, and its kind says which (ADR-0036).
	{ driver = "mongodb", schema_name = nil, table_name = "orders", kind = "collection" },
}

-- Only this suite's connections: invalidate(nil) would delete the developer's own catalogs.
for _, connection in pairs(connections) do
	schema.invalidate(connection)
end

for _, target in ipairs(targets) do
	local connection = connections[target.driver]
	support.describe("live/schema: " .. target.driver)
	if not support.reachable(connection) then
		note("skipped: nothing listening (tests/containers.sh up)")
	else
		support.ensure_fixture(connection)
		local databases, databases_err = support.sync(function(done)
			schema.databases(connection, function(records, err)
				done(records, err)
			end)
		end)
		if databases_err then
			support.fail("databases", databases_err)
		else
			-- SQLite has no catalog level at all.
			if target.driver ~= "sqlite" then
				check("databases are listed", #databases > 0, true)
			end
			note("databases: " .. table
				.concat(
					vim.tbl_map(function(r)
						return tostring(r.name)
					end, databases),
					", "
				)
				:sub(1, 70))
		end

		-- A view, so the kind collapse of ADR-0036 is asserted; the error is ignored
		-- because no engine agrees on the spelling of "create or replace view".
		if target.driver ~= "mongodb" then
			support.run(
				connection,
				("create view torture_v as select * from %s"):format(target.table_name),
				{ mode = "exec" }
			)
			schema.invalidate(connection)
		end

		-- Without these the "nothing outside the three" check below passed without
		-- ever being tested; PostgreSQL has both ambiguous TABLE_TYPEs.
		if target.driver == "postgres" then
			support.run(
				connection,
				("create materialized view if not exists torture_mv as select id from %s"):format(
					target.table_name
				),
				{ mode = "exec" }
			)
			support.run(
				connection,
				"create table if not exists torture_part (id int) partition by range (id)",
				{ mode = "exec" }
			)
			schema.invalidate(connection)
		end

		local tables, tables_err = support.sync(function(done)
			schema.tables(connection, target.schema_name, nil, function(records, err)
				done(records, err)
			end)
		end)
		if tables_err then
			support.fail("tables", tables_err)
		else
			local found, kinds = false, {}
			for _, record in ipairs(tables) do
				kinds[record.kind] = true
				if record.name == target.table_name then
					found = true
					check("the set carries its kind", record.kind, target.kind or "table")
				end
				if record.name == "torture_v" then
					check("and a view is a view", record.kind, "view")
				end
				if record.name == "torture_mv" then
					check("a materialized view collapses to a view", record.kind, "view")
				end
				if record.name == "torture_part" then
					check("and a partitioned table to a table", record.kind, "table")
				end
			end
			check(("%s is listed"):format(target.table_name), found, true)

			-- The keyset paging of ADR-0038 is only exact while the server's order
			-- is total and stable (ADR-0036).
			local names, ordered = {}, true
			for _, record in ipairs(tables) do
				names[#names + 1] = tostring(record.name)
			end
			for index = 2, #names do
				if names[index - 1]:lower() > names[index]:lower() then
					ordered = false
				end
			end
			check("the listing comes back ordered by name", ordered, true)
			for kind in pairs(kinds) do
				check(
					("%s is one of the three kinds"):format(kind),
					kind == "table" or kind == "view" or kind == "collection",
					true
				)
			end
		end

		local columns, columns_err = support.sync(function(done)
			schema.columns(connection, target.schema_name, target.table_name, function(records, err)
				done(records, err)
			end)
		end)
		-- MongoDB field sampling is best-effort: an empty sample is the wrapper
		-- declining, not a neogrip failure (ADR-0029).
		if target.driver == "mongodb" and not columns_err and #columns == 0 then
			note("mongodb: the wrapper returned no field sample; skipped (ADR-0029)")
		elseif columns_err then
			support.fail("columns", columns_err)
		else
			check("columns are reported", #columns > 0, true)
			note("columns: " .. table
				.concat(
					vim.tbl_map(function(column)
						return ("%s:%s"):format(column.name, column.type or "?")
					end, columns),
					", "
				)
				:sub(1, 90))
			if target.driver == "postgres" then
				local by_name = {}
				for _, column in ipairs(columns) do
					by_name[column.name] = column
				end
				check("the primary key is marked", by_name.id.is_pk, true)
				check("the full type is reported", by_name.n.type, "numeric(10,2)")
				check("nullability", by_name.s_null.nullable, true)
			end
			if target.driver == "mongodb" then
				local types = {}
				for _, column in ipairs(columns) do
					types[#types + 1] = ("%s:%s"):format(column.name, column.type)
				end
				local polymorphic = 0
				for _, entry in ipairs(types) do
					if entry:match("^total:") then
						polymorphic = polymorphic + 1
					end
				end
				check("a field with two types is reported twice", polymorphic, 2)
			end
		end

		local statement = schema.select_statement(connection, target.schema_name, target.table_name, columns)
		note("select: " .. statement:sub(1, 100))
		local _, select_err = support.run(connection, statement, { limit = 5 })
		check("the generated select runs", select_err, nil)
	end
end

support.describe("live/schema: a listing pages by name")
local duck = connections.duckdb
if not support.reachable(duck) then
	note("skipped")
else
	local gripd = require("neogrip.gripd")
	for letter in ("abcdefg"):gmatch(".") do
		support.run(duck, ("create table if not exists page_%s(id int)"):format(letter), { mode = "exec" })
	end

	-- Driven through the wire: what is being proved is the contract of ADR-0038.
	local seen, order, after, pages, cut = {}, {}, nil, 0, nil
	repeat
		local params = { schema = "main", limit = 3 }
		params.after = after
		local result, err = support.sync(function(done)
			gripd.request(duck, "catalog/tables", params, function(res, request_err)
				done(res, request_err)
			end)
		end)
		if err or not result then
			support.fail("paging", err and err.message or "no answer")
			break
		end
		pages = pages + 1
		check(("page %d holds at most the limit"):format(pages), #result.rows <= 3, true)
		for _, row in ipairs(result.rows) do
			seen[row.name] = (seen[row.name] or 0) + 1
			order[#order + 1] = row.name
			after = row.name
		end
		cut = result.truncated
	until not cut or pages >= 20

	check("more than one page was needed", pages > 1, true)
	check("and the last page is not marked truncated", cut, nil)
	local increasing = true
	for index = 2, #order do
		if order[index - 1]:lower() >= order[index]:lower() then
			increasing = false
		end
	end
	check("names strictly increase across pages", increasing, true)
	local missing, repeated = {}, {}
	for letter in ("abcdefg"):gmatch(".") do
		local name = "page_" .. letter
		if not seen[name] then
			missing[#missing + 1] = name
		elseif seen[name] > 1 then
			repeated[#repeated + 1] = name
		end
	end
	check("every table was seen", missing, {})
	check("and none of them twice", repeated, {})
	note(("%d names over %d pages"):format(#order, pages))
end

support.describe("live/schema: a collection is sampled at both ends")
do
	local mongo = connections.mongodb
	if not support.reachable(mongo) then
		note("skipped")
	else
		-- A field only in the first document and another only in the last: reading
		-- just the head would see one of them (ADR-0038).
		local fields = support.sync(function(done)
			schema.columns(mongo, nil, "sampling", function(records, err)
				done(records, err)
			end)
		end)
		if not fields or #fields == 0 then
			note("mongodb: the wrapper returned no field sample; skipped (ADR-0029)")
		else
			local by_name = {}
			for _, field in ipairs(fields) do
				by_name[field.name] = field
			end
			check("a field only in the first document is seen", by_name.only_first ~= nil, true)
			check("and one only in the last is seen too", by_name.only_last ~= nil, true)
			check("the sample says how many it looked at", by_name.filler and by_name.filler.sample_size, 100)
			note(
				("sampling: %d fields over %s documents"):format(
					#fields,
					tostring(by_name.filler and by_name.filler.sample_size)
				)
			)
		end
	end
end

support.describe("live/schema: approximate row counts")
do
	local gripd = require("neogrip.gripd")
	-- PostgreSQL's reltuples is -1 until analyzed, so the analyze makes this
	-- about the query and not the clock.
	local count_targets = {
		{ driver = "postgres", schema_name = "public", prepare = "analyze torture" },
		{ driver = "mysql", schema_name = "testdb" },
		{ driver = "mariadb", schema_name = "testdb" },
		{ driver = "mssql", schema_name = "dbo" },
		{ driver = "duckdb", schema_name = "main", empty = true },
		{ driver = "sqlite", empty = true },
		{ driver = "mongodb", empty = true },
		-- A query engine owns no tables and keeps no statistics of its own.
		{ driver = "trino", empty = true },
	}
	for _, target in ipairs(count_targets) do
		local connection = connections[target.driver]
		if not support.reachable(connection) then
			note(("%s: skipped"):format(target.driver))
		else
			-- catalog/counts goes straight to the process, and Trino, in this list
			-- only, would be asked before it had a connection at all.
			if not gripd.is_connected(connection.id) then
				support.run(connection, "select 1", { timeout = 90000 })
			end
			if target.prepare then
				support.run(connection, target.prepare, { mode = "exec" })
			end
			local result, err = support.sync(function(done)
				gripd.request(
					connection,
					"catalog/counts",
					{ schema = target.schema_name },
					function(res, request_err)
						done(res, request_err)
					end
				)
			end)
			check(("%s answers without failing"):format(target.driver), err, nil)
			if result then
				if target.empty then
					-- Nothing counts rows on its own behalf (ADR-0038).
					check(("%s keeps no estimate"):format(target.driver), vim.tbl_count(result.counts), 0)
				else
					local estimate = result.counts and result.counts.torture
					check(("%s estimates torture"):format(target.driver), type(estimate), "number")
					note(("%s: torture ~ %s rows"):format(target.driver, tostring(estimate)))
				end
			end
		end
	end
end

support.describe("live/schema: a binary column needs no rewriting")
local pg = connections.postgres
if support.reachable(pg) then
	local columns = support.sync(function(done)
		schema.columns(pg, "public", "torture", function(records)
			done(records)
		end)
	end)
	local statement = schema.select_statement(pg, "public", "torture", columns)
	-- The old client had to rewrite the projection as encode(b,'hex'); with JDBC
	-- "select *" is enough.
	check("a plain select is generated", statement, 'SELECT * FROM "public"."torture"')
	local result = support.run(pg, statement .. " ORDER BY id", { limit = 5 })
	local index
	for position, column in ipairs(result.columns) do
		if column == "b" then
			index = position
		end
	end
	check("and the value is readable", result.rows[1][index], "01020aff")
else
	note("skipped")
end

support.describe("live/schema: the cache")
if support.reachable(pg) then
	support.sync(function(done)
		schema.tables(pg, "public", nil, function(records)
			done(records)
		end)
	end)
	local started = vim.uv.hrtime()
	support.sync(function(done)
		schema.tables(pg, "public", nil, function(records)
			done(records)
		end)
	end)
	local elapsed = (vim.uv.hrtime() - started) / 1e6
	check("the second lookup does not touch the server", elapsed < 50, true)
	note(("cached lookup: %.1f ms"):format(elapsed))

	schema.invalidate(pg)
	local fresh = support.sync(function(done)
		schema.tables(pg, "public", nil, function(records)
			done(records)
		end)
	end)
	-- Not a timing comparison: JDBC answers in a millisecond or two, so "slower
	-- than the cache" is not measurable.
	check("and after invalidating it asks the server again", #fresh > 0, true)
else
	note("skipped")
end
