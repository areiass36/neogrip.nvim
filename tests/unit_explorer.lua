-- The explorer's tree and the pure helpers around it. The levels are driven
-- directly rather than through keystrokes: Telescope is only the window, and
-- what is worth testing is which level follows which, what each entry says, and
-- what the actions on an entry produce. No server and no picker.
local support = require("tests.support")
local check = support.check
local explorer = require("neogrip.explorer")
local icons = require("neogrip.icons")
local schema = require("neogrip.schema")

local function connection(driver, database)
	return {
		id = "__test_explorer_" .. driver .. "__",
		name = driver,
		driver = driver,
		database = database,
	}
end

support.describe("explorer: where a walk into a connection begins")

--- The entry point flattened to the three things about it that matter, plus
--- whether the connection came through untouched.
local function entry(driver, database)
	local conn = connection(driver, database)
	local point = explorer.entry_point(conn)
	return {
		level = point.level,
		catalog = point.context.catalog,
		schema = point.context.schema,
		own = point.context.connection == conn,
	}
end

check("sqlite has neither catalogs nor schemas, so it opens on tables", entry("sqlite"), {
	level = "tables",
	own = true,
})
check("and naming a database changes nothing about that", entry("sqlite", "main"), {
	level = "tables",
	own = true,
})
check("duckdb is the same shape", entry("duckdb", ""), { level = "tables", own = true })
check("named or not", entry("duckdb", "memory"), { level = "tables", own = true })

check("mysql's one level is the schema its tables sit in", entry("mysql", "appdb"), {
	level = "tables",
	schema = "appdb",
	own = true,
})
check("mariadb likewise", entry("mariadb", "appdb"), { level = "tables", schema = "appdb", own = true })
check("and mongodb, whose collections are the tables", entry("mongodb", "shop"), {
	level = "tables",
	schema = "shop",
	own = true,
})
check("without one, mysql starts by choosing a database", entry("mysql"), {
	level = "databases",
	own = true,
})
check("as does mariadb", entry("mariadb", ""), { level = "databases", own = true })
check("and mongodb", entry("mongodb"), { level = "databases", own = true })

check("postgres carries its database as the catalog and opens on schemas", entry("postgres", "appdb"), {
	level = "schemas",
	catalog = "appdb",
	own = true,
})
check("sql server the same", entry("mssql", "DW"), { level = "schemas", catalog = "DW", own = true })
check("and trino, where a catalog is full of schemas", entry("trino", "hive"), {
	level = "schemas",
	catalog = "hive",
	own = true,
})
check("without one, postgres starts by choosing a database", entry("postgres"), {
	level = "databases",
	own = true,
})
check("as does sql server", entry("mssql", ""), { level = "databases", own = true })
check("and trino", entry("trino"), { level = "databases", own = true })

support.describe("explorer: choosing a database re-enters the tree")

-- One definition serves both the entry and the step: whichever level a driver
-- starts on is the level a chosen database leads to.
local pg = connection("postgres")
local pg_step = explorer.levels.databases.child({ connection = pg }, { value = "warehouse" })
check("a postgres database leads to its schemas", pg_step.level, "schemas")
check("carried as the catalog", pg_step.context.catalog, "warehouse")
check("on a connection now pointed at it", pg_step.context.connection.database, "warehouse")
check("while the connection it was asked about is left alone", pg.database, nil)

local my_step = explorer.levels.databases.child({ connection = connection("mysql") }, { value = "appdb" })
check("a mysql database is itself the level above its tables", my_step.level, "tables")
check("so it arrives as the schema instead", my_step.context.schema, "appdb")
check("and no catalog is invented for it", my_step.context.catalog, nil)

support.describe("explorer: the name an entry inserts")

local function qualified(driver, level, context, value)
	local full = vim.tbl_extend("force", { connection = connection(driver, "appdb") }, context)
	return explorer.qualified_name(level, full, { value = value })
end

