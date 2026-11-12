-- A whole swept catalog on disk, replaced only by :NGripIntrospect and never expiring on its
-- own, so walking the tree costs nothing across restarts. The Java side writes the file;
-- nothing the size of a catalog crosses the request protocol.
local neogrip = require("neogrip")

local M = {}

--- @class neogrip.Snapshot
--- @field at integer os.time() when it was taken
--- @field product string|nil the server's own version string
--- @field catalog string|nil
--- @field parallel boolean|nil whether the sweep used more than one connection
--- @field partial boolean|nil true when the detail pass ran out of its budget
--- @field schemas table[] { name, tables }

-- A catalog is megabytes of JSON; decoding it once a session is the difference between an
-- instant picker and one that stutters on every keystroke.
local loaded = {}

local function key_of(connection, catalog)
	return ("%s|%s"):format(connection.id, tostring(catalog or ""))
end

local function dir()
	local path = neogrip.state_dir .. "/catalog"
	vim.fn.mkdir(path, "p")
	return path
end

--- Two hashes rather than one of the pair, so a connection's catalogs can be found by prefix when dropped.
function M.path(connection, catalog)
	return ("%s/%s-%s.json"):format(
		dir(),
		vim.fn.sha256(connection.id),
		vim.fn.sha256(tostring(catalog or ""))
	)
end

--- An index built once per decode; without it every preview keystroke walks every table.
local function indexed(snapshot)
	local by_schema = {}
	local counts = { schemas = 0, tables = 0, columns = 0, details = 0 }
	for _, schema in ipairs(snapshot.schemas or {}) do
		local by_table = {}
		for _, entry in ipairs(schema.tables or {}) do
			by_table[tostring(entry.name or "")] = entry
			counts.tables = counts.tables + 1
			counts.columns = counts.columns + #(entry.columns or {})
			if entry.details then
				counts.details = counts.details + 1
			end
		end
		by_schema[tostring(schema.name or "")] = { tables = schema.tables or {}, by_table = by_table }
		counts.schemas = counts.schemas + 1
	end
	snapshot.index = { by_schema = by_schema, counts = counts }
	return snapshot
end

--- nil for a half-written or hand-edited file: every caller falls back to asking the server.
--- @return table|nil
local function read_snapshot(path)
	if vim.fn.filereadable(path) ~= 1 then
		return nil
	end
	local read, lines = pcall(vim.fn.readfile, path)
	if not read then
		return nil
	end
	local decoded, snapshot = pcall(vim.json.decode, table.concat(lines, "\n"))
	if not decoded or type(snapshot) ~= "table" or type(snapshot.schemas) ~= "table" then
		return nil
	end
	return snapshot
end

--- @return neogrip.Snapshot|nil
function M.load(connection, catalog)
	if not connection then
		return nil
	end
	local key = key_of(connection, catalog)
	local cached = loaded[key]
	if cached ~= nil then
		-- false is "looked, nothing there": the normal pre-introspect state must not send a
		-- caller back to the filesystem on every keystroke.
		return cached or nil
	end

	local snapshot = read_snapshot(M.path(connection, catalog))
	if not snapshot then
		loaded[key] = false
		return nil
	end
	loaded[key] = indexed(snapshot)
	return loaded[key]
end

--- Forget the decoded copy, so the next read picks up a freshly written file.
function M.reload(connection, catalog)
	loaded[key_of(connection, catalog)] = nil
	return M.load(connection, catalog)
end

--- Only the tests need this; the Java side writes the real thing straight to M.path.
function M.save(connection, catalog, snapshot)
	snapshot.at = snapshot.at or os.time()
	snapshot.catalog = snapshot.catalog or catalog
	loaded[key_of(connection, catalog)] = nil
	return pcall(vim.fn.writefile, { vim.json.encode(snapshot) }, M.path(connection, catalog))
end

