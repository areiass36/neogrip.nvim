-- The JDBC urls. No server and no driver: this is string building, and the
-- shapes below are the ones a driver rejects when they are wrong.
local support = require("tests.support")
local check = support.check
local dsn = require("neogrip.dsn")

local function url(overrides)
	return dsn.build(vim.tbl_extend("force", { id = "t", driver = "postgres", options = {} }, overrides))
end

support.describe("dsn: trino")

check(
	"no catalog: no path at all, because an empty segment is rejected",
	url({ driver = "trino", host = "trino.example.com", port = 443 }),
	"jdbc:trino://trino.example.com:443?SSL=true"
)

check(
	"a catalog is the first path segment",
	url({ driver = "trino", host = "trino.example.com", port = 443, database = "deltalaketrusted" }),
	"jdbc:trino://trino.example.com:443/deltalaketrusted?SSL=true"
)

check(
	"a default schema is the second",
	url({
		driver = "trino",
		host = "trino.example.com",
		port = 443,
		database = "deltalaketrusted",
		default_schema = "receita_federal",
	}),
	"jdbc:trino://trino.example.com:443/deltalaketrusted/receita_federal?SSL=true"
)

check(
	"a schema without a catalog has nowhere to go, and is left out",
	url({ driver = "trino", host = "trino.example.com", port = 443, default_schema = "receita_federal" }),
	"jdbc:trino://trino.example.com:443?SSL=true"
)

check(
	"the default port is plain http",
	url({ driver = "trino", host = "127.0.0.1", database = "memory" }),
	"jdbc:trino://127.0.0.1:8080/memory"
)

check(
	"SSL stays off when asked, and options come through as the driver spells them",
	url({
		driver = "trino",
		host = "trino.example.com",
		port = 443,
		database = "hive",
		options = { SSL = "false", SSLVerification = "NONE" },
	}),
	"jdbc:trino://trino.example.com:443/hive?SSL=false&SSLVerification=NONE"
)

support.describe("dsn: the other engines")

check(
	"a local postgres is not asked to speak TLS",
	url({ host = "127.0.0.1", port = 5432, database = "app_dev" }),
	"jdbc:postgresql://127.0.0.1:5432/app_dev?sslmode=disable"
)

check(
	"a remote one is left to the driver's default",
	url({ host = "db.example.com", port = 5432, database = "app" }),
	"jdbc:postgresql://db.example.com:5432/app"
)

check(
	"sql server separates properties with semicolons",
	url({ driver = "mssql", host = "sql.example.com", database = "DW" }),
	"jdbc:sqlserver://sql.example.com:1433;databaseName=DW;encrypt=false"
)

check("an unknown driver has no url", url({ driver = "nosuchdb", host = "h" }), nil)

support.describe("dsn: properties the url cannot carry")

local function properties(overrides)
	return dsn.properties(vim.tbl_extend("force", { id = "t", driver = "postgres" }, overrides))
end

check(
	"a trino option stays in the url only -- the driver rejects it in both",
	properties({ driver = "trino", options = { SSL = "true", SSLVerification = "NONE" } }),
	{}
)

check(
	"so does a postgres one",
	properties({ options = { sslmode = "require", ApplicationName = "nvim" } }),
	{}
)

check(
	"a sqlite url is a bare path, so its options have nowhere else to go",
	properties({ driver = "sqlite", file = "/tmp/app.db", options = { open_mode = "1" } }),
	{ open_mode = "1" }
)

check(
	"and a duckdb one likewise",
	properties({ driver = "duckdb", file = "/tmp/app.duckdb", options = { access_mode = "READ_ONLY" } }),
	{ access_mode = "READ_ONLY" }
)

check("no options at all is empty, not nil", properties({ driver = "sqlite", file = "/tmp/a.db" }), {})
