-- Walking the schema explorer, level by level, and the three actions on an
-- entry. The levels are driven directly rather than through keystrokes: what is
-- worth testing is the tree and what each action produces, not Telescope.
--
-- The walk starts where M.entry_point puts it, which is the explorer's whole
-- contract: it opens on the database the buffer runs against, not on a list of
-- every connection configured.
local support = require("tests.support")
local check, note = support.check, support.note

if not support.has_jdk() then
	support.describe("live/explorer")
	note("skipped: no JDK available (set NEOGRIP_TEST_JDK)")
	return
end
support.seed_secrets()
local explorer = require("neogrip.explorer")

local connections = support.connections()
local pg = connections.postgres

support.describe("explorer: the tree")
if not support.reachable(pg) then
	note("skipped: nothing listening (tests/containers.sh up)")
	return
end

local connections_module = require("neogrip.connections")
local saved_all, saved_get = connections_module.all, connections_module.get
connections_module.all = function()
	return { pg, connections.duckdb, connections.mongodb }
end
connections_module.get = function(id)
	for _, connection in pairs(connections) do
		if connection.id == id then
			return connection
		end
	end
	return saved_get(id)
end

local function load(level, context)
	local entries, err = support.sync(function(done)
		explorer.levels[level].load(context, function(list, error_)
			done(list, error_)
		end)
	end)
	return entries, err
end

local function entry_named(entries, name)
	for _, entry in ipairs(entries or {}) do
		if tostring(entry.value) == name or (type(entry.value) == "table" and entry.value.id == name) then
			return entry
		end
	end
	return nil
end

-- the entry point: this connection names its database, so there is nothing to
-- choose above it and the walk starts at its schemas
local start = explorer.entry_point(pg)
check("a connection that names its database starts at its schemas", start.level, "schemas")
check("carried as the catalog, which is what filters the metadata", start.context.catalog, "testdb")
local level, context = start.level, start.context
local entries, err = load(level, context)
check("schemas load", err, nil)
check("public is listed", entry_named(entries, "public") ~= nil, true)
check(
	"and wears the folder icon, so the level is readable without the title",
	entry_named(entries, "public").text:find(require("neogrip.icons").folder, 1, true) ~= nil,
	true
)

-- The database level is still there for a connection that does not name one,
-- which is how Trino's catalogs are reached. Only where it starts is asked of
-- an unnamed connection: a postgres driver given no database falls back to the
-- user name as the database and cannot connect at all, so the level itself is
-- loaded through the connection that does name one.
local anywhere = vim.deepcopy(pg)
anywhere.database = nil
check("without a database it starts a level higher", explorer.entry_point(anywhere).level, "databases")
local database_entries, database_err = load("databases", { connection = pg })
check("databases load", database_err, nil)
check("testdb is listed", entry_named(database_entries, "testdb") ~= nil, true)
check(
	"and wears the database icon",
	entry_named(database_entries, "testdb").text:find(require("neogrip.icons").database, 1, true) ~= nil,
	true
)
local chosen = explorer.levels.databases.child({ connection = pg }, entry_named(database_entries, "testdb"))
check("choosing one re-enters the tree at the schema level", chosen.level, "schemas")
check("with the connection now pointed at it", chosen.context.connection.database, "testdb")
check("and the catalog set from it", chosen.context.catalog, "testdb")

local entry, child

-- schemas -> tables
entry = entry_named(entries, "public")
child = explorer.levels[level].child(context, entry)
check("then tables", child.level, "tables")
level, context = child.level, child.context
entries, err = load(level, context)
check("tables load", err, nil)
entry = entry_named(entries, "torture")
check("torture is listed", entry ~= nil, true)
check("its kind is known", entry.kind, "table")

