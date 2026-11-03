-- The catalog as a navigable tree of data, for a client that draws its own
-- explorer (ADR-0036, ADR-0037).
--
-- Six levels, a closed set:
--
--   server -> instance -> namespace -> set -> object -> attribute
--   (conn)    (database)  (schema)    (table) (row)     (column)
--
-- Nothing here is formatted for a human: no icons, no padding, no "12
-- columns". A node carries what it is and what is true about it, and the
-- client decides how that looks. `lua/neogrip/icons.lua` is a table a client
-- may read or override; nothing in this module touches it.
--
-- Which levels a connection actually has differs by engine, and that knowledge
-- stays here: `shape()` answers the walk already truncated, with a label per
-- level, so a client recurses through one `children()` call from the
-- connection down to the column without ever naming an engine.
local connections = require("neogrip.connections")
local gripd = require("neogrip.gripd")
local runner = require("neogrip.runner")
local schema = require("neogrip.schema")
local store = require("neogrip.schema.store")

local M = {}

--- The level a node sits at. A closed set: adding one is a contract change.
M.LEVELS = { "server", "instance", "namespace", "set", "object", "attribute" }

--- @param driver string
local function labels_for(driver)
	return {
		server = "Connection",
		instance = driver == "trino" and "Catalogs" or "Databases",
		namespace = "Schemas",
		set = driver == "mongodb" and "Collections" or "Tables",
		object = driver == "mongodb" and "Documents" or "Rows",
		attribute = driver == "mongodb" and "Fields" or "Columns",
	}
end

