-- The catalog, asked of the driver.
--
-- This used to be six files of hand-written SQL - pg_catalog, information_
-- schema, sys.objects, sqlite_master, duckdb_tables() and a Mongo aggregation
-- - each with its own quirks. JDBC's DatabaseMetaData answers all of it, so
-- the Java side does the asking and this is only a cache in front of it.
--
-- Two caches, with different jobs. neogrip/schema/store.lua holds a whole
-- catalog as swept once by :NGripIntrospect, and is asked first because an
-- answer from it costs nothing and survives a restart. What is left here is
-- the per-question cache that fills in as you walk: it answers for a database
-- nobody has introspected yet, and for a table the sweep's budget did not
-- reach.
local config = require("neogrip.config")
local neogrip = require("neogrip")
local sidecar = require("neogrip.sidecar")
local runner = require("neogrip.runner")
local store = require("neogrip.schema.store")

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

--- schema.table, quoted, for a generated statement.
function M.qualify(connection, schema, table_name)
	if connection.driver == "mongodb" then
		return tostring(table_name)
	end
	if schema and schema ~= "" and connection.driver ~= "sqlite" then
		return M.quote(connection.driver, schema) .. "." .. M.quote(connection.driver, table_name)
	end
	return M.quote(connection.driver, table_name)
end

--- The catalog a connection means - and so the key its swept catalog is kept
--- under on disk.
---
--- One definition, because three callers have to agree about it: the explorer
--- opens on it, :NGripIntrospect sweeps it, and the store keys its file by it.
--- They did not agree in the predecessor: completion asked every question with
--- no catalog at all and therefore never once read the sweep it was supposed
--- to be instant because of.
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
		-- Their one database is a schema as far as the metadata calls are
		-- concerned; the catalog argument is not what filters them.
		return nil
	end
	-- Trino's catalog field, or the database the connection names.
	if connection.catalog and connection.catalog ~= "" then
		return connection.catalog
	end
	if connection.database == nil or connection.database == "" then
		return nil
	end
	return connection.database
end

local function cache_path(connection)
	local dir = neogrip.state_dir .. "/cache"
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

--- Forget everything cached for a connection, the swept catalog included:
--- "reload the schema" has to mean all of it, or the stale half keeps
--- answering.
function M.invalidate(connection)
	if connection then
		memory[connection.id] = nil
		pcall(vim.fn.delete, cache_path(connection))
	else
		memory = {}
		pcall(vim.fn.delete, neogrip.state_dir .. "/cache", "rf")
	end
	store.clear(connection)
end

--- Make sure the connection's process is up, then carry on.
---
--- A catalog question is sent to the process directly rather than queued as a
--- statement, so something has to open the process first: a trivial query is
--- the cheapest way, and it is what the runner would do anyway. A connection
--- re-pointed at another database or catalog counts as not connected.
--- @param callback fun(err: string|nil)
local function connected(connection, callback)
	if sidecar.is_connected_to(connection) then
		return callback(nil)
	end
	runner.run({
		connection = connection,
		sql = connection.driver == "mongodb" and "db.getCollectionNames()" or "select 1",
		mode = "query",
		limit = 1,
		background = true,
	}, function(_, err)
		if err and not sidecar.is_connected(connection.id) then
			return callback(err.message)
		end
		callback(nil)
	end)
end

--- Ask the sidecar a catalog question.
---
--- `whole` keeps the entire answer instead of just its rows: the details
--- method reports a primary key, indexes and foreign keys alongside the
--- columns, and those do not fit the rows shape.
local function ask(connection, method, params, key, callback, whole)
	if key then
		local cached = cache_get(connection, key)
		if cached then
			return callback(cached, nil)
		end
	end

	local function send()
		sidecar.request(connection, method, params, function(result, err)
			if err then
				return callback(nil, err.message or "catalog lookup failed")
			end
			local value
			if whole then
				-- Named rather than copied wholesale so a stray protocol
				-- field cannot become editor state, but every field the
				-- renderer draws has to be here: a constraint name or a
				-- table's comment left out is a definition that silently
				-- renders as less than the server reported.
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

--- A whole schema at once: every table with every one of its columns.
---
--- One round trip instead of one per level and one more per table the cursor
--- touches, which is where the explorer's waiting used to go. M.tables and
--- M.columns are both served from this, so after it lands the walk down to a
--- column asks the server nothing.
function M.snapshot(connection, catalog, schema, callback)
	ask(
		connection,
		"catalog/snapshot",
		{ catalog = catalog, schema = schema },
		snapshot_key(catalog, schema),
		callback
	)
end

--- Fill the cache for a schema without waiting for it, and without disturbing
--- whatever is on screen. Used when walking into a catalog.
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
		-- The snapshot already carries name and kind for every table, which is
		-- all this level shows.
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
			return record.columns
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

--- What the sweep found, synchronously, or nil when nothing has been swept.
---
--- M.schemas and M.tables are the asynchronous pair that fall back to the
--- server; these are for a caller that cannot wait for a round trip, such as
--- completion answering a keystroke or a previewer drawing a pane.
function M.schemas_known(connection, catalog)
	return store.schemas(connection, catalog)
end

function M.tables_known(connection, catalog, schema_name)
	return store.tables(connection, catalog, schema_name)
end

--- Which schema holds this table, according to the sweep.
---
--- An unqualified name in a statement is not enough to ask the server about -
--- that would need the search path, which is a session property and not a
--- catalog one. The swept catalog does know every schema, so here the answer
--- is a lookup. nil means nothing was swept, or there is no such table.
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

--- Everything the table view draws, when it is already known and without
--- asking anyone: what the previewer needs to draw a definition while the
--- cursor is still moving. nil means it would take a round trip.
--- @return table|nil { rows, primary_key, indexes, foreign_keys, referenced_by }
function M.details_ready(connection, catalog, schema, table_name)
	return store.details(connection, catalog, schema, table_name)
end

--- Everything the table view draws: columns, primary key, indexes, the foreign
--- keys the table declares and the ones pointing back at it.
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
				-- Fold it into the swept catalog, so a table the budget did not
				-- reach costs one round trip and not one per preview.
				store.merge_details(connection, catalog, schema, table_name, details)
			end
			callback(details, err)
		end,
		true
	)