-- tables -> columns
child = explorer.levels[level].child(context, entry)
check("then columns", child.level, "columns")
check("the table is carried into it", child.context.table, "torture")
local table_context, table_entry = context, entry
local column_entries = load(child.level, child.context)
check("columns load", #column_entries > 0, true)
local id_column = entry_named(column_entries, "id")
check("the primary key is flagged in the hint", id_column.hint:find("PK") ~= nil, true)
local numeric_column = entry_named(column_entries, "n")
check("the type is in the hint", numeric_column.hint:find("numeric") ~= nil, true)
check("columns are the deepest level", explorer.levels.columns.child(child.context, id_column), nil)

support.describe("explorer: every engine starts where it has something to show")
check("sqlite has neither catalogs nor schemas", explorer.entry_point(connections.sqlite).level, "tables")
check("nor duckdb", explorer.entry_point(connections.duckdb).level, "tables")
check(
	"mongo names its database, so it opens on the collections",
	explorer.entry_point(connections.mongodb).level,
	"tables"
)
check(
	"and that database is the schema the collections are asked for",
	explorer.entry_point(connections.mongodb).context.schema,
	connections.mongodb.database
)
local anonymous_mongo = vim.deepcopy(connections.mongodb)
anonymous_mongo.database = nil
check("without one it asks which", explorer.entry_point(anonymous_mongo).level, "databases")
check(
	"and a mongo database leads to collections",
	explorer.levels.databases.child({ connection = anonymous_mongo }, { value = "shop" }).level,
	"tables"
)

support.describe("explorer: the name an entry contributes")
check(
	"a table is schema-qualified and quoted",
	explorer.qualified_name("tables", table_context, table_entry),
	'"public"."torture"'
)
check("a column is just quoted", explorer.qualified_name("columns", child.context, id_column), '"id"')
check(
	"sql server uses brackets",
	explorer.qualified_name(
		"tables",
		{ connection = connections.mssql, schema = "dbo" },
		{ value = "torture" }
	),
	"[dbo].[torture]"
)
check(
	"mysql uses backticks",
	explorer.qualified_name(
		"tables",
		{ connection = connections.mysql, schema = "testdb" },
		{ value = "torture" }
	),
	"`testdb`.`torture`"
)

support.describe("explorer: <C-s> opens a runnable select")
local query_buf, query_text = support.sync(function(done)
	explorer.open_select(table_context, table_entry, function(bufnr, text)
		done(bufnr, text)
	end)
end)
check("a buffer was opened", query_buf ~= nil, true)
check("it is a sql buffer", vim.bo[query_buf].filetype, "sql")
check("bound to the right connection", require("neogrip.resolve").for_buf(query_buf).id, pg.id)
note("select: " .. tostring(query_text))
check("the statement is limited", query_text:find("LIMIT") ~= nil, true)
check("and selects every column", query_text:find("SELECT %*") ~= nil, true)
local result, run_err = support.run(pg, (query_text:gsub(";%s*$", "")), { limit = 10 })
check("and it runs", run_err, nil)
check("returning rows", #result.rows, 2)

support.describe("explorer: <C-y> writes into the buffer it was opened from")
local origin = vim.api.nvim_create_buf(false, true)
vim.bo[origin].filetype = "sql"
vim.api.nvim_buf_set_lines(origin, 0, -1, false, { "select * from " })
vim.api.nvim_set_current_buf(origin)
local origin_win = vim.api.nvim_get_current_win()
vim.api.nvim_win_set_cursor(origin_win, { 1, 14 })
explorer.insert_name(origin_win, origin, '"public"."torture"')
check(
	"the name lands in the original buffer",
	vim.api.nvim_buf_get_lines(origin, 0, 1, false)[1],
	'select * from "public"."torture"'
)

-- And when that window is showing something else by then, the buffer still gets
-- the text and the other buffer stays untouched.
local other = vim.api.nvim_create_buf(false, true)
vim.api.nvim_set_current_buf(other)
explorer.insert_name(origin_win, origin, " x")
check(
	"still the original buffer",
	vim.api.nvim_buf_get_lines(origin, 0, 1, false)[1]:find(" x$") ~= nil,
	true
)
check("and the other buffer is untouched", vim.api.nvim_buf_get_lines(other, 0, -1, false), { "" })

support.describe("explorer: <C-d> shows a definition")
local windows_before = #vim.api.nvim_list_wins()
local ddl_lines = support.sync(function(done)
	explorer.show_ddl(table_context, table_entry, function(lines)
		done(lines)
	end)
end)
check("something was rendered", #ddl_lines > 0, true)
local joined = table.concat(ddl_lines, "\n")
check("naming the columns", joined:find("s_comma") ~= nil, true)
check("and the primary key", joined:find("PRIMARY KEY") ~= nil, true)
note("ddl first line: " .. tostring(ddl_lines[1]))
check("it opened in this window rather than splitting it", #vim.api.nvim_list_wins(), windows_before)
check(
	"and this window is showing it",
	vim.api.nvim_buf_get_name(vim.api.nvim_get_current_buf()):find("neogrip://table/", 1, true) ~= nil,
	true
)
-- Again, to prove the window is reused: the complaint that started this was a
-- new split stacking up on every visit.
support.sync(function(done)
	explorer.show_ddl(table_context, table_entry, function(lines)
		done(lines)
	end)
end)
check("twice is still one window", #vim.api.nvim_list_wins(), windows_before)

support.describe("explorer: the previewer's contents")
local preview = require("neogrip.explorer.preview")
local preview_buf = vim.api.nvim_create_buf(false, true)

local table_lines = support.sync(function(done)
	preview.render("tables", table_context, table_entry, preview_buf, done)
end, 30000)
local table_text = table.concat(table_lines, "\n")
check("a table shows its columns", table_text:find("s_comma") ~= nil, true)
check("with types", table_text:find("numeric") ~= nil, true)
-- The preview is the definition, not a summary of it: resting on a table and
-- opening it have to say the same thing, or one of them is a lie.
check("as a definition", table_text:find("CREATE TABLE") ~= nil, true)
check("with the primary key as a constraint", table_text:find("PRIMARY KEY") ~= nil, true)
check(
	"the same lines pressing <CR> would open",
	table_text,
	table.concat(
		require("neogrip.explorer.detail").render(
			pg,
			table_context,
			table_entry.value,
			support.sync(function(done)
				require("neogrip.schema").details(
					pg,
					table_context.schema,
					table_entry.value,
					function(details)
						done(details)
					end,
					table_context.catalog
				)
			end)
		),
		"\n"
	)
)
check(
	"and no rows: a sample is a query against every table the cursor touches",
	table_text:find("-- Sample", 1, true),
	nil
)
note("preview tail: " .. tostring(table_lines[#table_lines]))

-- Still available for whoever wants to pay for it.
local config = require("neogrip.config")
config.setup({ preview_sample = true })
local sampled = support.sync(function(done)
	preview.render("tables", table_context, table_entry, preview_buf, done)
end, 30000)
local sampled_text = table.concat(sampled, "\n")
check("turned on, the sample comes back", sampled_text:find("-- Sample", 1, true) ~= nil, true)
local create_at = sampled_text:find("CREATE TABLE")
local sample_at = sampled_text:find("-- Sample", 1, true)
check("below the definition", create_at ~= nil and sample_at ~= nil and create_at < sample_at, true)
check("with real values in it", sampled_text:find("a,b", 1, true) ~= nil, true)
config.setup({})
config.reload()

local column_lines = support.sync(function(done)
	preview.render("columns", child.context, numeric_column, preview_buf, done)
end)
check("a column shows its type", table.concat(column_lines, "\n"):find("numeric%(10,2%)") ~= nil, true)

connections_module.all, connections_module.get = saved_all, saved_get