check("a postgres column is quoted on its own", qualified("postgres", "columns", {}, "email"), '"email"')
check(
	"a postgres table is qualified by its schema",
	qualified("postgres", "tables", { schema = "public" }, "users"),
	'"public"."users"'
)
check(
	"a schema is a bare name, because nothing is selected from a schema",
	qualified("postgres", "schemas", {}, "public"),
	"public"
)
check("mysql quotes with backticks", qualified("mysql", "columns", {}, "email"), "`email`")
check(
	"and qualifies with the database it calls a schema",
	qualified("mysql", "tables", { schema = "appdb" }, "users"),
	"`appdb`.`users`"
)
check("a mysql schema name is bare too", qualified("mysql", "schemas", {}, "appdb"), "appdb")
check("sql server quotes with brackets", qualified("mssql", "columns", {}, "email"), "[email]")
check(
	"and qualifies the same way",
	qualified("mssql", "tables", { schema = "dbo" }, "users"),
	"[dbo].[users]"
)
check("and its schema name is bare as well", qualified("mssql", "schemas", {}, "dbo"), "dbo")

support.describe("explorer: what each level lists")

local CATALOG = {
	databases = { { name = "appdb" }, { name = "warehouse" } },
	schemas = { { name = "public" }, { name = "audit" } },
	tables = { { name = "users", kind = "table" }, { name = "active_users", kind = "view" } },
	columns = {
		{ name = "id", type = "bigint", nullable = false, is_pk = true },
		{ name = "note", type = "text", nullable = true },
		{ name = "tags", type = "array", nullable = true, count = 42 },
	},
}

-- db/explorer captured the schema module at load, so the fakes have to replace
-- its functions in place; the module itself must stay the same table.
local real = {
	databases = schema.databases,
	schemas = schema.schemas,
	tables = schema.tables,
	columns = schema.columns,
}

schema.databases = function(_, callback)
	callback(CATALOG.databases, nil)
end
schema.schemas = function(_, _, callback)
	callback(CATALOG.schemas, nil)
end
schema.tables = function(_, _, _, callback)
	callback(CATALOG.tables, nil)
end
schema.columns = function(_, _, _, callback)
	callback(CATALOG.columns, nil)
end

--- Load one level and insist it answered before it returned: the fakes above
--- are synchronous, and a level that went to a server would have to hang here.
local function listed(level, context)
	local entries, failure, called = nil, nil, false
	explorer.levels[level].load(context, function(list, err)
		entries, failure, called = list, err, true
	end)
	return called, entries, failure
end

local function values(entries)
	return vim.tbl_map(function(item)
		return item.value
	end, entries)
end

local conn = connection("postgres", "appdb")

local databases_called, databases = listed("databases", { connection = conn })
check("the databases level answers from what it is given", databases_called, true)
check("naming each one", values(databases), { "appdb", "warehouse" })
check("with the database icon", databases[1].text, ("%s %s"):format(icons.database, "appdb"))

local _, schemas = listed("schemas", { connection = conn, catalog = "appdb" })
check("the schemas level names each schema", values(schemas), { "public", "audit" })
check("and a schema is the folder of the tree", schemas[1].text, ("%s %s"):format(icons.folder, "public"))

-- An engine that reports nothing still has one schema to walk into, or the
-- walk dead-ends on a database that clearly has tables in it.
schema.schemas = function(_, _, callback)
	callback({}, nil)
end
local mssql = vim.tbl_extend("force", connection("mssql", "DW"), { schema = "dbo" })
local _, only = listed("schemas", { connection = mssql, catalog = "DW" })
check("an engine reporting no schemas offers the one it was configured with", values(only), { "dbo" })
local _, fallback = listed("schemas", { connection = conn, catalog = "appdb" })
check("and with nothing configured, the one every postgres has", values(fallback), { "public" })
schema.schemas = function(_, _, callback)
	callback(CATALOG.schemas, nil)
end

