-- Connections come from two files and never contain a secret.
--
--   global:  stdpath("state")/neogrip/connections.json
--   project: <root>/.nvim/database.json, which also maps folders and globs to
--            a connection and names the project default
--
-- A project entry wins over a global one with the same id. Every secret is a
-- kvstore.nvim key name (ADR-0007): the file stores { "kvstore": "<key>" }
-- and a literal value is a hard error, so the file stays inert data.
--
-- Schema version 2 (ADR-0008): auth as an object, ssl as a block, catalog and
-- schema split from database, options passed through to the driver.
local neogrip = require("neogrip")

local M = {}

local DRIVERS = {
	postgres = true,
	mysql = true,
	mariadb = true,
	mssql = true,
	sqlite = true,
	duckdb = true,
	mongodb = true,
	trino = true,
}

-- Driver spellings people reasonably write, mapped to the canonical one.
-- Azure SQL is the mssql driver; its difference is the auth mode.
local DRIVER_ALIASES = {
	postgresql = "postgres",
	pg = "postgres",
	pgsql = "postgres",
	sqlserver = "mssql",
	tsql = "mssql",
	azuresql = "mssql",
	sqlite3 = "sqlite",
	mongo = "mongodb",
	presto = "trino",
}

local AUTH_TYPES = {
	none = true,
	password = true,
	entra_interactive = true,
	service_principal = true,
	managed_identity = true,
	token = true,
}

-- The fields of an auth object that hold a secret; each must be a kvstore
-- reference, never a literal.
local SECRET_FIELDS = { "password", "client_secret", "token", "passphrase" }

local PROJECT_FILE = ".nvim/database.json"
-- The predecessor's name, still read for one migration window.
local DEPRECATED_PROJECT_FILE = ".nvim/databases.json"

local cache = nil
local warned = {}
-- Connections that exist only for this session, such as the DuckDB scratch a
-- materialised result is queried through. They are not in any file, but a
-- buffer still has to be able to resolve one by id.
local ephemeral = {}

local function warn_once(key, message)
	if not warned[key] then
		warned[key] = true
		neogrip.notify(message, vim.log.levels.WARN)
	end
end

local function project_file_in(dir)
	if vim.fn.filereadable(dir .. "/" .. PROJECT_FILE) == 1 then
		return dir .. "/" .. PROJECT_FILE
	end
	if vim.fn.filereadable(dir .. "/" .. DEPRECATED_PROJECT_FILE) == 1 then
		warn_once(
			"deprecated-name",
			DEPRECATED_PROJECT_FILE .. " is the old name; rename it to " .. PROJECT_FILE
		)
		return dir .. "/" .. DEPRECATED_PROJECT_FILE
	end
	return nil
end

--- The nearest folder, from here upwards, that holds a connection file.
local function declared_root(cwd)
	if project_file_in(cwd) then
		return cwd
	end
	for dir in vim.fs.parents(cwd) do
		if project_file_in(dir) then
			return dir
		end
	end
	return nil
end

function M.project_root()
	local cwd = vim.fs.normalize(vim.fn.getcwd())
	-- A connection file outranks a .git, and is looked for above it: someone
	-- put it there on purpose. A workspace holding several repositories side
	-- by side - with no repository above them - can then declare its databases
	-- once, at the top; with the git root alone, opening nvim inside one of
	-- those repositories would look for the file there and find nothing.
	return declared_root(cwd) or vim.fs.root(cwd, ".git") or cwd
end

function M.global_file()
	return neogrip.state_dir .. "/connections.json"
end

function M.project_file()
	return project_file_in(M.project_root()) or (M.project_root() .. "/" .. PROJECT_FILE)
end

local function read_json(path)
	if vim.fn.filereadable(path) == 0 then
		return nil
	end
	local ok, lines = pcall(vim.fn.readfile, path)
	if not ok then
		return nil, "could not read " .. path
	end
	local decoded, data = pcall(vim.json.decode, table.concat(lines, "\n"))
	if not decoded or type(data) ~= "table" then
		return nil, ("%s is not valid JSON"):format(path)
	end
	return data
end

--- Expand a path the way a shell would, and resolve a relative one against the
--- project root so a project file can say "file": "db/app.sqlite".
local function resolve_file(path)
	if not path or path == "" then
		return nil
	end
	local expanded = vim.fn.expand(path)
	if
		vim.fn.fnamemodify(expanded, ":p") == expanded
		or expanded:match("^[/~]")
		or expanded:match("^%a:[/\\]")
	then
		return vim.fs.normalize(expanded)
	end
	return vim.fs.normalize(M.project_root() .. "/" .. expanded)
end

--- A secret field is a kvstore key reference and nothing else. A literal would
--- turn the file into a credential store, which is exactly what ADR-0007
--- forbids.
--- @return table|nil reference, string|nil error
local function normalize_secret(id, field, value)
	if value == nil then
		return nil, nil
	end
	if type(value) == "table" and type(value.kvstore) == "string" and value.kvstore ~= "" then
		return { kvstore = value.kvstore }
	end
	return nil,
		('connection %q: %s must be { "kvstore": "<key>" }; store the value first with :KVStore <key>'):format(
			id,
			field
		)
end

--- @return table|nil auth, string|nil error
local function normalize_auth(entry)
	local auth = entry.auth
	if auth == nil then
		return { type = "none" }
	end
	if type(auth) ~= "table" or type(auth.type) ~= "string" then
		return nil, ("connection %q: auth needs a type"):format(entry.id)
	end
	if not AUTH_TYPES[auth.type] then
		return nil, ("connection %q: unknown auth type %q"):format(entry.id, auth.type)
	end

	local normalized =
		{ type = auth.type, user = auth.user, client_id = auth.client_id, tenant = auth.tenant }
	for _, field in ipairs(SECRET_FIELDS) do
		local reference, err = normalize_secret(entry.id, "auth." .. field, auth[field])
		if err then
			return nil, err
		end
		normalized[field] = reference
	end
	if auth.type == "password" and not normalized.password then
		return nil, ("connection %q: auth.password must name a kvstore key"):format(entry.id)
	end
	return normalized