end

--- The engine's own CREATE TABLE, for the engines that have one statement
--- that produces it.
---
--- JDBC has no concept of a check constraint, so a definition rendered from
--- DatabaseMetaData is never the whole truth. This is the server's own text
--- where it can be had cheaply - and nil is a perfectly normal answer, not an
--- error: most engines have nothing of the kind to ask for.
--- @param callback fun(ddl: string|nil, err: string|nil)
function M.native_ddl(connection, schema, table_name, callback, catalog)
	local key = ("native_ddl:%s.%s.%s"):format(tostring(catalog), tostring(schema), tostring(table_name))
	local cached = cache_get(connection, key)
	if cached ~= nil then
		-- Cached as a table because the cache cannot tell "no DDL" from "not
		-- asked yet" if it stores a bare nil.
		return callback(cached.ddl, nil)
	end

	connected(connection, function(connect_err)
		if connect_err then
			return callback(nil, connect_err)
		end
		local params = { catalog = catalog, schema = schema, table = table_name }
		sidecar.request(connection, "catalog/nativeDdl", params, function(result, err)
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

--- Sweep the whole catalog - every schema, table, column, key and index - and
--- keep it in the store.
---
--- The work happens on the Java side, on connections of its own: the process
--- has one worker and one connection for statements, and a sweep that took
--- them would make every query wait behind it. It writes straight to the
--- store's file (ADR-0010), so a catalog the size of a warehouse never travels
--- through the request protocol.
---
--- @param opts table|nil { parallelism, timeout_ms, details }
--- @param callback fun(summary: table|nil, err: string|nil)|nil
function M.introspect(connection, catalog, opts, callback)
	opts = opts or {}
	callback = callback or function() end
	local key = sweep_key(connection, catalog)
	if running_sweeps[key] then
		return callback(nil, "already introspecting this catalog")
	end

	local settings = config.get()
	local path = store.path(connection, catalog)
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
		sidecar.request(connection, "catalog/introspect", {
			catalog = catalog,
			path = path,
			parallelism = opts.parallelism or settings.introspect_parallelism,
			budgetMs = opts.timeout_ms or settings.introspect_timeout_ms,
			details = details ~= false,
		}, function(result, err)
			if err then
				return finish(nil, err.message or "introspect failed")
			end
			-- The file is the answer: drop the decoded copy so the next
			-- question reads the one that was just written.
			store.reload(connection, catalog)
			finish({
				schemas = result.schemas or 0,
				tables = result.tables or 0,
				columns = result.columns or 0,
				details = result.details or 0,
				partial = result.partial == true,
				parallel = result.parallel == true,
				elapsed_ms = result.elapsedMs or 0,
				path = path,
			}, nil)
		end)
	end)
end

--- What has been swept for this catalog, for :NGripDoctor.
function M.snapshot_stat(connection, catalog)
	return store.stat(connection, catalog)
end

--- The SELECT the explorer opens for a table.
---
--- No column rewriting: the Java side renders a binary column as hex because
--- JDBC tells it the column is binary, so "select *" is safe.
function M.select_statement(connection, schema, table_name, _columns)
	if connection.driver == "mongodb" then
		return ("db.%s.find({})"):format(table_name)
	end
	return ("SELECT * FROM %s"):format(M.qualify(connection, schema, table_name))
end

--- A few rows for the previewer.
function M.sample(connection, schema, table_name, count, callback)
	local sql
	if connection.driver == "mongodb" then
		sql = ("db.%s.find({})"):format(table_name)
	else
		-- The row cap is applied by the driver (setMaxRows), so no dialect
		-- needs a LIMIT spelled out here.
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