local tables_context = { connection = conn, catalog = "appdb", schema = "public" }
local _, tables = listed("tables", tables_context)
check("the tables level names each table", values(tables), { "users", "active_users" })
check("a table gets the table icon", tables[1].text, ("%s %s"):format(icons.table, "users"))
check("and has nothing further to say about itself", tables[1].hint, nil)
check("a view gets the branch icon", tables[2].text, ("%s %s"):format(icons.branch, "active_users"))
check("and says which kind it is", { tables[2].kind, tables[2].hint }, { "view", "view" })

local columns_context = {
	connection = conn,
	catalog = "appdb",
	schema = "public",
	table = "users",
}
local _, columns = listed("columns", columns_context)
check("a column is listed by name alone, because its type is the hint", {
	columns[1].value,
	columns[1].text,
}, { "id", "id" })
check("a key column says so, after its type", columns[1].hint, "bigint PK NOT NULL")
check("a column with no flags is its type alone", columns[2].hint, "text")
check("a mongo field is hinted with how many documents have it", columns[3].hint, "array 42 docs")
check("and the whole record is kept, for the previewer to draw", columns[1].column.type, "bigint")

check("a column is the end of the walk", explorer.levels.columns.child(columns_context, columns[1]), nil)

schema.databases, schema.schemas = real.databases, real.schemas
schema.tables, schema.columns = real.tables, real.columns
check("the schema module is left as it was found", schema.columns == real.columns, true)

support.describe("explorer: a name written into the buffer the picker came from")

local origin = vim.api.nvim_create_buf(false, true)
vim.bo[origin].filetype = "sql"
vim.api.nvim_buf_set_lines(origin, 0, -1, false, { "select * from " })
vim.api.nvim_set_current_buf(origin)
local origin_win = vim.api.nvim_get_current_win()
vim.api.nvim_win_set_cursor(origin_win, { 1, 14 })
explorer.insert_name(origin_win, origin, '"public"."users"')
check(
	"the name lands where the cursor was",
	vim.api.nvim_buf_get_lines(origin, 0, 1, false)[1],
	'select * from "public"."users"'
)

-- The window may be showing something else by the time a name is chosen, and
-- putting the text into whatever is current would edit the wrong file.
local other = vim.api.nvim_create_buf(false, true)
vim.api.nvim_set_current_buf(other)
explorer.insert_name(origin_win, origin, " limit 10")
check(
	"a buffer no longer on screen still gets the name",
	vim.api.nvim_buf_get_lines(origin, 0, 1, false)[1],
	'select * from "public"."users" limit 10'
)
check("without being made current to do it", vim.api.nvim_get_current_buf(), other)
check("and the buffer that is on screen stays empty", vim.api.nvim_buf_get_lines(other, 0, -1, false), { "" })

vim.api.nvim_buf_delete(origin, { force = true })
vim.api.nvim_buf_delete(other, { force = true })

support.describe("explorer: the row that walks back out")

local rows = { { value = "users" }, { value = "orders" } }
check("the first level has nowhere to go back to", explorer.with_parent(rows, {}), rows)

