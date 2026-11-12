-- The Java side asks JDBC's DatabaseMetaData; this is only a cache in front of it. store.lua
-- holds a whole swept catalog and is asked first; what is left here is the per-question cache
-- that fills in as you walk.
local config = require("neogrip.config")
local paths = require("neogrip.paths")
local gripd = require("neogrip.gripd")
local runner = require("neogrip.gripd.runner")
local store = require("neogrip.catalog.store")

local M = {}

local QUOTE = {
	mysql = "`",
	mariadb = "`",
	mssql = "[",
	mongodb = "",
}

local memory = {}

--- Quote an identifier the way this engine expects.
function M.quote(driver, name)
	local style = QUOTE[driver]
	if style == "" then
		return tostring(name)
	end
	if style == "[" then
		return "[" .. tostring(name):gsub("%]", "]]") .. "]"
	end
	if style == "`" then
		return "`" .. tostring(name):gsub("`", "``") .. "`"
	end
	return '"' .. tostring(name):gsub('"', '""') .. '"'
end

--- Only Trino addresses catalogs in SQL and queries across them in one session (ADR-0039);
--- PostgreSQL cannot query across databases and MySQL's database travels in the namespace slot.
local function catalog_in_name(driver)
	return driver == "trino"
end

--- schema.table, quoted; `catalog` is optional and last so callers that rebuild SQL from a
--- result are unchanged, and absent, the connection's own catalog stands in.
function M.qualify(connection, schema, table_name, catalog)
	if connection.driver == "mongodb" then
		return tostring(table_name)
	end
	local quoted = M.quote(connection.driver, table_name)
	if schema and schema ~= "" and connection.driver ~= "sqlite" then
		quoted = M.quote(connection.driver, schema) .. "." .. quoted
		if catalog_in_name(connection.driver) then
			local named = catalog
			if named == nil or named == "" then
				named = M.catalog_of(connection)
			end
			if named ~= nil and named ~= "" then
				quoted = M.quote(connection.driver, named) .. "." .. quoted
			end
		end
	end
	return quoted
end

--- The catalog a connection means, and the key its swept catalog is kept under: one definition
--- because the tree, the sweep and the store must agree - in the predecessor, completion asked
--- with no catalog and never once read the sweep.
--- @return string|nil
function M.catalog_of(connection)
	local driver = connection.driver
	if
		driver == "sqlite"
		or driver == "duckdb"
		or driver == "mysql"
		or driver == "mariadb"
		or driver == "mongodb"
	then
		-- Their one database is a schema to the metadata calls; catalog is not what filters them.
		return nil
	end
	if connection.catalog and connection.catalog ~= "" then
		return connection.catalog
	end
	if connection.database == nil or connection.database == "" then
		return nil
	end
	return connection.database
end

local function cache_path(connection)
	local dir = paths.state_dir .. "/cache"
	vim.fn.mkdir(dir, "p")
	return ("%s/%s.json"):format(dir, vim.fn.sha256(connection.id))
end

local function cache_get(connection, key)
	local answers = memory[connection.id]
	if not answers then
		answers = {}
		local path = cache_path(connection)
		if vim.fn.filereadable(path) == 1 then
			local ok, lines = pcall(vim.fn.readfile, path)
			if ok then
				local decoded, data = pcall(vim.json.decode, table.concat(lines, "\n"))
				if decoded and type(data) == "table" then
					answers = data
				end
			end
		end
		memory[connection.id] = answers
	end
	local entry = answers[key]
	if not entry or (os.time() - (entry.at or 0)) > config.get().schema_ttl_seconds then
		return nil
	end
	return entry.value
end

local function cache_put(connection, key, value)
	memory[connection.id] = memory[connection.id] or {}
	memory[connection.id][key] = { at = os.time(), value = value }
	pcall(vim.fn.writefile, { vim.json.encode(memory[connection.id]) }, cache_path(connection))
end

