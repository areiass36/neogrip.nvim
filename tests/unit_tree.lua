-- The tree's shape, its ids and the statements it writes: everything that is
-- a function of what we know rather than of what a server answers (ADR-0036).
local support = require("tests.support")
local check = support.check
local tree = require("neogrip.tree")
local statement = require("neogrip.sql.statement")

support.describe("tree: the shape of every engine")

--- The level chain, as one string, so a disagreement reads at a glance.
local function chain(connection)
	local parts = {}
	for _, entry in ipairs(tree.shape(connection).levels) do
		parts[#parts + 1] = entry.level .. (entry.on_demand and "*" or "")
	end
	return table.concat(parts, "/")
end

-- SQLite is its own database and reports no schemas at all.
check("sqlite", chain({ driver = "sqlite", file = "/tmp/x.sqlite" }), "server/set/object*/attribute")
-- DuckDB is a file as well, but it does report schemas - and the sweep keys
-- its snapshot by them, so pretending otherwise sends a tree to the server for
-- what it already has.
check(
	"duckdb",
	chain({ driver = "duckdb", file = "/tmp/x.duckdb" }),
	"server/namespace/set/object*/attribute"
)

-- Databases but no schema layer; naming one skips the level that chooses it.
check("mysql", chain({ driver = "mysql" }), "server/instance/set/object*/attribute")
check("mysql with a database", chain({ driver = "mysql", database = "app" }), "server/set/object*/attribute")
check("mariadb", chain({ driver = "mariadb" }), "server/instance/set/object*/attribute")
check("mongodb", chain({ driver = "mongodb" }), "server/instance/set/object*/attribute")
check(
	"mongodb with a database",
	chain({ driver = "mongodb", database = "shop" }),
	"server/set/object*/attribute"
)

-- Both container levels, and the instance drops out once the connection names
-- the database it is pinned to.
check("postgres", chain({ driver = "postgres" }), "server/instance/namespace/set/object*/attribute")
check(
	"postgres with a database",
	chain({ driver = "postgres", database = "app" }),
	"server/namespace/set/object*/attribute"
)
check("mssql", chain({ driver = "mssql" }), "server/instance/namespace/set/object*/attribute")
check(
	"trino with a catalog",
	chain({ driver = "trino", catalog = "hive" }),
	"server/namespace/set/object*/attribute"
)

support.describe("tree: what each level is called")

local function labels(connection)
	local by_level = {}
	for _, entry in ipairs(tree.shape(connection).levels) do
		by_level[entry.level] = entry.label
	end
	return by_level
end

-- The label is what lets a client write one renderer and still say the word
-- the user's engine uses.
check("trino calls an instance a catalog", labels({ driver = "trino" }).instance, "Catalogs")
check("postgres calls it a database", labels({ driver = "postgres" }).instance, "Databases")
local mongo_labels = labels({ driver = "mongodb" })
check("mongo has collections, documents and fields", {
	mongo_labels.set,
	mongo_labels.object,
	mongo_labels.attribute,
}, { "Collections", "Documents", "Fields" })

support.describe("tree: what can be swept")

check("a relational catalog can", tree.shape({ driver = "postgres" }).sweepable, true)
-- A collection catalog cannot: its fields come from sampling (ADR-0029).
check("a collection catalog cannot", tree.shape({ driver = "mongodb" }).sweepable, false)
check("and a row is never cached", tree.shape({ driver = "postgres" }).cacheable_until, "attribute")

support.describe("tree: ids survive the names people actually use")

check(
	"a plain path",
	tree.id({ server = "pg", instance = "app", namespace = "public", set = "users" }),
	"pg/app/public/users"
)
-- The separator inside a name would read as another level, and two different
-- nodes would share one id.
check("a slash in a name", tree.id({ server = "pg", namespace = "public", set = "a/b" }), "pg/public/a%2Fb")
check("the escape itself", tree.id({ server = "pg", set = "100%" }), "pg/100%25")
check("a space and a quote", tree.id({ server = "pg", set = 'my "table"' }), 'pg/my "table"')
check("unicode is left alone", tree.id({ server = "pg", set = "日本語" }), "pg/日本語")
check(
	"two names that differ only by the escaping",
	tree.id({ server = "pg", set = "a/b" }) ~= tree.id({ server = "pg", namespace = "a", set = "b" }),
	true
)
check(
	"a column hangs off its set",
	tree.id({ server = "pg", namespace = "public", set = "users", attribute = "id" }),
	"pg/public/users/id"
)
-- A row has no identity but its position, and the id says so.
check(
	"a row is positional",
	tree.id({ server = "pg", namespace = "public", set = "users", object = 3 }),
	"pg/public/users/#3"
)

support.describe("tree: the statements it writes, and nothing it opens")

local pg = { driver = "postgres", database = "app" }
local columns = {
	{ name = "id", type = "integer", is_pk = true, auto_increment = true },
	{ name = "email", type = "text" },
	{ name = "created_at", type = "timestamptz", generated = true },
}

check(
	"select is the whole table",
	statement.for_set(pg, "public", "users", "select", columns),
	'SELECT * FROM "public"."users"'
)
-- A column the server writes itself is not one you supply.
check(
	"insert leaves out what the server fills in",
	statement.for_set(pg, "public", "users", "insert", columns),
	'INSERT INTO "public"."users" ("email")\nVALUES (:email);'
)
check(
	"update arrives with its WHERE written",
	statement.for_set(pg, "public", "users", "update", columns),
	'UPDATE "public"."users" SET\n    "email" = :email\nWHERE "id" = :id;'
)
check(
	"delete too",
	statement.for_set(pg, "public", "users", "delete", columns),
	'DELETE FROM "public"."users"\nWHERE "id" = :id;'
)

-- Nothing here is runnable on purpose: the values are placeholders, so a
-- statement that would rewrite a table cannot go off by accident.
check(
	"no statement is executable as written",
	statement.for_set(pg, "public", "users", "update", columns):find(":email", 1, true) ~= nil,
	true
)

-- Without a key there is no WHERE to write, and saying so beats a statement
-- that silently rewrites every row.
local keyless = { { name = "a", type = "int" }, { name = "b", type = "int" } }
check(
	"a table with no primary key is warned about",
	statement.for_set(pg, "public", "log", "delete", keyless):find("No primary key", 1, true) ~= nil,
	true
)

-- Quoting is the engine's, not ours: the same ref reads differently per driver.
check(
	"mysql quotes with backticks",
	statement.for_set({ driver = "mysql" }, "app", "users", "select", columns),
	"SELECT * FROM `app`.`users`"
)
check(
	"sql server with brackets",
	statement.for_set({ driver = "mssql" }, "dbo", "users", "select", columns),
	"SELECT * FROM [dbo].[users]"
)
check(
	"a collection is named the way mongo names one",
	statement.for_set({ driver = "mongodb" }, nil, "orders", "select", {}),
	"db.orders.find({})"
)

support.describe("tree: a name becomes SQL the way the engine spells it")

local connections = require("neogrip.connections")

-- qualified_name is the only door from a ref to SQL (ADR-0036), so every
-- dialect's quoting is asserted here rather than discovered by a generated
-- statement that fails on half the engines.
local DIALECTS = {
	{
		connection = { id = "u-pg", driver = "postgres", database = "app" },
		ref = { namespace = "public", set = "Order" },
		want = '"public"."Order"',
	},
	-- MySQL reports its database as a catalog and has no schema layer, so the
	-- database is what lands where every other engine puts its schema.
	{
		connection = { id = "u-my", driver = "mysql", database = "app" },
		ref = { set = "Order" },
		want = "`app`.`Order`",
	},
	{
		connection = { id = "u-maria", driver = "mariadb", database = "app" },
		ref = { set = "Order" },
		want = "`app`.`Order`",
	},
	{
		connection = { id = "u-ms", driver = "mssql", database = "app" },
		ref = { namespace = "dbo", set = "Order" },
		want = "[dbo].[Order]",
	},
	-- One file and no schema layer: qualifying would produce a name SQLite
	-- rejects, so the namespace in the ref is deliberately ignored.
	{
		connection = { id = "u-lite", driver = "sqlite", file = "/tmp/u.sqlite" },
		ref = { namespace = "main", set = "Order" },
		want = '"Order"',
	},
	{
		connection = { id = "u-duck", driver = "duckdb", file = "/tmp/u.duckdb" },
		ref = { namespace = "main", set = "Order" },
		want = '"main"."Order"',
	},
	-- A collection is addressed by its bare name; the db. prefix a statement
	-- needs belongs to the statement, not to the name.
	{
		connection = { id = "u-mongo", driver = "mongodb", database = "shop" },
		ref = { set = "orders" },
		want = "orders",
	},
}

for _, dialect in ipairs(DIALECTS) do
	connections.register(dialect.connection)
	local ref = vim.tbl_extend("force", dialect.ref, { server = dialect.connection.id })
	check(dialect.connection.driver, tree.qualified_name(ref), dialect.want)
end

-- The quote character inside the name is the case that produces broken SQL
-- silently: doubled it is a name, undoubled it is a syntax error.
check(
	"a quote in a name is doubled",
	tree.qualified_name({ server = "u-pg", namespace = "public", set = 'a"b' }),
	'"public"."a""b"'
)
check(
	"and a bracket is, in sql server",
	tree.qualified_name({ server = "u-ms", namespace = "dbo", set = "a]b" }),
	"[dbo].[a]]b]"
)
-- Case is never folded: two sets that differ only by it are two sets, and
-- each engine's own folding rules are its business, not the tree's.
check(
	"case is left exactly as it came",
	tree.qualified_name({ server = "u-pg", namespace = "public", set = "Users" }),
	'"public"."Users"'
)
check(
	"so two names differing only by case are two ids",
	tree.id({ server = "pg", set = "Users" }) ~= tree.id({ server = "pg", set = "users" }),
	true
)
check("a ref with no set has no name", tree.qualified_name({ server = "u-pg" }), nil)

support.describe("tree: one page of a listing, and what it says about the rest")

-- The paged path talks to the server directly, so the server is what is
-- faked. An in-process stub rather than tests/mock_gripd.lua, which is a
-- separate process speaking the wire for the rpc client's own suite: driving
-- the tree through that one would need a JDK and a connect, and this suite
-- touches neither (ADR-0023).
local gripd = require("neogrip.gripd")
local real_request = gripd.request
local asked, answer = nil, nil
gripd.request = function(_, method, params, callback)
	asked = { method = method, params = params }
	callback(answer, nil)
end

--- One synchronous page: the stub answers inline, so the nodes are back
--- before children() returns.
local function page_of(from, opts)
	local nodes, err, page = nil, nil, nil
	tree.children(
		from,
		vim.tbl_extend("force", opts, {
			on_page = function(continuation)
				page = continuation
			end,
		}),
		function(result, request_err)
			nodes, err = result, request_err
		end
	)
	return nodes, page, err
end

connections.register({ id = "u-pg2", driver = "postgres", database = "app" })

answer = {
	rows = {
		{ name = "accounts", kind = "table", remarks = "the ledger" },
		{ name = "audit", kind = "view" },
		-- No kind at all: a TABLE_TYPE the server never saw is a table, which
		-- is what "anything selectable that is not a view nor a collection"
		-- means in ADR-0036.
		{ name = "backlog" },
	},
	truncated = true,
}
local namespace_node = { level = "namespace", ref = { server = "u-pg2", namespace = "public" } }
local sets, sets_page = page_of(namespace_node, { limit = 3, pattern = "a" })

check("a page of sets is asked of the server", asked.method, "catalog/tables")
check("qualified by catalog and schema", { asked.params.catalog, asked.params.schema }, { "app", "public" })
check("carrying the page size and the pattern", { asked.params.limit, asked.params.pattern }, { 3, "a" })
check("the first page has no cursor", asked.params.after, nil)
check("every row came back as a node", #sets, 3)
check("at the set level", sets[1].level, "set")
check("the kind the server sent is the kind on the node", { sets[1].kind, sets[2].kind }, { "table", "view" })
check("and a row with no kind is a table", sets[3].kind, "table")
check("remarks ride along as a fact", sets[1].facts.remarks, "the ledger")
check("a node from the server says so", sets[1].source, "server")
check("its ref carries the whole path", {
	sets[1].ref.server,
	sets[1].ref.namespace,
	sets[1].ref.set,
}, { "u-pg2", "public", "accounts" })

-- The order is the server's (ADR-0036) and the tree must not touch it: the
-- keyset resumes from the last name received, which is only exact while the
-- order is the server's own and total.
check("the server's order is preserved", {
	sets[1].name,
	sets[2].name,
	sets[3].name,
}, { "accounts", "audit", "backlog" })

-- truncated on the wire is done = false to the client, and what is left in
-- the page is exactly the opts of the next call.
check("a cut page is not done", sets_page.done, false)
check("and resumes from the last name it sent", sets_page.after, "backlog")

answer = { rows = { { name = "customers", kind = "table" } } }
local rest, rest_page = page_of(namespace_node, vim.tbl_extend("force", { limit = 3 }, sets_page))
check("the cursor goes back to the server verbatim", asked.params.after, "backlog")
check("the last page answers what is left", #rest, 1)
-- No truncated field at all, rather than truncated = false: an absent field
-- is how the server says a page was not cut.
check("and says it is done", rest_page.done, true)
check("with the last name it sent", rest_page.after, "customers")

answer = { rows = {}, truncated = false }
local empty, empty_page = page_of(namespace_node, { limit = 3 })
check("an empty page is not an error", #empty, 0)
check("it is done", empty_page.done, true)
check("and has no cursor to offer", empty_page.after, nil)

-- The namespace level pages through its own listing, and nothing a table
-- listing needs leaks into it.
answer = { rows = { { name = "public" }, { name = "reporting" } }, truncated = true }
local schemas, schemas_page = page_of({ level = "server", ref = { server = "u-pg2" } }, { limit = 2 })
check("a page of namespaces has its own method", asked.method, "catalog/schemas")
check("qualified by catalog alone", { asked.params.catalog, asked.params.schema }, { "app", nil })
check("the nodes are namespaces", { schemas[1].level, schemas[1].kind }, { "namespace", "schema" })
check("and the page resumes by name too", schemas_page.after, "reporting")

-- The third listing. A warehouse has catalogs the way a database has tables,
-- so all three container levels page.
connections.register({ id = "u-pg3", driver = "postgres" })
answer = { rows = { { name = "app" }, { name = "reporting" } } }
local instances = page_of({ level = "server", ref = { server = "u-pg3" } }, { limit = 2 })
check("a page of instances has its own method", asked.method, "catalog/catalogs")
check("no catalog qualifies a listing of catalogs", asked.params.catalog, nil)
check("postgres calls one a database", instances[1].kind, "database")
check("and it reconnects to walk into it", instances[1].facts.reconnects, true)

connections.register({ id = "u-trino", driver = "trino" })
answer = { rows = { { name = "tpch" } } }
local catalogs = page_of({ level = "server", ref = { server = "u-trino" } }, { limit = 2 })
check("trino calls one a catalog", catalogs[1].kind, "catalog")
-- And walking into it is a longer name, not a new connection (ADR-0039).
check("which is not something you reconnect to", catalogs[1].facts.reconnects, nil)

-- Without limit or after the question is the other one: the whole schema in
-- one round trip, kept, which is what a tree wants for the hundreds of sets a
-- person actually browses.
asked = nil
answer = { rows = {} }
tree.children(namespace_node, {}, function() end)
check("no page asked for means no paged request", asked, nil)

support.describe("tree: row counts, where the engine has them")

answer = { counts = { accounts = 1200, audit = 0 } }
local counts = nil
tree.counts({ server = "u-pg2", namespace = "public" }, function(result)
	counts = result
end)
check("the estimates arrive by set name", counts, { accounts = 1200, audit = 0 })
check("asked of the namespace", { asked.method, asked.params.schema }, { "catalog/counts", "public" })

-- SQLite, DuckDB, Trino and MongoDB keep no cheap estimate, and the contract
-- is an empty map rather than an error or a count nobody asked to pay for.
answer = {}
tree.counts({ server = "u-pg2", namespace = "public" }, function(result)
	counts = result
end)
check("an engine with no estimate answers an empty map", counts, {})

-- A partial map is normal even where the engine does have estimates:
-- postgres leaves reltuples at -1 until something analyzes the table, and a
-- set that was never analyzed is simply absent.
answer = { counts = { accounts = 1200 } }
tree.counts({ server = "u-pg2", namespace = "public" }, function(result)
	counts = result
end)
check("a set with no estimate is absent, not zero", counts.audit, nil)
check("while the ones that have it are there", counts.accounts, 1200)

local counts_err = nil
gripd.request = function(_, _, _, callback)
	callback(nil, { code = -32010, message = "no such schema" })
end
tree.counts({ server = "u-pg2", namespace = "nope" }, function(result, err)
	counts, counts_err = result, err
end)
check("a server error is not swallowed", counts_err and counts_err.message, "no such schema")
check("and no map is invented", counts, nil)

-- The stub belongs to this module, not to the process: the live suites run
-- after it and need the real client back.
gripd.request = real_request
check("the real client is back in place", gripd.request == real_request, true)

support.describe("tree: the catalog is part of the name on trino only")

-- A SQL name has at most three parts and they are the tree's
-- instance.namespace.set (ADR-0039). Trino addresses catalogs in SQL and
-- queries across them in one session, so there the instance the ref carries is
-- part of the name; everywhere else the connection pins it and two parts are
-- the whole name.
connections.register({ id = "u-trino-free", driver = "trino" })
connections.register({ id = "u-trino-pinned", driver = "trino", database = "tpch" })

check(
	"trino qualifies with the catalog the ref carries",
	tree.qualified_name({
		server = "u-trino-free",
		instance = "tpch",
		namespace = "tiny",
		set = "nation",
	}),
	'"tpch"."tiny"."nation"'
)
check(
	"or with the one the connection names",
	tree.qualified_name({ server = "u-trino-pinned", namespace = "tiny", set = "nation" }),
	'"tpch"."tiny"."nation"'
)
-- With neither there is no third part to write. Two is then the best this can
-- do, and the session has to supply the rest.
check(
	"and with neither it can only say two",
	tree.qualified_name({ server = "u-trino-free", namespace = "tiny", set = "nation" }),
	'"tiny"."nation"'
)

-- The regression that matters: PostgreSQL cannot query across databases, so a
-- third part there is an error rather than a longer name.
check(
	"postgres gains no third part from its instance",
	tree.qualified_name({ server = "u-pg", instance = "app", namespace = "public", set = "users" }),
	'"public"."users"'
)
check(
	"nor does sql server",
	tree.qualified_name({ server = "u-ms", instance = "app", namespace = "dbo", set = "users" }),
	"[dbo].[users]"
)
-- MySQL already carries its database in the namespace slot, because the driver
-- reports it as a catalog and there is no schema layer under it.
check(
	"and mysql still names its database once",
	tree.qualified_name({ server = "u-my", instance = "app", set = "users" }),
	"`app`.`users`"
)

check(
	"the statement a ref writes carries the catalog too",
	statement.for_set({ driver = "trino" }, "tiny", "nation", "select", {}, "tpch"),
	'SELECT * FROM "tpch"."tiny"."nation"'
)
check(
	"in every kind, not just select",
	statement.for_set(
		{ driver = "trino" },
		"tiny",
		"nation",
		"delete",
		{ { name = "nationkey", type = "bigint", is_pk = true } },
		"tpch"
	),
	'DELETE FROM "tpch"."tiny"."nation"\nWHERE "nationkey" = :nationkey;'
)

support.describe("tree: which instances mean reopening the connection")

--- The instance level of this connection's shape, or nil when it has none.
local function instance_level(connection)
	for _, entry in ipairs(tree.shape(connection).levels) do
		if entry.level == "instance" then
			return entry
		end
	end
end

-- Nothing in the plugin acts on this flag: the client draws the explorer
-- (ADR-0037), so it is the only way it learns that walking into a database
-- needs a new connection rather than a longer name.
check("postgres reconnects to use another database", instance_level({ driver = "postgres" }).reconnects, true)
check("mysql too", instance_level({ driver = "mysql" }).reconnects, true)
check("and sql server too", instance_level({ driver = "mssql" }).reconnects, true)
-- Trino is why the flag is not simply implied by the level existing.
check("trino does not", instance_level({ driver = "trino" }).reconnects, nil)
