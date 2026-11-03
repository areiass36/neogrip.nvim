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

-- A file is its own database and has nothing above the tables.
check("sqlite", chain({ driver = "sqlite", file = "/tmp/x.sqlite" }), "server/set/object*/attribute")
check("duckdb", chain({ driver = "duckdb", file = "/tmp/x.duckdb" }), "server/set/object*/attribute")

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
