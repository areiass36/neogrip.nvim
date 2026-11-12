-- Export everything under one catalog ref as a runnable DDL script: every
-- non-comment line is SQL that runs top to bottom against an empty schema,
-- and every answer comes from the server at the moment of the export, never
-- from the swept store or the TTL cache (ADR-0047).
local connections = require("neogrip.connections")
local ddl = require("neogrip.catalog.ddl")
local dsn = require("neogrip.gripd.dsn")
local gripd = require("neogrip.gripd")
local notify = require("neogrip.notify")
local schema = require("neogrip.catalog")
local tree = require("neogrip.catalog.tree")

local M = {}

--- How NativeDdl.java answers for this engine; the two tables must agree
--- (ADR-0047): an engine missing here degrades to a rendered-only export.
--- sqlite's text carries the table alone - an index is its own row of
--- sqlite_master - so its index statements are still rendered.
local NATIVE = {
	mysql = "complete",
	mariadb = "complete",
	trino = "complete",
	sqlite = "table",
	postgres = "fragments",
}

local function message_of(err)
	local text = type(err) == "table" and (err.message or vim.inspect(err)) or tostring(err)
	-- A driver's message can quote the DSN it failed on; see Secret Rules.
	return dsn.redact(text)
end

--- The counts, spelled for the header and the notification alike.
local function spelled(counts)
	local parts = {}
	local function add(count, word)
		if count > 0 then
			parts[#parts + 1] = ("%d %s%s"):format(count, word, count > 1 and "s" or "")
		end
	end
	add(counts.tables, "table")
	add(counts.views, "view")
	add(counts.collections, "collection")
	if counts.skipped > 0 then
		parts[#parts + 1] = ("%d skipped"):format(counts.skipped)
	end
	return table.concat(parts, ", ")
end

--- The engine's text as script lines, ending in the terminator the engine's
--- SHOW CREATE answer does not carry.
local function native_lines(text)
	local lines = {}
	for _, line in ipairs(vim.split(text, "\n", { plain = true })) do
		lines[#lines + 1] = (line:gsub("%s+$", ""))
	end
	while #lines > 0 and lines[#lines] == "" do
		table.remove(lines)
	end
	if #lines > 0 and not lines[#lines]:match(";$") then
		lines[#lines] = lines[#lines] .. ";"
	end
	return lines
end

--- One gripd question, dropped on the floor once the export is finished or
--- cancelled: the server still answers, nobody is listening.
local function request(ctx, method, params, on_answer)
	if ctx.state.finished or ctx.state.cancelled then
		return
	end
	gripd.request(ctx.connection, method, params, function(result, err)
		if ctx.state.finished or ctx.state.cancelled then
			return
		end
		on_answer(result, err)
	end)
end

--- A whole listing, following `after` until the server stops truncating
--- (ADR-0038); rows arrive ordered by name and stay that way.
local function listing(ctx, method, base, on_row, done)
	local function fetch(after)
		local params = vim.tbl_extend("force", {}, base)
		params.after = after
		request(ctx, method, params, function(result, err)
			if err then
				return done(err)
			end
			local last = nil
			for _, row in ipairs((result or {}).rows or {}) do
				on_row(row)
				last = row.name
			end
			if result and result.truncated == true and last ~= nil then
				return fetch(last)
			end
			done(nil)
		end)
	end
	fetch(nil)
end

--- The (catalog, namespace) scopes under this ref, enumerated with the same
--- paged listings the tree uses.
local function list_scopes(ctx, ref, done)
	local connection = ctx.connection
	if ref.namespace or ref.set then
		local catalog, namespace = tree.qualifiers(connection, ref)
		return done({ { catalog = catalog, namespace = namespace } }, nil)
	end

	local function namespaces_of(catalog, scopes, next_step)
		listing(ctx, "catalog/schemas", { catalog = catalog }, function(row)
			scopes[#scopes + 1] = { catalog = catalog, namespace = row.name }
		end, next_step)
	end

	if ref.instance then
		local catalog, namespace = tree.qualifiers(connection, ref)
		if namespace then
			-- MySQL, MariaDB and MongoDB report the database as a catalog, so
			-- the namespace slot already holds it and there is nothing to list.
			return done({ { catalog = catalog, namespace = namespace } }, nil)
		end
		local scopes = {}
		return namespaces_of(ref.instance, scopes, function(err)
			done(err == nil and scopes or nil, err)
		end)
	end

	-- A server ref: walk down whatever the shape has next.
	local shape = tree.shape(connection)
	local next_level = nil
	for _, entry in ipairs(shape.levels) do
		if entry.level ~= "server" then
			next_level = entry
			break
		end
	end
	if next_level == nil then
		return done({}, nil)
	end
	if next_level.level == "instance" then
		-- Only Trino reaches here: everywhere else the server ref was refused
		-- before any request went out.
		local instances = {}
		return listing(ctx, "catalog/catalogs", {}, function(row)
			instances[#instances + 1] = row.name
		end, function(err)
			if err then
				return done(nil, err)
			end
			local scopes = {}
			local function next_instance(index)
				if index > #instances then
					return done(scopes, nil)
				end
				namespaces_of(instances[index], scopes, function(inner_err)
					if inner_err then
						return done(nil, inner_err)
					end
					next_instance(index + 1)
				end)
			end
			next_instance(1)
		end)
	end
	local catalog, namespace = tree.qualifiers(connection, {})
	if next_level.level == "namespace" then
		local scopes = {}
		return namespaces_of(catalog, scopes, function(err)
			done(err == nil and scopes or nil, err)
		end)
	end
	done({ { catalog = catalog, namespace = namespace } }, nil)
end

--- Every set in every scope, in listing order; a set ref keeps only its own.
local function list_sets(ctx, ref, scopes, done)
	local sets = {}
	local function next_scope(index)
		if index > #scopes then
			return done(sets, nil)
		end
		local scope = scopes[index]
		listing(ctx, "catalog/tables", { catalog = scope.catalog, schema = scope.namespace }, function(row)
			if ref.set == nil or tostring(row.name) == tostring(ref.set) then
				sets[#sets + 1] = {
					catalog = scope.catalog,
					namespace = scope.namespace,
					name = row.name,
					kind = row.kind or "table",
				}
			end
		end, function(err)
			if err then
				return done(nil, err)
			end
			next_scope(index + 1)
		end)
	end
	next_scope(1)
end

--- details and, where the engine has one, the native text, one set at a time:
--- sequential is what makes a cancel between requests mean something.
local function fetch_sets(ctx, sets, index, done)
	local set = sets[index]
	if set == nil then
		return done()
	end
	local function next_set()
		fetch_sets(ctx, sets, index + 1, done)
	end
	if set.kind == "collection" then
		return next_set()
	end

	local params = { catalog = set.catalog, schema = set.namespace, table = set.name }
	local function ask_native()
		if NATIVE[ctx.connection.driver] == nil then
			return next_set()
		end
		request(ctx, "catalog/nativeDdl", params, function(result, err)
			if err == nil then
				local text = result and result.ddl
				if text ~= vim.NIL and text ~= "" and type(text) == "string" then
					set.native = text
				end
			end
			-- A refusal only takes away the better answer: the definition is
			-- rendered from the metadata instead.
			next_set()
		end)
	end

	if set.kind == "view" then
		return ask_native()
	end
	request(ctx, "catalog/details", params, function(result, err)
		if err then
			set.skipped = message_of(err)
			return next_set()
		end
		set.details = {
			rows = result.rows or {},
			primary_key = result.primary_key or {},
			primary_key_name = result.primary_key_name,
			remarks = result.remarks,
			indexes = result.indexes or {},
			foreign_keys = result.foreign_keys or {},
			referenced_by = result.referenced_by or {},
		}
		ask_native()
	end)
end

local function key_of(namespace, name)
	return tostring(namespace) .. "\1" .. tostring(name)
end

--- Tables dependencies-first, smallest name among the ready ones next, so the
--- order is total and two exports of one unchanged schema are byte-identical.
--- A self-reference is not a dependency; a cycle is broken at the smallest
--- remaining name; a foreign key leaving the export is kept and noted.
local function ordered_tables(connection, tables)
	local exported = {}
	for _, set in ipairs(tables) do
		exported[key_of(set.namespace, set.name)] = true
	end

	local pending = {}
	for _, set in ipairs(tables) do
		set.notes = {}
		set.deps = {}
		local seen = {}
		for _, fk in ipairs(set.details.foreign_keys or {}) do
			local target_namespace = fk.schema or set.namespace
			local target = key_of(target_namespace, fk.table)
			if target ~= key_of(set.namespace, set.name) and not seen[target] then
				seen[target] = true
				if exported[target] then
					set.deps[#set.deps + 1] = target
				else
					set.notes[#set.notes + 1] = ("-- %s: foreign key references %s outside this export."):format(
						schema.qualify(connection, set.namespace, set.name, set.catalog),
						schema.qualify(connection, target_namespace, fk.table, set.catalog)
					)
				end
			end
		end
		table.sort(set.deps)
		pending[#pending + 1] = set
	end
	table.sort(pending, function(left, right)
		return key_of(left.namespace, left.name) < key_of(right.namespace, right.name)
	end)

	local emitted, order = {}, {}
	while #pending > 0 do
		local picked = nil
		for position, set in ipairs(pending) do
			local ready = true
			for _, dep in ipairs(set.deps) do
				if not emitted[dep] then
					ready = false
					break
				end
			end
			if ready then
				picked = position
				break
			end
		end
		local broken = picked == nil
		local set = table.remove(pending, picked or 1)
		if broken then
			for _, dep in ipairs(set.deps) do
				if not emitted[dep] then
					local target_namespace, target_name = dep:match("^(.-)\1(.*)$")
					set.notes[#set.notes + 1] = ("-- cycle broken: %s references %s, created later in this file."):format(
						schema.qualify(connection, set.namespace, set.name, set.catalog),
						schema.qualify(connection, target_namespace, target_name, set.catalog)
					)
				end
			end
		end
		emitted[key_of(set.namespace, set.name)] = true
		order[#order + 1] = set
	end
	return order
end

--- One table's statements, composed by the engine's native shape (ADR-0047).
local function table_lines(connection, set)
	local shape = NATIVE[connection.driver]
	if shape == "complete" and set.native then
		return native_lines(set.native)
	end
	if shape == "table" and set.native then
		local lines = native_lines(set.native)
		vim.list_extend(lines, ddl.index_statements(connection, set.namespace, set.name, set.details))
		return lines
	end
	if shape == "fragments" and set.native then
		-- The native fragments re-add every constraint, so the rendered half
		-- carries the columns alone or the replay would declare each key twice.
		local lines = ddl.create_table(connection, set.namespace, set.name, set.details, { keys = false })
		lines[#lines + 1] = ""
		vim.list_extend(lines, native_lines(set.native))
		return lines
	end
	local lines = ddl.create_table(connection, set.namespace, set.name, set.details)
	vim.list_extend(lines, ddl.index_statements(connection, set.namespace, set.name, set.details))
	return lines
end

--- The whole script, from what the fetch gathered.
local function compose(ctx, ref, sets)
	local connection = ctx.connection
	local tables, views, collections, skipped = {}, {}, {}, {}
	for _, set in ipairs(sets) do
		if set.skipped then
			skipped[#skipped + 1] = set
		elseif set.kind == "view" then
			views[#views + 1] = set
		elseif set.kind == "collection" then
			collections[#collections + 1] = set
		else
			tables[#tables + 1] = set
		end
	end
	local counts = {
		tables = #tables,
		views = #views,
		collections = #collections,
		skipped = #skipped,
	}

	local lines = { ("-- neogrip export: %s"):format(tree.id(ref)) }
	local summary = spelled(counts)
	lines[#lines + 1] = summary == "" and "-- nothing to export: no sets reported."
		or ("-- %s"):format(summary)
	if connection.driver == "mssql" or connection.driver == "duckdb" then
		lines[#lines + 1] = "-- CHECK constraints are not reported by this engine's metadata."
	end
	if connection.driver == "duckdb" then
		-- The driver answers getImportedKeys with nothing; see doc/internals.md#schema-and-tree.
		lines[#lines + 1] = "-- Foreign keys are not reported by this engine's driver."
	end

	local function section(section_lines)
		while #section_lines > 0 and section_lines[#section_lines] == "" do
			table.remove(section_lines)
		end
		if #section_lines > 0 then
			lines[#lines + 1] = ""
			vim.list_extend(lines, section_lines)
		end
	end

	for _, set in ipairs(skipped) do
		section({
			("-- %s: skipped (%s)"):format(
				schema.qualify(connection, set.namespace, set.name, set.catalog),
				set.skipped
			),
		})
	end
	for _, set in ipairs(ordered_tables(connection, tables)) do
		local body = vim.list_slice(set.notes, 1, #set.notes)
		vim.list_extend(body, table_lines(connection, set))
		section(body)
	end
	for _, set in ipairs(views) do
		if set.native then
			section(native_lines(set.native))
		else
			section({
				("-- view %s: the engine does not hand back its definition."):format(
					schema.qualify(connection, set.namespace, set.name, set.catalog)
				),
			})
		end
	end
	for _, set in ipairs(collections) do
		section({
			("-- %s: a collection has no DDL; the catalog reports a sample of its fields, not a schema."):format(
				tostring(set.name)
			),
		})
	end

	return lines, counts
end

--- Temp-plus-atomic-rename, the rule ADR-0010 set for bulk data.
local function write_script(path, lines)
	local tmp = path .. ".tmp"
	local ok, code = pcall(vim.fn.writefile, lines, tmp)
	if not ok or code ~= 0 then
		return ("could not write %s"):format(tmp)
	end
	local renamed = vim.uv.fs_rename(tmp, path)
	if not renamed then
		pcall(vim.fn.delete, tmp)
		return ("could not move the script onto %s"):format(path)
	end
	return nil
end

--- The level a ref points at, by its deepest key.
local function level_of(ref)
	for _, level in ipairs({ "object", "attribute", "set", "namespace", "instance" }) do
		if ref[level] ~= nil then
			return level
		end
	end
	return "server"
end

--- Write the DDL of everything under `target` to `opts.path`.
---
--- The target is a tree node id or a ref; sets, namespaces, instances and
--- whole file databases are exportable, a row or a column is not, and a
--- server whose instances need reopening the connection is refused. The
--- callback fires exactly once in every path, a cancel included; with no
--- callback, the notifier reports the counts.
---
--- @param target string|table a tree node id, or the ref itself
--- @param opts table { path }
--- @param callback fun(summary: table|nil, err: table|nil)|nil
--- @return table handle with :cancel()
function M.script(target, opts, callback)
	opts = opts or {}
	local state = { finished = false, cancelled = false }

	local function finish(summary, err)
		if state.finished then
			return
		end
		state.finished = true
		if callback then
			return callback(summary, err)
		end
		if err then
			notify.send(("export failed: %s"):format(message_of(err)), vim.log.levels.ERROR)
		else
			notify.send(
				("exported %s to %s"):format(
					spelled(summary) == "" and "nothing" or spelled(summary),
					summary.path
				)
			)
		end
	end

	local handle = {
		cancel = function()
			if state.finished then
				return false
			end
			state.cancelled = true
			finish(nil, { message = "export cancelled" })
			return true
		end,
	}

	local ref = target
	if type(target) == "string" then
		local decoded, reason = tree.ref_of(target)
		if not decoded then
			finish(nil, { message = reason })
			return handle
		end
		ref = decoded
	end

	local connection = connections.get(ref and ref.server)
	if not connection then
		finish(nil, { message = ("no connection named %s"):format(tostring(ref and ref.server)) })
		return handle
	end
	if type(opts.path) ~= "string" or opts.path == "" then
		finish(nil, { message = "an export needs a path" })
		return handle
	end

	local level = level_of(ref)
	if level == "object" or level == "attribute" then
		finish(nil, {
			message = level == "object" and "a row has no definition to export"
				or "a column has no definition to export",
		})
		return handle
	end
	if level == "server" then
		local shape = tree.shape(connection)
		local below = shape.levels[2]
		if below and below.level == "instance" and below.reconnects then
			finish(nil, {
				message = "a whole server cannot be exported: its instances need reopening the connection",
			})
			return handle
		end
	end

	local ctx = { connection = connection, state = state }

	schema.ensure_connected(connection, function(connect_err)
		if state.finished or state.cancelled then
			return
		end
		if connect_err then
			return finish(nil, { message = message_of(connect_err) })
		end
		list_scopes(ctx, ref, function(scopes, scope_err)
			if scope_err then
				return finish(nil, { message = message_of(scope_err) })
			end
			list_sets(ctx, ref, scopes, function(sets, set_err)
				if set_err then
					return finish(nil, { message = message_of(set_err) })
				end
				if ref.set and #sets == 0 then
					return finish(nil, { message = ("no set named %s"):format(tostring(ref.set)) })
				end
				fetch_sets(ctx, sets, 1, function()
					if state.finished or state.cancelled then
						return
					end
					local lines, counts = compose(ctx, ref, sets)
					local write_err = write_script(opts.path, lines)
					if write_err then
						return finish(nil, { message = write_err })
					end
					counts.path = opts.path
					finish(counts, nil)
				end)
			end)
		end)
	end)

	return handle
end

return M