local walked = explorer.with_parent(rows, { { level = "schemas", context = {} } })
check("below it, a row is added", #walked, #rows + 1)
check("at the top, which is where the cursor starts", walked[1].parent, true)
check("naming the level it returns to", walked[1].text, ".. Schemas")
check("and the real entries keep their order behind it", { walked[2].value, walked[3].value }, {
	"users",
	"orders",
})
-- Every action asks for a qualified name first, so this is the one guard that
-- keeps "a table called .." out of generated SQL.
check("it has no name to insert", explorer.qualified_name("tables", { connection = conn }, walked[1]), "")

support.describe("explorer: counts come from the sweep")

local counted = {
	{ name = "users", kind = "table", columns = { {}, {}, {} } },
	{ name = "active_users", kind = "view", columns = { {}, {} } },
	{ name = "audit", kind = "table" },
}
local real_tables, real_schemas = schema.tables, schema.schemas
schema.tables = function(_, _, _, callback)
	callback(counted, nil)
end
local _, sized = listed("tables", { connection = conn, catalog = "appdb", schema = "public" })
check("a table says how wide it is", sized[1].hint, "3 columns")
check("a view says both what it is and how wide", sized[2].hint, "view  2 columns")
check("and a table the sweep has no columns for says nothing", sized[3].hint, nil)

-- The schema level counts out of the snapshot on disk, which is the only place
-- that knows before you walk in.
local store = require("neogrip.schema.store")
local swept = { id = "__test_explorer_counts__", driver = "postgres", database = "appdb" }
store.save(swept, "appdb", {
	product = "test",
	schemas = {
		{ name = "public", tables = { { name = "users" }, { name = "orders" } } },
		{ name = "empty", tables = {} },
		{ name = "solo", tables = { { name = "only" } } },
	},
})
schema.schemas = function(_, _, callback)
	callback({ { name = "public" }, { name = "empty" }, { name = "solo" }, { name = "unswept" } }, nil)
end
local _, sized_schemas = listed("schemas", { connection = swept, catalog = "appdb" })
check("a swept schema says how many tables are in it", sized_schemas[1].hint, "2 tables")
check("an empty one says so rather than nothing", sized_schemas[2].hint, "0 tables")
check("one table reads as one table, not one tables", sized_schemas[3].hint, "1 table")
check("and one the sweep never saw says nothing at all", sized_schemas[4].hint, nil)
store.clear(swept)
schema.tables, schema.schemas = real_tables, real_schemas

support.describe("explorer: statements generated for a table")

local GENERATED = {
	{ name = "id", type = "bigint", nullable = false, is_pk = true, auto_increment = true },
	{ name = "email", type = "text", nullable = false },
	{ name = "search", type = "tsvector", nullable = true, generated = true },
}
local real_columns = schema.columns
schema.columns = function(_, _, _, callback)
	callback(GENERATED, nil)
end

local buffer = require("neogrip.buffer")
local real_new_query = buffer.new_query
buffer.new_query = function()
	return 0
end

local function generated(kind, column_records)
	local real_answer = schema.columns
	if column_records then
		schema.columns = function(_, _, _, callback)
			callback(column_records, nil)
		end
	end
	local text = nil
	explorer.open_statement(
		{ connection = conn, catalog = "appdb", schema = "public" },
		{
			value = "users",
		},
		kind,
		function(_, statement)
			text = statement
		end
	)
	schema.columns = real_answer
	return text or ""
end

local insert = generated("insert")
check("an insert names the table", insert:find('INSERT INTO "public"."users"', 1, true) ~= nil, true)
check("lists the column you have to supply", insert:find('"email"', 1, true) ~= nil, true)
check("skips the key the server writes itself", insert:find('"id"', 1, true), nil)
check("and the column the server computes", insert:find('"search"', 1, true), nil)
check("with a placeholder named after the column", insert:find(":email", 1, true) ~= nil, true)

local update = generated("update")
check("an update sets what you may change", update:find('"email" = :email', 1, true) ~= nil, true)
check("and comes with its key already in the WHERE", update:find('WHERE "id" = :id;', 1, true) ~= nil, true)

local delete = generated("delete")
check("a delete is keyed the same way", delete:find('DELETE FROM "public"."users"', 1, true) ~= nil, true)
check("and never arrives without a WHERE", delete:find('WHERE "id" = :id;', 1, true) ~= nil, true)

-- A table with no key is the dangerous case: the statement still comes, and it
-- says why it is not finished.
local keyless = generated("update", { { name = "email", type = "text" } })
check("without a key it says so first", keyless:find("^%-%- No primary key reported") ~= nil, true)
check("warning what an unqualified update would do", keyless:find("rewrites every row") ~= nil, true)
check("and leaves the WHERE empty rather than inventing one", keyless:find("WHERE ;", 1, true) ~= nil, true)

schema.columns = real_columns
buffer.new_query = real_new_query
check("the modules are left as they were found", schema.columns == real_columns, true)