--- Fold a one-schema snapshot into the catalog (ADR-0038): re-reading one schema after a
--- migration must not throw away the other forty. The derived index is dropped before
--- writing; persisting it would double the file.
--- @return boolean, string|nil
function M.merge_from(connection, catalog, path, schema_name)
	local partial = read_snapshot(path)
	if not partial then
		return false, "the scoped sweep wrote nothing readable"
	end

	local snapshot = M.load(connection, catalog)
	if not snapshot then
		return M.save(connection, catalog, { catalog = catalog, schemas = partial.schemas })
	end

	local wanted = tostring(schema_name)
	local body = nil
	for _, schema in ipairs(partial.schemas) do
		if tostring(schema.name) == wanted then
			body = schema
		end
	end

	local kept = {}
	for _, schema in ipairs(snapshot.schemas) do
		if tostring(schema.name) ~= wanted then
			kept[#kept + 1] = schema
		end
	end
	-- A schema the sweep found nothing for is dropped: that is how a dropped schema reports itself.
	if body then
		kept[#kept + 1] = body
	end

	snapshot.schemas = kept
	snapshot.index = nil
	snapshot.at = partial.at or os.time()
	return M.save(connection, catalog, snapshot)
end

--- Drop every catalog taken for this connection, or every one of them.
function M.clear(connection)
	if not connection then
		loaded = {}
		pcall(vim.fn.delete, neogrip.state_dir .. "/catalog", "rf")
		return
	end
	local prefix = connection.id .. "|"
	for key in pairs(loaded) do
		if key:sub(1, #prefix) == prefix then
			loaded[key] = nil
		end
	end
	local pattern = ("%s/%s-*.json"):format(dir(), vim.fn.sha256(connection.id))
	for _, path in ipairs(vim.fn.glob(pattern, false, true)) do
		pcall(vim.fn.delete, path)
	end
end

--- What :NGripDoctor reports.
--- @return table|nil { at, age_seconds, product, schemas, tables, columns, details, partial, path }
function M.stat(connection, catalog)
	local snapshot = M.load(connection, catalog)
	if not snapshot then
		return nil
	end
	local counts = snapshot.index.counts
	return {
		at = snapshot.at,
		age_seconds = os.time() - (snapshot.at or os.time()),
		product = snapshot.product,
		parallel = snapshot.parallel,
		partial = snapshot.partial,
		schemas = counts.schemas,
		tables = counts.tables,
		columns = counts.columns,
		details = counts.details,
		path = M.path(connection, catalog),
	}
end

--- @return table[]|nil in the shape the schemas level reads
function M.schemas(connection, catalog)
	local snapshot = M.load(connection, catalog)
	if not snapshot then
		return nil
	end
	local list = {}
	for _, schema in ipairs(snapshot.schemas or {}) do
		list[#list + 1] = { name = schema.name }
	end
	return #list > 0 and list or nil
end

local function schema_of(connection, catalog, schema_name)
	local snapshot = M.load(connection, catalog)
	if not snapshot then
		return nil
	end
	-- An engine with no schemas reports "" where the caller passes nil.
	return snapshot.index.by_schema[tostring(schema_name or "")]
end

--- @return table[]|nil { name, kind, columns }
function M.tables(connection, catalog, schema_name)
	local schema = schema_of(connection, catalog, schema_name)
	return schema and schema.tables or nil
end

local function table_of(connection, catalog, schema_name, table_name)
	local schema = schema_of(connection, catalog, schema_name)
	return schema and schema.by_table[tostring(table_name or "")] or nil
end

--- An empty list is not an answer: zero columns means the sweep never filled the entry in
--- (a MongoDB collection's fields come from sampling), and returning the empty list once
--- made that sampling unreachable (ADR-0029).
--- @return table[]|nil
function M.columns(connection, catalog, schema_name, table_name)
	local entry = table_of(connection, catalog, schema_name, table_name)
	local columns = entry and entry.columns
	if columns and #columns > 0 then
		return columns
	end
	return nil
end

--- One table, in the shape schema.details answers with; nil when the sweep's detail pass
--- spent its budget before reaching this table, and the caller then asks the server.
--- @return table|nil { rows, primary_key, indexes, foreign_keys, referenced_by }
function M.details(connection, catalog, schema_name, table_name)
	local entry = table_of(connection, catalog, schema_name, table_name)
	if not entry or not entry.details then
		return nil
	end
	return {
		rows = entry.columns or {},
		primary_key = entry.primary_key or {},
		primary_key_name = entry.primary_key_name,
		remarks = entry.remarks,
		indexes = entry.indexes or {},
		foreign_keys = entry.foreign_keys or {},
		referenced_by = entry.referenced_by or {},
	}
end

--- Fold freshly fetched details into memory, so a skipped table is asked for once, not once per preview.
function M.merge_details(connection, catalog, schema_name, table_name, details)
	local entry = table_of(connection, catalog, schema_name, table_name)
	if not entry or not details then
		return false
	end
	entry.columns = details.rows or entry.columns
	entry.primary_key = details.primary_key or {}
	entry.indexes = details.indexes or {}
	entry.foreign_keys = details.foreign_keys or {}
	entry.referenced_by = details.referenced_by or {}
	entry.details = true
	return true
end

return M