--- The walk this connection has, already truncated, and how to label it.
---
--- A file database has no instance to choose and no schema layer; MySQL and
--- MongoDB have databases but no schemas; a connection that names its database
--- starts below that level because there is nothing left to choose. Trino is
--- why `instance` carries the label it does, and why the catalog travels in
--- every ref: asked for all catalogs at once it answers with every catalog's
--- schemas and nothing saying which is which.
---
--- `object` is in the walk but marked `on_demand`: rows are data, they cost a
--- query and are never cached, so `children()` does not reach them unless it is
--- asked to.
--- @param connection table
--- @return table { levels, sweepable, cacheable_until }
function M.shape(connection)
	local driver = connection.driver
	local labels = labels_for(driver)
	local levels = { { level = "server", label = labels.server } }

	local function add(level, extra)
		local entry = { level = level, label = labels[level] }
		for key, value in pairs(extra or {}) do
			entry[key] = value
		end
		levels[#levels + 1] = entry
	end

	if driver == "sqlite" then
		-- One file and no schemas at all: getSchemas answers nothing there, so
		-- the sets hang off the connection itself.
		add("set")
		add("object", { on_demand = true })
		add("attribute")
		return { levels = levels, sweepable = true, cacheable_until = "attribute" }
	elseif driver == "duckdb" then
		-- A file too, but it does have schemas - main, information_schema,
		-- pg_catalog - and the sweep keys its snapshot by them, so a tree that
		-- skipped the level would ask the server for what it already had. It
		-- has attached catalogs as well, and they are deliberately not a level:
		-- the catalog argument is not what filters DuckDB's metadata, which is
		-- why schema.catalog_of answers nothing for it.
		add("namespace")
	elseif driver == "mysql" or driver == "mariadb" or driver == "mongodb" then
		-- A connection that names its database starts below that level:
		-- there is nothing left to choose.
		if connection.database == nil or connection.database == "" then
			add("instance", { reconnects = true })
		end
	else
		if not schema.catalog_of(connection) then
			add("instance", { reconnects = true })
		end
		add("namespace")
	end
	add("set")
	add("object", { on_demand = true })
	add("attribute")

	return {
		levels = levels,
		-- A collection catalog cannot be swept; its fields come from sampling
		-- one collection at a time (ADR-0029).
		sweepable = driver ~= "mongodb",
		-- Everything down to a column can come out of a snapshot. A row never
		-- can, and never will: it is data.
		cacheable_until = "attribute",
	}
end

--- The level `children()` goes to next, skipping what must be asked for.
local function next_level(shape, level, wanted)
	local found = level == nil
	for _, entry in ipairs(shape.levels) do
		if found then
			if wanted then
				if entry.level == wanted then
					return entry.level
				end
			elseif not entry.on_demand then
				return entry.level
			end
		end
		if entry.level == level then
			found = true
		end
	end
	return nil
end

-- --- ids ---------------------------------------------------------------

--- A segment of an id, with the separator and the escape itself escaped.
---
--- Names carry slashes, percent signs, quotes and spaces: a table called `a/b`
--- would otherwise produce an id that reads as two levels, and two different
--- nodes could share one. A client keys its cache, its diff and its extmarks
--- on this, so it has to be exact.
local function encode(segment)
	return (tostring(segment):gsub("[%%/]", function(char)
		return ("%%%02X"):format(char:byte())
	end))
end

--- The stable id of whatever this ref points at.
---
--- A row's id ends in its position, which is the only identity a row has
--- without a key the client never asked us for - so it is stable for as long
--- as the page is, and no longer.
--- @param ref table
--- @return string
function M.id(ref)
	local parts = { encode(ref.server or "") }
	for _, key in ipairs({ "instance", "namespace", "set", "attribute" }) do
		if ref[key] ~= nil then
			parts[#parts + 1] = encode(ref[key])
		end
	end
	if ref.object ~= nil then
		parts[#parts + 1] = "#" .. encode(ref.object)
	end
	return table.concat(parts, "/")
end

-- --- refs and the engines' two qualifiers ------------------------------

--- The connection a ref names, out of the registry.
---
--- A ref carries an id and not a connection object, because it has to survive
--- being a node id, a client's cache key and a round trip through a config
--- file. A connection the registry has never seen - an ephemeral one a caller
--- built itself - has to be registered before the tree can answer for it.
--- @return table|nil connection
local function server_of(ref)
	return ref and ref.server and connections.get(ref.server) or nil
end

--- How this engine wants a ref's two qualifiers passed to `schema.*`.
---
--- MySQL, MariaDB and MongoDB report their databases as catalogs and have no
--- schema layer, so the database goes where every other engine puts its schema.
--- @return string|nil catalog, string|nil namespace
local function qualifiers(connection, ref)
	local driver = connection.driver
	if driver == "mysql" or driver == "mariadb" or driver == "mongodb" then
		return nil, ref.instance or (connection.database ~= "" and connection.database or nil)
	end
	return ref.instance or schema.catalog_of(connection), ref.namespace
end

local function extend(ref, key, value)
	local next_ref = vim.deepcopy(ref or {})
	next_ref[key] = value
	return next_ref
end

-- --- nodes -------------------------------------------------------------

--- @return table node
local function node(level, kind, name, ref, extra)
	local built = {
		id = M.id(ref),
		level = level,
		kind = kind,
		name = name,
		ref = ref,
		expandable = level ~= "attribute" and level ~= "object",
		facts = {},
	}
	for key, value in pairs(extra or {}) do
		built[key] = value
	end
	return built
end

--- A handle a client can abandon: a warehouse answers a listing in seconds,
--- and a node collapsed in the meantime must not deliver into a tree that has
--- moved on. For rows the cancel reaches the server, which closes the cursor
--- there - gripd keeps four per connection and evicts the oldest, so a client
--- that never closes loses the branch it opened first.
local function new_handle()
	local state = { cancelled = false, run = nil }
	return {
		cancel = function()
			state.cancelled = true
			if state.run then
				runner.cancel(state.run)
			end
			return true
		end,
		_state = state,
	}
end

local function deliver(handle, callback, nodes, err)
	if handle._state.cancelled then
		return
	end
	callback(nodes, err)
end

-- --- children ----------------------------------------------------------

local function servers(handle, callback)
	local nodes = {}
	for _, connection in ipairs(connections.all()) do
		local ref = { server = connection.id }
		nodes[#nodes + 1] = node("server", connection.driver, connection.name or connection.id, ref, {
			source = "cache",
			facts = {
				readonly = connection.readonly == true or nil,
				production = connection.production == true or nil,
				connected = gripd.is_connected(connection.id) or nil,
			},
		})
	end
	table.sort(nodes, function(left, right)
		return tostring(left.name):lower() < tostring(right.name):lower()
	end)
	return deliver(handle, callback, nodes, nil)
end

local function instances(handle, connection, ref, callback)
	schema.databases(connection, function(records, err)
		if err then
			return deliver(handle, callback, nil, err)
		end
		local nodes = {}
		for _, record in ipairs(records or {}) do
			local kind = connection.driver == "trino" and "catalog" or "database"
			nodes[#nodes + 1] = node(
				"instance",
				kind,
				record.name,
				extend(ref, "instance", record.name),
				{ source = "server", facts = { reconnects = true } }
			)
		end
		deliver(handle, callback, nodes, nil)
	end)
end

local function namespaces(handle, connection, ref, callback)
	local catalog = qualifiers(connection, ref)
	local known = schema.schemas_known(connection, catalog)
	schema.schemas(connection, catalog, function(records, err)
		if err then
			return deliver(handle, callback, nil, err)
		end
		local nodes = {}
		for _, record in ipairs(records or {}) do
			nodes[#nodes + 1] = node(
				"namespace",
				"schema",
				record.name,
				extend(ref, "namespace", record.name),
				{ source = known and "cache" or "server" }
			)
		end
		deliver(handle, callback, nodes, nil)
	end)
end

local function sets(handle, connection, ref, pattern, callback)
	local catalog, namespace = qualifiers(connection, ref)
	local known = schema.tables_known(connection, catalog, namespace)
	schema.tables(connection, namespace, pattern, function(records, err)
		if err then
			return deliver(handle, callback, nil, err)
		end
		local nodes = {}
		for _, record in ipairs(records or {}) do
			nodes[#nodes + 1] =
				node("set", record.kind or "table", record.name, extend(ref, "set", record.name), {
					source = known and "cache" or "server",
					facts = {
						remarks = record.remarks,
						columns = record.columns and #record.columns > 0 and #record.columns or nil,
					},
				})
		end
		deliver(handle, callback, nodes, nil)
	end, catalog)
end

local function attributes(handle, connection, ref, callback)
	local catalog, namespace = qualifiers(connection, ref)
	schema.columns(connection, namespace, ref.set, function(records, err)
		if err then
			return deliver(handle, callback, nil, err)
		end
		local nodes = {}
		local kind = connection.driver == "mongodb" and "field" or "column"
		for _, record in ipairs(records or {}) do
			nodes[#nodes + 1] = node("attribute", kind, record.name, extend(ref, "attribute", record.name), {
				source = schema.details_ready(connection, catalog, namespace, ref.set) and "cache"
					or "server",
				facts = {
					type = record.type,
					nullable = record.nullable,
					is_pk = record.is_pk or nil,
					default_expr = record.default_expr,
					auto_increment = record.auto_increment,
					generated = record.generated,
					position = record.position,
					remarks = record.remarks,
					-- A collection's fields are sampled, not declared
					-- (ADR-0038): these two are what say so.
					count = record.count,
					sample_size = record.sample_size,
				},
			})
		end
		deliver(handle, callback, nodes, nil)
	end, catalog)
end

--- The rows of a set, as nodes, through the named cursor of ADR-0031.
---
--- Never cached and never swept: this is the one level that is data. The
--- result carries `continue` when there are more, and closing a node means
--- calling the handle's cancel so gripd stops holding the cursor - it keeps
--- four per connection and evicts the oldest, so a client that expands five
--- tables without closing any loses the first.
local function objects(handle, connection, ref, opts, callback)
	M.statement(ref, "select", function(text, statement_err)
		if statement_err then
			return deliver(handle, callback, nil, statement_err)
		end
		local limit = opts.limit or 50
		local request = {
			connection = connection,
			sql = opts.hash and nil or text,
			mode = opts.hash and "next" or "query",
			hash = opts.hash,
			limit = limit,
		}
		local run = runner.run(request, function(result, err)
			if err then
				return deliver(handle, callback, nil, err)
			end
			local nodes = {}
			local kind = connection.driver == "mongodb" and "document" or "row"
			local columns = result.columns or {}
			for index, row in ipairs(result.rows or {}) do
				local values = {}
				for position, column in ipairs(columns) do
					values[tostring(column)] = row[position]
				end
				local position = (opts.from or 0) + index
				nodes[#nodes + 1] =
					node("object", kind, tostring(position), extend(ref, "object", position), {
						source = "server",
						facts = { values = values, columns = columns },
					})
			end
			-- The continuation before the nodes: a client that pages on
			-- delivery has what it needs to ask for more.
			if not handle._state.cancelled and opts.on_page then
				opts.on_page({
					hash = result.hash,
					done = result.done == true,
					from = (opts.from or 0) + #nodes,
				})
			end
			deliver(handle, callback, nodes, nil)
		end)
		handle._state.run = run
	end)
end

--- The children of a node, at whatever level comes next for this connection.
---
--- `node` of nil answers the configured connections, so one recursive function
--- walks from there down to a column without knowing that the top level comes
--- from a different place than the rest.
---
--- @param from table|nil the node to expand, or nil for the servers
--- @param opts table|nil { objects = true, limit, hash, from, on_page, pattern }
--- @param callback fun(nodes: table[]|nil, err: table|string|nil)
--- @return table handle with :cancel()
function M.children(from, opts, callback)
	opts = opts or {}
	local handle = new_handle()

	if from == nil then
		servers(handle, callback)
		return handle
	end

	local connection = server_of(from.ref)
	if not connection then
		deliver(handle, callback, nil, { message = "no connection named " .. tostring(from.ref.server) })
		return handle
	end

	local shape = M.shape(connection)
	local wanted = opts.objects and "object" or nil
	local level = next_level(shape, from.level, wanted)
	if level == nil then
		deliver(handle, callback, {}, nil)
		return handle
	end

	if level == "instance" then
		instances(handle, connection, from.ref, callback)
	elseif level == "namespace" then
		namespaces(handle, connection, from.ref, callback)
	elseif level == "set" then
		sets(handle, connection, from.ref, opts.pattern, callback)
	elseif level == "attribute" then
		attributes(handle, connection, from.ref, callback)
	elseif level == "object" then
		objects(handle, connection, from.ref, opts, callback)
	else
		deliver(handle, callback, {}, nil)
	end
	return handle
end

-- --- tools -------------------------------------------------------------

--- The name a statement can carry, quoted for this engine.
---
--- The one place a name becomes SQL: a set called `Order` needs its quotes in
--- PostgreSQL, backticks in MySQL and brackets in SQL Server, and a client that
--- concatenated the segments itself would be writing a statement that fails on
--- half the engines.
--- @param ref table
--- @return string|nil
function M.qualified_name(ref)
	local connection = server_of(ref)
	if not connection or not ref.set then
		return nil
	end
	local _, namespace = qualifiers(connection, ref)
	return schema.qualify(connection, namespace, ref.set)
end

--- A statement to start from, as text. Opens nothing.
--- @param kind string "select" | "insert" | "update" | "delete"
--- @param callback fun(text: string|nil, err: table|string|nil)
function M.statement(ref, kind, callback)
	local connection = server_of(ref)
	if not connection or not ref.set then
		return callback(nil, "a statement needs a set")
	end
	local catalog, namespace = qualifiers(connection, ref)
	schema.columns(connection, namespace, ref.set, function(columns, err)
		if err then
			return callback(nil, err)
		end
		callback(require("neogrip.sql.statement").for_set(connection, namespace, ref.set, kind, columns), nil)
	end, catalog)
end

--- Keys, indexes and references for one set, as records.
function M.details(ref, callback)
	local connection = server_of(ref)
	if not connection or not ref.set then
		return callback(nil, "details need a set")
	end
	local catalog, namespace = qualifiers(connection, ref)
	schema.details(connection, namespace, ref.set, callback, catalog)
end

--- The server's own definition, or nil where the engine has none.
function M.ddl(ref, callback)
	local connection = server_of(ref)
	if not connection or not ref.set then
		return callback(nil, "a definition needs a set")
	end
	local catalog, namespace = qualifiers(connection, ref)
	schema.native_ddl(connection, namespace, ref.set, callback, catalog)
end

--- Approximate row counts for a namespace, by set name (ADR-0038).
---
--- Lazy on purpose: the tree does not wait for it, and where the engine keeps
--- no estimate the answer is simply empty - a client shows no number rather
--- than a wrong one, and nothing counts rows on its behalf.
function M.counts(ref, callback)
	local connection = server_of(ref)
	if not connection then
		return callback(nil, "no connection")
	end
	local catalog, namespace = qualifiers(connection, ref)
	gripd.request(
		connection,
		"catalog/counts",
		{ catalog = catalog, schema = namespace },
		function(result, err)
			if err then
				return callback(nil, err)
			end
			callback(result and result.counts or {}, nil)
		end
	)
end

--- Sets whose name contains `pattern`, anywhere under this ref.
---
--- A flat answer rather than a walk, because that is what a fuzzy finder
--- wants. With a snapshot it is a scan of what is already here; without one it
--- is a server-side search of the namespace in the ref.
function M.find(ref, pattern, callback)
	local connection = server_of(ref)
	if not connection then
		return callback(nil, "no connection")
	end
	local catalog, namespace = qualifiers(connection, ref)
	local needle = tostring(pattern or ""):lower()

	local snapshot = store.load(connection, catalog)
	if snapshot and needle ~= "" then
		local nodes = {}
		for _, schema_entry in ipairs(snapshot.schemas or {}) do
			for _, record in ipairs(schema_entry.tables or {}) do
				if tostring(record.name):lower():find(needle, 1, true) then
					local found = { server = connection.id, instance = catalog, set = record.name }
					if schema_entry.name and schema_entry.name ~= "" then
						found.namespace = schema_entry.name
					end
					nodes[#nodes + 1] = node("set", record.kind or "table", record.name, found, {
						source = "cache",
						facts = { remarks = record.remarks },
					})
				end
			end
		end
		return callback(nodes, nil)
	end

	M.children(
		{ level = "namespace", ref = extend(ref, "namespace", namespace) },
		{ pattern = pattern },
		callback
	)
end

--- Sweep this ref's catalog, or just one namespace of it (ADR-0038).
---
--- A ref naming a namespace sweeps that namespace and folds the answer into
--- what is already known; anything shallower sweeps the whole instance and
--- replaces it. Mongo cannot be swept at all - `shape().sweepable` says so
--- before the attempt.
function M.sweep(ref, opts, callback)
	local connection = server_of(ref)
	if not connection then
		return callback(nil, "no connection")
	end
	local catalog, namespace = qualifiers(connection, ref)
	local settings = vim.tbl_extend("force", opts or {}, {})
	if ref.namespace then
		settings.schema = namespace
	end
	schema.introspect(connection, catalog, settings, callback)
end

--- When this ref's catalog was swept, and what it holds. nil when never.
function M.swept(ref)
	local connection = server_of(ref)
	if not connection then
		return nil
	end
	local catalog = qualifiers(connection, ref)
	return store.stat(connection, catalog)
end

--- Forget what is cached for this ref's connection, so the next question asks
--- the server. The client decides when: nothing here watches the database.
function M.forget(ref)
	local connection = server_of(ref)
	if not connection then
		return false
	end
	schema.invalidate(connection)
	return true
end

return M
