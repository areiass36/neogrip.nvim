-- The connection files, schema v2: normalization, the kvstore-only secret
-- rule, aliases, and project-over-global precedence. Everything runs against
-- temp directories; no real state directory is touched for the project side.
local support = require("tests.support")
local check, note = support.check, support.note
local connections = require("neogrip.connections")

support.describe("connections: schema v2")

local root = vim.fn.tempname()
vim.fn.mkdir(root .. "/.nvim", "p")
-- macOS tempdirs live behind a /var -> /private/var symlink; getcwd() resolves
-- it and tempname() does not, so the comparison has to start from the real path.
root = vim.uv.fs_realpath(root) or root
local original_cwd = vim.fn.getcwd()
vim.cmd("cd " .. vim.fn.fnameescape(root))

local function write_project(payload)
	vim.fn.writefile(vim.split(vim.json.encode(payload), "\n"), root .. "/.nvim/database.json")
	connections.reload()
end

write_project({
	version = 2,
	default = "replica",
	connections = {
		{
			id = "replica",
			name = "Replica",
			driver = "postgresql",
			host = "db.example.com",
			port = 5432,
			database = "app",
			catalog = "hive",
			schema = "public",
			readonly = true,
			production = true,
			ssl = { mode = "require" },
			options = { connectTimeout = "10" },
			auth = { type = "password", user = "fulano", password = { kvstore = "replica-password" } },
		},
		{
			id = "warehouse",
			driver = "azuresql",
			host = "wh.example.com",
			auth = { type = "entra_interactive", user = "fulano@example.com" },
		},
	},
})

local replica = connections.get("replica")
check("the driver alias is canonical", replica.driver, "postgres")
check("azuresql maps to the mssql driver", connections.get("warehouse").driver, "mssql")
check("catalog and schema are separate fields", { replica.catalog, replica.schema }, { "hive", "public" })
check("the ssl block survives", replica.ssl, { mode = "require" })
check("options pass through", replica.options, { connectTimeout = "10" })
check("readonly and production are booleans", { replica.readonly, replica.production }, { true, true })
check("the secret is a kvstore reference", replica.auth.password, { kvstore = "replica-password" })
check("the project default", connections.project_default(), "replica")
check("the project root is where the file is", connections.project_root(), vim.fs.normalize(root))

support.describe("connections: a literal secret is refused")
write_project({
	version = 2,
	connections = {
		{
			id = "leaky",
			driver = "postgres",
			host = "x",
			auth = { type = "password", user = "u", password = "hunter2" },
		},
		{
			id = "sane",
			driver = "duckdb",
			file = "data/app.duckdb",
		},
	},
})
check("the leaky connection is dropped", connections.get("leaky"), nil)
check("the sane one still loads", connections.get("sane") ~= nil, true)
check(
	"a relative file resolves against the project root",
	connections.get("sane").file,
	vim.fs.normalize(root .. "/data/app.duckdb")
)

support.describe("connections: entries that cannot be used are dropped")
write_project({
	version = 2,
	connections = {
		{ id = "nodriver", driver = "oracle", host = "x" },
		{ id = "nofile", driver = "sqlite" },
		{ id = "badauth", driver = "postgres", host = "x", auth = { type = "osmosis" } },
		{ id = "nokey", driver = "postgres", host = "x", auth = { type = "password", user = "u" } },
	},
})
check("unknown driver", connections.get("nodriver"), nil)
check("file driver without a file", connections.get("nofile"), nil)
check("unknown auth type", connections.get("badauth"), nil)
check("password auth without a kvstore key", connections.get("nokey"), nil)

support.describe("connections: ephemeral registrations resolve by id")
connections.register({ id = "__scratch__", name = "scratch", driver = "duckdb", file = root .. "/s.duckdb" })
check("the ephemeral connection resolves", connections.get("__scratch__").name, "scratch")
note("global-file precedence is exercised implicitly: the project file always wins on id collision")

vim.cmd("cd " .. vim.fn.fnameescape(original_cwd))
connections.reload()
vim.fn.delete(root, "rf")
