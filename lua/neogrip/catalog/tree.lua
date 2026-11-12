-- The catalog as a navigable tree of data:
-- server -> instance -> namespace -> set -> object -> attribute.
local connections = require("neogrip.connections")
local gripd = require("neogrip.gripd")
local runner = require("neogrip.gripd.runner")
local schema = require("neogrip.catalog")
local store = require("neogrip.catalog.store")

local M = {}

--- The level a node sits at. A closed set: adding one is a contract change.
M.LEVELS = { "server", "instance", "namespace", "set", "object", "attribute" }

--- Whether using another instance means reopening the connection: everywhere
--- but Trino, where one session queries across catalogs (ADR-0039).
--- @return boolean|nil
local function reconnects_for(connection)
	return connection.driver ~= "trino" or nil
end

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
--- The catalog travels in every ref because Trino, asked for all catalogs at
--- once, answers every catalog's schemas with nothing saying which is which.
--- `object` is on_demand: rows are data, cost a query and are never cached.
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
		-- SQLite's sets hang off the connection; see doc/internals.md#schema-and-tree.
		add("set")
		add("object", { on_demand = true })
		add("attribute")
		return { levels = levels, sweepable = true, cacheable_until = "attribute" }
	elseif driver == "duckdb" then
		-- DuckDB has schemas and the sweep keys its snapshot by them; attached
		-- catalogs are not a level because the catalog argument does not filter
		-- its metadata.
		add("namespace")
	elseif driver == "mysql" or driver == "mariadb" or driver == "mongodb" then
		-- A connection that names its database has nothing left to choose.
		if connection.database == nil or connection.database == "" then
			add("instance", { reconnects = reconnects_for(connection) })
		end
	else
		if not schema.catalog_of(connection) then
			add("instance", { reconnects = reconnects_for(connection) })
		end
		add("namespace")
	end
	add("set")
	add("object", { on_demand = true })
	add("attribute")

	return {
		levels = levels,
		-- A collection catalog cannot be swept; fields come from sampling (ADR-0029).
		sweepable = driver ~= "mongodb",
		-- A row never comes out of a snapshot: it is data.
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

--- A segment of an id, with the separator, the escape itself and the row
--- marker escaped: a table called `a/b` would otherwise produce an id that
--- reads as two levels, and one called `#3` an id that reads as a row.
local function encode(segment)
	return (tostring(segment):gsub("[%%/#]", function(char)
		return ("%%%02X"):format(char:byte())
	end))
end

--- A segment back to the name it encodes.
local function decode(segment)
	return (segment:gsub("%%(%x%x)", function(hex)
		return string.char(tonumber(hex, 16))
	end))
end

--- The stable id of whatever this ref points at; a row's id ends in its
--- position, stable for as long as the page is and no longer.
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

--- The connection a ref names; a ref carries an id, not a connection object,
--- so it survives being a node id, a cache key and a config round trip.
--- @return table|nil connection
local function server_of(ref)
	return ref and ref.server and connections.get(ref.server) or nil
end

--- The ref a node id names, resolved against the connection's shape: the id
--- alone does not say which level a segment fills, the walk this connection
--- has does.
--- @param id string
--- @return table|nil ref, string|nil reason
function M.ref_of(id)
	local segments = vim.split(tostring(id or ""), "/", { plain = true })
	local server = decode(segments[1] or "")
	local connection = connections.get(server)
	if not connection then
		return nil, ("no connection named %s"):format(server)
	end

	local ref = { server = connection.id }
	local levels = {}
	for _, entry in ipairs(M.shape(connection).levels) do
		if entry.level ~= "server" and entry.level ~= "object" then
			levels[#levels + 1] = entry.level
		end
	end

	local names = {}
	for index = 2, #segments do
		local segment = segments[index]
		if segment:sub(1, 1) == "#" then
			if index ~= #segments then
				return nil, "a row's position ends its id"
			end
			local position = decode(segment:sub(2))
			ref.object = tonumber(position) or position
		else
			names[#names + 1] = decode(segment)
		end
	end

	-- A ref built from a search result carries the connection's own catalog in
	-- its instance slot even where the shape has no instance level; the walk
	-- never writes that segment, so a first name spelling that catalog is read
	-- as the instance, not as the level the walk would fill.
	if levels[1] ~= "instance" and #names > 0 and names[1] == schema.catalog_of(connection) then
		ref.instance = table.remove(names, 1)
	end
	if #names > #levels then
		return nil, ("%s has no level for %q"):format(connection.id, tostring(names[#levels + 1]))
	end
	for index, name in ipairs(names) do
		ref[levels[index]] = name
	end
	return ref, nil
end

--- How this engine passes a ref's two qualifiers to `schema.*`: MySQL, MariaDB
--- and MongoDB report databases as catalogs and have no schema layer.
--- @return string|nil catalog, string|nil namespace
local function qualifiers(connection, ref)
	local driver = connection.driver
	if driver == "mysql" or driver == "mariadb" or driver == "mongodb" then
		return nil, ref.instance or (connection.database ~= "" and connection.database or nil)
	end
	return ref.instance or schema.catalog_of(connection), ref.namespace
end

--- The same mapping for a caller composing catalog requests of its own (ADR-0047).
M.qualifiers = qualifiers

local function extend(ref, key, value)
	local next_ref = vim.deepcopy(ref or {})
	next_ref[key] = value
	return next_ref
end

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

--- A handle a client can abandon; for rows the cancel reaches the server,
--- since nothing evicts a cursor on the client's behalf any more (ADR-0041).
local function new_handle()
	local state = { cancelled = false, run = nil }
	return {
		cancel = function()
			state.cancelled = true
			if state.run then
				-- cancel declines once answered; since the cap went (ADR-0041)
				-- nothing else closes the listing, so it is handed back by name
				-- or held until the idle sweep an hour later.
				if not runner.cancel(state.run) and state.run.hash then
					runner.release(state.run.request.connection, state.run.hash)
				end
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
				{ source = "server", facts = { reconnects = reconnects_for(connection) } }
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

--- One page of a listing, straight from the server (ADR-0038): the cached path
--- caps what it sends without saying so, and a cap is not a page, so an exact
--- caller pages and learns from `done` that there is more.
local function paged(handle, connection, ref, level, pattern, opts, callback)
	local catalog, namespace = qualifiers(connection, ref)
	local method = ({
		instance = "catalog/catalogs",
		namespace = "catalog/schemas",
		set = "catalog/tables",
	})[level]
	local params = { after = opts.after, limit = opts.limit }
	if level ~= "instance" then
		params.catalog = catalog
	end
	if level == "set" then
		params.schema = namespace
		params.pattern = pattern
	end
	gripd.request(connection, method, params, function(result, err)
		if err then
			return deliver(handle, callback, nil, err)
		end
		local nodes = {}
		local last = nil
		for _, record in ipairs((result or {}).rows or {}) do
			local built
			if level == "set" then
				built = node("set", record.kind or "table", record.name, extend(ref, "set", record.name), {
					source = "server",
					facts = { remarks = record.remarks },
				})
			elseif level == "instance" then
				built = node(
					"instance",
					connection.driver == "trino" and "catalog" or "database",
					record.name,
					extend(ref, "instance", record.name),
					{ source = "server", facts = { reconnects = reconnects_for(connection) } }
				)
			else
				built = node(
					"namespace",
					"schema",
					record.name,
					extend(ref, "namespace", record.name),
					{ source = "server" }
				)
			end
			nodes[#nodes + 1] = built
			last = record.name
		end
		-- The page is exactly the opts of the next call, so a client continues
		-- with one `vim.tbl_extend("force", opts, page)` at any level.
		if not handle._state.cancelled and opts.on_page then
			opts.on_page({
				done = not (result and result.truncated == true),
				after = last,
			})
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
					-- A collection's fields are sampled, not declared (ADR-0038).
					count = record.count,
					sample_size = record.sample_size,
				},
			})
		end
		deliver(handle, callback, nodes, nil)
	end, catalog)
end

--- The rows of a set, as nodes, through the named cursor of ADR-0031; never
--- cached, and closing a node means calling the handle's cancel so gripd stops
--- holding the cursor (ADR-0041).
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
			-- The continuation goes before the nodes, so a client paging on
			-- delivery can ask for more.
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

--- The children of a node, at whatever level comes next for this connection;
--- nil answers the configured connections. `limit` or `after` asks the server
--- for one page and reports `{ done, after }` through `on_page`; without
--- either, the answer is the cached whole-schema one, capped by the server
--- without saying so.
--- @param from table|nil the node to expand, or nil for the servers
--- @param opts table|nil { objects, limit, after, hash, from, on_page, pattern }
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

	local paging = opts.after ~= nil or opts.limit ~= nil
	if level == "instance" then
		if paging then
			paged(handle, connection, from.ref, "instance", nil, opts, callback)
		else
			instances(handle, connection, from.ref, callback)
		end
	elseif level == "namespace" then
		if paging then
			paged(handle, connection, from.ref, "namespace", nil, opts, callback)
		else
			namespaces(handle, connection, from.ref, callback)
		end
	elseif level == "set" then
		if paging then
			paged(handle, connection, from.ref, "set", opts.pattern, opts, callback)
		else
			sets(handle, connection, from.ref, opts.pattern, callback)
		end
	elseif level == "attribute" then
		attributes(handle, connection, from.ref, callback)
	elseif level == "object" then
		objects(handle, connection, from.ref, opts, callback)
	else
		deliver(handle, callback, {}, nil)
	end
	return handle
end

--- The name a statement can carry, quoted for this engine: a client that
--- concatenated the segments itself would fail on half the engines.
--- @param ref table
--- @return string|nil
function M.qualified_name(ref)
	local connection = server_of(ref)
	if not connection or not ref.set then
		return nil
	end
	local catalog, namespace = qualifiers(connection, ref)
	return schema.qualify(connection, namespace, ref.set, catalog)
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
		callback(
			require("neogrip.catalog.statement").for_set(
				connection,
				namespace,
				ref.set,
				kind,
				columns,
				catalog
			),
			nil
		)
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

--- Approximate row counts for a namespace, by set name (ADR-0038); empty where
--- the engine keeps no estimate, so a client shows no number rather than a wrong one.
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

--- Sets whose name contains `pattern`, as a flat answer: a scan of the
--- snapshot when there is one, a server-side search otherwise.
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

--- Sweep this ref's catalog, or one namespace of it folded into what is known
--- (ADR-0038); anything shallower replaces the whole instance.
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

--- Forget what is cached for this ref's connection; the client decides when.
function M.forget(ref)
	local connection = server_of(ref)
	if not connection then
		return false
	end
	schema.invalidate(connection)
	return true
end

return M
