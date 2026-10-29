-- The swept catalog, on disk and read back. No server, no Java process and no
-- driver: every answer below comes out of a file this suite writes itself, in
-- the shape the Java side writes it.
local support = require("tests.support")
local check = support.check
local store = require("neogrip.schema.store")
local schema = require("neogrip.schema")

-- Ids no real connection can have, because the suite deletes every catalog
-- file it finds under them and those sit next to a developer's own snapshots.
local CONNECTION = { id = "__test_store__", driver = "postgres" }
local OTHER = { id = "__test_store_other__", driver = "postgres" }
local CATALOG = "appdb"

local function snapshot()
	return {
		at = os.time() - 90,
		product = "PostgreSQL 16.2",
		parallel = true,
		partial = true,
		schemas = {
			{
				name = "public",
				tables = {
					{
						name = "users",
						kind = "table",
						columns = {
							{ name = "id", type = "bigint", nullable = false, is_pk = true },
							{ name = "email", type = "varchar(255)", nullable = false },
						},
						primary_key = { "id" },
						indexes = { { name = "users_pkey", unique = true, columns = { "id" } } },
						foreign_keys = {},
						referenced_by = {
							{
								name = "orders_user_fk",
								schema = "public",
								table = "orders",
								columns = { "id" },
								ref_columns = { "user_id" },
							},
						},
						details = true,
					},
					{
						name = "orders_v",
						kind = "view",
						columns = { { name = "total", type = "numeric", nullable = true } },
						primary_key = {},
						indexes = {},
						foreign_keys = {},
						referenced_by = {},
						-- The detail pass spent its budget before reaching this
						-- one, which is what `partial` above records.
						details = false,
					},
				},
			},
			{ name = "audit", tables = {} },
		},
	}
end

--- A fresh snapshot on disk, with nothing remembered from an earlier group.
local function saved()
	store.clear(CONNECTION)
	return (store.save(CONNECTION, CATALOG, snapshot()))
end

support.describe("store: where a catalog is kept")

check(
	"the same connection and catalog always name the same file",
	store.path(CONNECTION, CATALOG),
	store.path(CONNECTION, CATALOG)
)
check(
	"another catalog of the same connection is another file",
	store.path(CONNECTION, CATALOG) ~= store.path(CONNECTION, "warehouse"),
	true
)
check(
	"and the same catalog on another connection likewise",
	store.path(CONNECTION, CATALOG) ~= store.path(OTHER, CATALOG),
	true
)

support.describe("store: the round trip")