end

--- @return table|nil connection, string|nil error
local function normalize(entry, scope)
	if type(entry) ~= "table" then
		return nil, "connection entry is not an object"
	end
	if type(entry.id) ~= "string" or entry.id == "" then
		return nil, "connection without an id"
	end
	local driver = DRIVER_ALIASES[entry.driver] or entry.driver
	if not DRIVERS[driver] then
		return nil, ("connection %q has an unknown driver %q"):format(entry.id, tostring(entry.driver))
	end

	local auth, err = normalize_auth(entry)
	if not auth then
		return nil, err
	end

	local file = resolve_file(entry.file)
	if (driver == "sqlite" or driver == "duckdb") and not file then
		return nil, ("connection %q (%s) needs a file"):format(entry.id, driver)
	end

	-- Decoded JSON is whitelisted field by field into a fresh table, never
	-- passed through raw.
	return {
		id = entry.id,
		name = entry.name or entry.id,
		driver = driver,
		host = entry.host,
		port = entry.port,
		database = entry.database,
		catalog = entry.catalog,
		schema = entry.schema,
		file = file,
		auth = auth,
		ssl = type(entry.ssl) == "table" and entry.ssl or nil,
		options = entry.options or {},
		readonly = entry.readonly == true,
		production = entry.production == true,
		limit = entry.limit,
		timeout_ms = entry.timeout_ms,
		scope = scope,
	}
end

local function load_file(path, scope, into, order)
	local data, err = read_json(path)
	if err then
		warn_once("read:" .. path, err)
		return nil
	end
	if not data then
		return nil
	end
	if data.version ~= 2 then
		warn_once("version:" .. path, ("%s: expected schema version 2"):format(path))
	end
	for _, entry in ipairs(data.connections or {}) do
		local connection, entry_err = normalize(entry, scope)
		if connection then
			if into[connection.id] and into[connection.id].scope ~= scope then
				warn_once(
					"dup:" .. connection.id,
					("connection %q is defined twice; the project file wins"):format(connection.id)
				)
			elseif not into[connection.id] then
				order[#order + 1] = connection.id
			end
			into[connection.id] = connection
		else
			warn_once("entry:" .. path .. tostring(entry.id), entry_err)
		end
	end
	return data
end

--- Warn when the project file is not ignored by git. It holds hosts, user
--- names and kvstore key names: useful to a reader, and not something to push
--- by accident.
local function check_ignored(path)
	if vim.fn.filereadable(path) == 0 then
		return
	end
	vim.system(
		{ "git", "check-ignore", "-q", path },
		{ cwd = M.project_root() },
		vim.schedule_wrap(function(result)
			-- 0 is ignored, 1 is not, anything else means git could not answer
			-- - usually because this folder is not a repository at all, and
			-- then there is nothing to commit the file to.
			if result.code == 1 then
				warn_once("gitignore", PROJECT_FILE .. " is not gitignored; add '.nvim/' to .gitignore")
			end
		end)
	)
end

local function load()
	local by_id, order = {}, {}
	load_file(M.global_file(), "global", by_id, order)
	local project_path = M.project_file()
	local project = load_file(project_path, "project", by_id, order)
	check_ignored(project_path)

	local list = {}
	for _, id in ipairs(order) do
		list[#list + 1] = by_id[id]
	end
	-- Project connections first: they are the ones you want in a picker.
	table.sort(list, function(a, b)
		if a.scope ~= b.scope then
			return a.scope == "project"
		end
		return a.name < b.name
	end)

	cache = {
		by_id = by_id,
		list = list,
		default = project and project.default or nil,
		bindings = project and project.bindings or {},
	}
	return cache
end

function M.state()
	return cache or load()
end

--- @return table[] every connection, project ones first
function M.all()
	return M.state().list
end

--- @return table|nil
function M.get(id)
	if not id then
		return nil
	end
	return M.state().by_id[id] or ephemeral[id]
end

--- Make a connection resolvable by id without writing it to a file.
function M.register(connection)
	ephemeral[connection.id] = connection
	return connection
end

function M.project_default()
	return M.state().default
end

function M.project_bindings()
	return M.state().bindings
end

function M.reload()
	cache = nil
	warned = {}
	-- Buffers memoize the connection they resolved to; that answer may have changed.
	for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
		pcall(function()
			vim.b[bufnr].neogrip_connection = nil
		end)
	end
	return M.state()
end

--- Write a connection into the global file, replacing one with the same id.
function M.save_global(connection)
	local data = read_json(M.global_file()) or { version = 2, connections = {} }
	data.connections = data.connections or {}
	local replaced = false
	for index, entry in ipairs(data.connections) do
		if entry.id == connection.id then
			data.connections[index] = connection
			replaced = true
			break
		end
	end
	if not replaced then
		table.insert(data.connections, connection)
	end
	vim.fn.mkdir(neogrip.state_dir, "p")
	local ok = pcall(vim.fn.writefile, vim.split(vim.json.encode(data), "\n"), M.global_file())
	if ok then
		M.reload()
	end
	return ok
end

function M.setup()
	load()
	vim.api.nvim_create_autocmd("DirChanged", {
		group = vim.api.nvim_create_augroup("NeogripConnections", { clear = true }),
		callback = function()
			M.reload()
		end,
	})
end

return M