--- Forget everything, the swept catalog included: "reload" must mean all of it, or the stale
--- half keeps answering.
function M.invalidate(connection)
	if connection then
		memory[connection.id] = nil
		pcall(vim.fn.delete, cache_path(connection))
	else
		memory = {}
		pcall(vim.fn.delete, paths.state_dir .. "/cache", "rf")
	end
	store.clear(connection)
end

--- Ensure the process is up: a catalog question bypasses the statement queue, so a trivial
--- query opens the process first; re-pointed at another database counts as not connected.
--- @param callback fun(err: string|nil)
local function connected(connection, callback)
	if gripd.is_connected_to(connection) then
		return callback(nil)
	end
	runner.run({
		connection = connection,
		sql = connection.driver == "mongodb" and "db.getCollectionNames()" or "select 1",
		mode = "query",
		limit = 1,
		background = true,
	}, function(_, err)
		if err and not gripd.is_connected(connection.id) then
			return callback(err.message)
		end
		callback(nil)
	end)
end

--- Ask gripd a catalog question; `whole` keeps the entire answer, because details do not fit the rows shape.
local function ask(connection, method, params, key, callback, whole)
	if key then
		local cached = cache_get(connection, key)
		if cached then
			return callback(cached, nil)
		end
	end

	local function send()
		gripd.request(connection, method, params, function(result, err)
			if err then
				return callback(nil, err.message or "catalog lookup failed")
			end
			local value
			if whole then
				-- Named rather than copied wholesale so a stray protocol field cannot become
				-- editor state; every field the renderer draws has to be here.
				value = {
					rows = result.rows or {},
					primary_key = result.primary_key or {},
					primary_key_name = result.primary_key_name,
					remarks = result.remarks,
					indexes = result.indexes or {},
					foreign_keys = result.foreign_keys or {},
					referenced_by = result.referenced_by or {},
				}
			else
				value = {}
				for _, row in ipairs(result.rows or {}) do
					value[#value + 1] = row
				end
			end
			if key then
				cache_put(connection, key, value)
			end
			callback(value, nil)
		end)
	end

	connected(connection, function(err)
		if err then
			return callback(nil, err)
		end
		send()
	end)
end

function M.databases(connection, callback)
	ask(connection, "catalog/catalogs", {}, "catalogs", callback)
end

function M.schemas(connection, catalog, callback)
	if type(catalog) == "function" then
		catalog, callback = nil, catalog
	end
	local known = store.schemas(connection, catalog)
	if known then
		return callback(known, nil)
	end
	ask(connection, "catalog/schemas", { catalog = catalog }, "schemas:" .. tostring(catalog), callback)
end

local function snapshot_key(catalog, schema)
	return ("snapshot:%s.%s"):format(tostring(catalog), tostring(schema))
end

--- A whole schema in one round trip instead of one per level, which is where the explorer's
--- waiting used to go; M.tables and M.columns are both served from this.
function M.snapshot(connection, catalog, schema, callback)
	ask(
		connection,
		"catalog/snapshot",
		{ catalog = catalog, schema = schema },
		snapshot_key(catalog, schema),
		callback
	)
end

--- Fill the cache for a schema without waiting for it; used when walking into a catalog.
function M.warm(connection, catalog, schema)
	if store.tables(connection, catalog, schema) then
		return
	end
	if cache_get(connection, snapshot_key(catalog, schema)) then
		return
	end
	M.snapshot(connection, catalog, schema, function() end)
end

function M.tables(connection, schema, pattern, callback, catalog)
	if pattern == nil or pattern == "" then
		local known = store.tables(connection, catalog, schema)
		if known then
			return callback(known, nil)
		end
		-- The snapshot already carries name and kind, which is all this level shows.
		return M.snapshot(connection, catalog, schema, callback)
	end
	-- A pattern is a server-side search, and not worth caching.
	ask(
		connection,
		"catalog/tables",
		{ catalog = catalog, schema = schema, pattern = pattern },
		nil,
		callback
	)
end

--- The columns of one table, from the schema snapshot when it is already here.
local function cached_columns(connection, catalog, schema, table_name)
	local snapshot = cache_get(connection, snapshot_key(catalog, schema))
	if not snapshot then
		return nil
	end
	for _, record in ipairs(snapshot) do
		if tostring(record.name) == tostring(table_name) then
			-- Empty is not an answer; see store.columns for why.
			if record.columns and #record.columns > 0 then
				return record.columns
			end
			return nil
		end
	end
	return nil
end

function M.columns(connection, schema, table_name, callback, catalog)
	local known = store.columns(connection, catalog, schema, table_name)
	if known then
		return callback(known, nil)
	end
	local cached = cached_columns(connection, catalog, schema, table_name)
	if cached then
		return callback(cached, nil)
	end
	ask(
		connection,
		"catalog/columns",
		{ catalog = catalog, schema = schema, table = table_name },
		("columns:%s.%s.%s"):format(tostring(catalog), tostring(schema), tostring(table_name)),
		callback
	)
end

--- What the sweep found, synchronously, for a caller that cannot wait for a round trip.
function M.schemas_known(connection, catalog)
	return store.schemas(connection, catalog)
end

function M.tables_known(connection, catalog, schema_name)
	return store.tables(connection, catalog, schema_name)
end

--- Which schema holds this table, per the sweep: the server cannot be asked without the
--- search path, which is a session property; nil means nothing swept or no such table.
--- @return string|nil
function M.locate_table(connection, catalog, table_name)
	local schemas = store.schemas(connection, catalog)
	if not schemas then
		return nil
	end
	for _, record in ipairs(schemas) do
		if store.columns(connection, catalog, record.name, table_name) then
			return record.name
		end
	end
	return nil
end

--- Everything the table view draws, when already known; nil means it would take a round trip.
--- @return table|nil { rows, primary_key, indexes, foreign_keys, referenced_by }
function M.details_ready(connection, catalog, schema, table_name)
	return store.details(connection, catalog, schema, table_name)
end

--- Everything the table view draws: columns, keys, indexes, foreign keys both ways.
function M.details(connection, schema, table_name, callback, catalog)
	local known = store.details(connection, catalog, schema, table_name)
	if known then
		return callback(known, nil)
	end
	ask(
		connection,
		"catalog/details",
		{ catalog = catalog, schema = schema, table = table_name },
		("details:%s.%s.%s"):format(tostring(catalog), tostring(schema), tostring(table_name)),
		function(details, err)
			if details then
				-- Fold into the swept catalog, so a skipped table costs one round trip, not one per preview.
				store.merge_details(connection, catalog, schema, table_name, details)
			end
			callback(details, err)
		end,
		true
	)
end

--- The engine's own CREATE TABLE where it can be had: JDBC has no check constraints, so a
--- metadata definition is never the whole truth; nil is a normal answer, not an error.
--- @param callback fun(ddl: string|nil, err: string|nil)
function M.native_ddl(connection, schema, table_name, callback, catalog)
	local key = ("native_ddl:%s.%s.%s"):format(tostring(catalog), tostring(schema), tostring(table_name))
	local cached = cache_get(connection, key)
	if cached ~= nil then
		-- Cached as a table: a bare nil cannot tell "no DDL" from "not asked yet".
		return callback(cached.ddl, nil)
	end

	connected(connection, function(connect_err)
		if connect_err then
			return callback(nil, connect_err)
		end
		local params = { catalog = catalog, schema = schema, table = table_name }
		gripd.request(connection, "catalog/nativeDdl", params, function(result, err)
			if err then
				return callback(nil, err.message or "the server would not describe the table")
			end
			local ddl = result.ddl
			if ddl == vim.NIL or ddl == "" then
				ddl = nil
			end
			cache_put(connection, key, { ddl = ddl })
			callback(ddl, nil)
		end)
	end)
end

local running_sweeps = {}

local function sweep_key(connection, catalog)
	return ("%s|%s"):format(connection.id, tostring(catalog or ""))
end

--- Is a sweep of this catalog in flight?
function M.introspecting(connection, catalog)
	return running_sweeps[sweep_key(connection, catalog)] == true
end

--- Sweep the whole catalog on the Java side, on connections of its own so no query waits
--- behind it; it writes straight to the store's file (ADR-0010), so a warehouse-sized catalog
--- never travels through the protocol. opts.schema sweeps one namespace and folds it in (ADR-0038).
--- @param opts table|nil { parallelism, timeout_ms, details, schema }
--- @param callback fun(summary: table|nil, err: string|nil)|nil
function M.introspect(connection, catalog, opts, callback)
	opts = opts or {}
	callback = callback or function() end
	local key = sweep_key(connection, catalog)
	if running_sweeps[key] then
		return callback(nil, "already introspecting this catalog")
	end

	local settings = config.get()
	local scoped = opts.schema
	-- A scoped sweep must not land on the store's own file: that would throw the catalog away.
	local path = scoped and (vim.fn.tempname() .. ".json") or store.path(connection, catalog)
	local details = opts.details
	if details == nil then
		details = settings.introspect_details
	end
	running_sweeps[key] = true

	local function finish(summary, err)
		running_sweeps[key] = nil
		callback(summary, err)
	end

	connected(connection, function(connect_err)
		if connect_err then
			return finish(nil, connect_err)
		end
		gripd.request(connection, "catalog/introspect", {
			catalog = catalog,
			schema = scoped,
			path = path,
			parallelism = opts.parallelism or settings.introspect_parallelism,
			budgetMs = opts.timeout_ms or settings.introspect_timeout_ms,
			details = details ~= false,
		}, function(result, err)
			if err then
				return finish(nil, err.message or "introspect failed")
			end
			-- The file is the answer: drop the decoded copy so the next question reads the new one.
			if scoped then
				local merged, merge_err = store.merge_from(connection, catalog, path, scoped)
				pcall(vim.fn.delete, path)
				if not merged then
					return finish(nil, merge_err or "could not merge the scoped sweep")
				end
				store.reload(connection, catalog)
			else
				store.reload(connection, catalog)
			end
			finish({
				schemas = result.schemas or 0,
				tables = result.tables or 0,
				columns = result.columns or 0,
				details = result.details or 0,
				partial = result.partial == true,
				parallel = result.parallel == true,
				elapsed_ms = result.elapsedMs or 0,
				path = scoped and store.path(connection, catalog) or path,
				schema = scoped,
			}, nil)
		end)
	end)
end

--- What has been swept for this catalog, for :NGripDoctor.
function M.snapshot_stat(connection, catalog)
	return store.stat(connection, catalog)
end

--- The SELECT a client starts from; no column rewriting, because the Java side renders binary
--- as hex, so "select *" is safe.
function M.select_statement(connection, schema, table_name, _columns, catalog)
	if connection.driver == "mongodb" then
		return ("db.%s.find({})"):format(table_name)
	end
	return ("SELECT * FROM %s"):format(M.qualify(connection, schema, table_name, catalog))
end

--- A few rows for the previewer.
function M.sample(connection, schema, table_name, count, callback)
	local sql
	if connection.driver == "mongodb" then
		sql = ("db.%s.find({})"):format(table_name)
	else
		-- The row cap is applied by the driver (setMaxRows), so no dialect needs a LIMIT here.
		sql = ("SELECT * FROM %s"):format(M.qualify(connection, schema, table_name))
	end
	runner.run({
		connection = connection,
		sql = sql,
		mode = "query",
		limit = count,
		background = true,
		timeout_ms = 15000,
	}, function(result, err)
		if err then
			return callback(nil, err.message)
		end
		callback(result, nil)
	end)
end

return M