check("a snapshot is written", saved(), true)
local reread = store.load(CONNECTION, CATALOG)
check("and reads back with both of its schemas", reread and #reread.schemas, 2)
check("the server's own version string survives", reread.product, "PostgreSQL 16.2")
check("so does the catalog it was taken for", reread.catalog, CATALOG)

-- Decoding a catalog is megabytes of JSON, so the decoded copy is kept for the
-- session: deleting the file underneath it must not change any answer.
vim.fn.delete(store.path(CONNECTION, CATALOG))
check("a second load does not go back to the file", store.load(CONNECTION, CATALOG) ~= nil, true)
check("only reload does, and then there is nothing there", store.reload(CONNECTION, CATALOG), nil)

support.describe("store: answering out of the snapshot")

saved()
check(
	"the schemas are listed in the order they were swept",
	store.schemas(CONNECTION, CATALOG),
	{ { name = "public" }, { name = "audit" } }
)

local tables = store.tables(CONNECTION, CATALOG, "public")
check("a schema's tables come back whole", #tables, 2)
check("each knowing what kind of thing it is", { tables[1].kind, tables[2].kind }, { "table", "view" })
check(
	"a table's columns are named in order",
	vim.tbl_map(function(column)
		return column.name
	end, store.columns(CONNECTION, CATALOG, "public", "users")),
	{ "id", "email" }
)

local details = store.details(CONNECTION, CATALOG, "public", "users")
-- db/explorer/detail.lua renders details.rows, so the column list has to arrive
-- under that name rather than as `columns`.
check("a definition carries its column list as rows", #details.rows, 2)
check("the primary key is spelled out", details.primary_key, { "id" })
check("the indexes come with it", details.indexes[1].name, "users_pkey")
check("no outbound key is invented", details.foreign_keys, {})
check("and the keys pointing back at it are there too", details.referenced_by[1].table, "orders")

support.describe("store: a table the detail pass did not reach")

check("its definition is not known", store.details(CONNECTION, CATALOG, "public", "orders_v"), nil)
check("while its columns still are", #store.columns(CONNECTION, CATALOG, "public", "orders_v"), 1)
check(
	"a definition fetched from the server is folded in",
	store.merge_details(CONNECTION, CATALOG, "public", "orders_v", {
		rows = { { name = "total", type = "numeric", nullable = true } },
		primary_key = {},
		indexes = {},
		foreign_keys = {},
		referenced_by = {},
	}),
	true
)
check(
	"after which the table answers like any other",
	store.details(CONNECTION, CATALOG, "public", "orders_v") ~= nil,
	true
)
check(
	"a table the snapshot never had cannot be filled in",
	store.merge_details(CONNECTION, CATALOG, "public", "nosuch", { rows = {} }),
	false
)

support.describe("store: what is not in the snapshot")

check("an unknown schema has no tables", store.tables(CONNECTION, CATALOG, "nosuch"), nil)
check("an unknown table has no columns", store.columns(CONNECTION, CATALOG, "public", "nosuch"), nil)
check("nor a definition", store.details(CONNECTION, CATALOG, "public", "nosuch"), nil)
check("a catalog that was never swept has no schemas", store.schemas(CONNECTION, "nosuch"), nil)
check(
	"and a schema the sweep found empty answers with no tables rather than nothing",
	store.tables(CONNECTION, CATALOG, "audit"),
	{}
)

support.describe("store: an engine with no schemas")

-- SQLite and DuckDB have no schema level, so the sweep writes one nameless
-- schema and the caller asks for tables without naming one. Both sides have to
-- land on the same key or nothing is ever found.
store.clear(OTHER)
store.save(OTHER, nil, {
	at = os.time(),
	schemas = {
		{
			name = "",
			tables = {
				{
					name = "t_main",
					kind = "table",
					columns = { { name = "rowid", type = "integer", nullable = false, is_pk = true } },
					primary_key = { "rowid" },
					details = true,
				},
			},
		},
	},
})

check("the one schema is nameless", store.schemas(OTHER, nil), { { name = "" } })
check("a caller naming no schema still finds its tables", store.tables(OTHER, nil, nil)[1].name, "t_main")
check("and its columns", store.columns(OTHER, nil, nil, "t_main")[1].name, "rowid")
check("and its definition", store.details(OTHER, nil, nil, "t_main").primary_key, { "rowid" })

support.describe("store: what :DbDoctor reports")

saved()
local stat = store.stat(CONNECTION, CATALOG)
check(
	"the counts are over the whole catalog",
	{ stat.schemas, stat.tables, stat.columns, stat.details },
	{ 2, 2, 3, 1 }
)
check("the sweep is dated, in seconds since it ran", stat.age_seconds >= 90, true)
check("the product string is carried through", stat.product, "PostgreSQL 16.2")
check("so is the sweep having used more than one connection", stat.parallel, true)
check("and its having run out of its detail budget", stat.partial, true)
check("the file it names is the one it read", stat.path, store.path(CONNECTION, CATALOG))
check("nothing swept reports as nothing, not as zeroes", store.stat(OTHER, "never-swept"), nil)

support.describe("store: dropping one connection's catalogs")

saved()
store.save(OTHER, CATALOG, snapshot())
check("both connections have a file", {
	vim.fn.filereadable(store.path(CONNECTION, CATALOG)),
	vim.fn.filereadable(store.path(OTHER, CATALOG)),
}, { 1, 1 })

store.clear(CONNECTION)
check("clearing one deletes its file", vim.fn.filereadable(store.path(CONNECTION, CATALOG)), 0)
check("and forgets the decoded copy as well", store.load(CONNECTION, CATALOG), nil)
check("the other connection's snapshot is left alone", store.load(OTHER, CATALOG) ~= nil, true)
store.clear(OTHER)

support.describe("store: a file that is not a snapshot")

-- A half-written or hand-edited file is not worth a traceback: the explorer
-- falls back to asking the server, which is what it did before any of this.
local path = store.path(CONNECTION, CATALOG)
vim.fn.writefile({ "this is not json, it is a sentence" }, path)
check("a file that will not decode reads as no snapshot", store.reload(CONNECTION, CATALOG), nil)
vim.fn.writefile({ '{"at":1,"product":"something else entirely"}' }, path)
check("and so does one that decodes to the wrong document", store.reload(CONNECTION, CATALOG), nil)

support.describe("store: db.schema answers from the snapshot without a server")

saved()

--- Drive one of db.schema's callback functions and insist it answered before it
--- returned. A round trip would reach db.jvm, which has no process here.
local function answered(start)
	local records, failure, called = nil, nil, false
	start(function(list, err)
		records, failure, called = list, err, true
	end)
	return called, records, failure
end

local schemas_called, schemas_list, schemas_err = answered(function(done)
	schema.schemas(CONNECTION, CATALOG, done)
end)
check("schemas are answered without leaving the editor", schemas_called, true)
check("with no error", schemas_err, nil)
check("and name every schema of the snapshot", schemas_list, { { name = "public" }, { name = "audit" } })

local tables_called, tables_list, tables_err = answered(function(done)
	schema.tables(CONNECTION, "public", nil, done, CATALOG)
end)
check("tables are answered the same way", tables_called, true)
check("with no error", tables_err, nil)
check("naming both of the schema's tables", #tables_list, 2)

local columns_called, columns_list, columns_err = answered(function(done)
	schema.columns(CONNECTION, "public", "users", done, CATALOG)
end)
check("so are a table's columns", columns_called, true)
check("with no error", columns_err, nil)
check("carrying the types the sweep recorded", columns_list[1].type, "bigint")

local ready = schema.details_ready(CONNECTION, CATALOG, "public", "users")
check("a definition the sweep took is ready for the previewer", ready ~= nil, true)
check("and it is the one out of the snapshot", ready.primary_key, { "id" })
check(
	"a table the detail pass skipped is not ready, so the previewer asks",
	schema.details_ready(CONNECTION, CATALOG, "public", "orders_v"),
	nil
)

store.clear(CONNECTION)
store.clear(OTHER)
check("the suite leaves nothing behind", {
	vim.fn.filereadable(store.path(CONNECTION, CATALOG)),
	vim.fn.filereadable(store.path(OTHER, CATALOG)),
}, { 0, 0 })
