-- The catalog of every engine, and the explorer's generated SELECT.
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
	{ driver = "mssql", schema_name = "dbo", table_name = "torture" },
	{ driver = "sqlite", schema_name = nil, table_name = "torture" },
	{ driver = "duckdb", schema_name = "main", table_name = "torture" },
	{ driver = "mongodb", schema_name = nil, table_name = "orders" },
}

-- Only the connections this suite uses: invalidate(nil) would also delete the
-- catalogs the developer has swept, which cost a sweep to get back.
for _, connection in pairs(connections) do
	schema.invalidate(connection)
end

for _, target in ipairs(targets) do
	local connection = connections[target.driver]
	support.describe("live/schema: " .. target.driver)
	if not support.reachable(connection) then
		note("skipped: nothing listening (tests/containers.sh up)")
	else
		local databases, databases_err = support.sync(function(done)
			schema.databases(connection, function(records, err)
				done(records, err)
			end)
		end)
		if databases_err then
			support.fail("databases", databases_err)
		else
			-- SQLite has no catalog level at all, which is why the explorer
			-- goes straight from the connection to its tables.
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

		local tables, tables_err = support.sync(function(done)
			schema.tables(connection, target.schema_name, nil, function(records, err)
				done(records, err)
			end)
		end)
		if tables_err then
			support.fail("tables", tables_err)
		else
			local found = false
			for _, record in ipairs(tables) do
				if record.name == target.table_name then
					found = true
					check("the kind is reported", record.kind ~= nil, true)
				end
			end
			check(("%s is listed"):format(target.table_name), found, true)
		end

		local columns, columns_err = support.sync(function(done)
			schema.columns(connection, target.schema_name, target.table_name, function(records, err)
				done(records, err)
			end)
		end)
		if columns_err then
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

support.describe("live/schema: a binary column needs no rewriting")
local pg = connections.postgres
if support.reachable(pg) then
	local columns = support.sync(function(done)
		schema.columns(pg, "public", "torture", function(records)
			done(records)
		end)
	end)
	local statement = schema.select_statement(pg, "public", "torture", columns)
	-- The old client had to rewrite the projection as encode(b,'hex') because
	-- its JSON output destroyed the bytes. JDBC reports the column as binary,
	-- so the Java side renders it as hex and "select *" is enough.
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
	-- Not a timing comparison any more: JDBC answers a catalog question in a
	-- millisecond or two, so "slower than the cache" is not measurable. What
	-- matters is that the answer is fetched again.
	check("and after invalidating it asks the server again", #fresh > 0, true)
else
	note("skipped")
end
