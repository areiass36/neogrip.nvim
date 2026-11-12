-- A table or a schema as a document you can :edit: a neogrip:// name is read
-- by a BufReadCmd, every segment percent-encoded, empty where the engine has no catalog or schema.
local icons = require("neogrip.ui.icons")
local schema = require("neogrip.catalog")

local M = {}

-- Not the default encoding; see doc/internals.md#document-buffers.
local ENCODING = "rfc2396"

-- How many tables a schema listing spells out before falling back to a count.
local LISTED = 40

-- Lines the caller already has in hand, so an answer fetched before opening is
-- not paid for twice.
local pending = {}

-- M.setup registers the reader; M.open makes sure it has run.
local reading = false

--- A passing note as a SQL comment, flattened; see doc/internals.md#document-buffers.
local function comment(text)
	return "-- " .. (tostring(text):gsub("%s+", " "))
end

local function encode(value)
	return vim.uri_encode(tostring(value or ""), ENCODING)
end

local function decode(value)
	local ok, decoded = pcall(vim.uri_decode, value)
	return ok and decoded or value
end

--- Accept a connection table or just its id.
local function id_of(connection)
	if type(connection) == "table" then
		return connection.id
	end
	return connection
end

--- @return string
function M.table_uri(connection, catalog, schema_name, table_name)
	return ("neogrip://table/%s/%s/%s/%s"):format(
		encode(id_of(connection)),
		encode(catalog),
		encode(schema_name),
		encode(table_name)
	)
end

--- @return string
function M.schema_uri(connection, catalog, schema_name)
	return ("neogrip://schema/%s/%s/%s"):format(
		encode(id_of(connection)),
		encode(catalog),
		encode(schema_name)
	)
end

--- What a neogrip:// name means, or nil when it is not one of ours; a vanished
--- connection reads as nil so a stale session buffer degrades into a note.
--- @return table|nil { kind, connection, catalog, schema, table }
function M.parse(uri)
	if type(uri) ~= "string" then
		return nil
	end
	local kind, rest = uri:match("^neogrip://(%a+)/(.*)$")
	if kind ~= "table" and kind ~= "schema" then
		return nil
	end
	local segments = vim.split(rest, "/", { plain = true })
	if #segments ~= (kind == "table" and 4 or 3) then
		return nil
	end
	local connection = require("neogrip.connections").get(decode(segments[1]))
	if not connection then
		return nil
	end
	-- Empty back to nil: nil is how the module spells "no catalog" and "no schema".
	local catalog, schema_name = decode(segments[2]), decode(segments[3])
	if catalog == "" then
		-- The sweep is keyed by the catalog the connection means, so fill it in.
		catalog = schema.catalog_of(connection)
	end
	return {
		kind = kind,
		connection = connection,
		catalog = catalog ~= "" and catalog or nil,
		schema = schema_name ~= "" and schema_name or nil,
		table = segments[4] and decode(segments[4]) or nil,
	}
end

-- What a document draws beside a set of each kind.
local KIND_ICON = {
	table = icons.table,
	temp = icons.table,
	collection = icons.table,
	view = icons.branch,
	matview = icons.branch,
	foreign = icons.branch,
}

local KIND_LABEL = {
	table = { "table", "tables" },
	temp = { "temporary table", "temporary tables" },
	collection = { "collection", "collections" },
	view = { "view", "views" },
	matview = { "materialized view", "materialized views" },
	foreign = { "foreign table", "foreign tables" },
}

-- Tables first and the derived things after, whatever order the driver answered in.
local RANK = { table = 1, view = 2, matview = 3, foreign = 4, temp = 5, collection = 6 }

local function label_of(kind, count)
	local label = KIND_LABEL[kind]
	if not label then
		return ("%d %s"):format(count, kind)
	end
	return ("%d %s"):format(count, count == 1 and label[1] or label[2])
end

--- How the header names the schema it is listing.
local function title_of(connection, catalog, schema_name)
	local where = schema_name
	if where == nil or where == "" then
		-- An engine with no schemas: its one database is the thing being listed.
		where = catalog
	end
	if where == nil or where == "" then
		return tostring(connection.name or connection.id or "?")
	end
	return schema.quote(connection.driver, where)
end

--- One schema, as a listing of comments; shared with the preview pane, so
--- resting on a schema and opening it describe it the same way.
--- @param tables table[]|nil the schema's tables in the shape the store keeps;
--- read from the swept catalog when not given
--- @return string[]
function M.schema_lines(connection, catalog, schema_name, tables)
	connection = connection or {}
	-- The sweep is keyed by the catalog the connection means, so fill it in.
	catalog = catalog or schema.catalog_of(connection)
	local known = tables
	if not known and connection.id then
		known = schema.tables_known(connection, catalog, schema_name)
	end
	local title = title_of(connection, catalog, schema_name)

	if not known then
		return {
			comment(title),
			"-- Nothing has been read for this schema yet; :NGripIntrospect sweeps it in.",
		}
	end
	if #known == 0 then
		return { comment(("%s: empty"):format(title)) }
	end

	local counts, kinds = {}, {}
	for _, record in ipairs(known) do
		local kind = tostring(record.kind or "table")
		if counts[kind] == nil then
			kinds[#kinds + 1] = kind
		end
		counts[kind] = (counts[kind] or 0) + 1
	end
	table.sort(kinds, function(left, right)
		local first, second = RANK[left] or 99, RANK[right] or 99
		if first ~= second then
			return first < second
		end
		return left < right
	end)

	local summary = {}
	for _, kind in ipairs(kinds) do
		summary[#summary + 1] = label_of(kind, counts[kind])
	end

	local width = 1
	for index, record in ipairs(known) do
		if index > LISTED then
			break
		end
		width = math.max(width, #tostring(record.name or ""))
	end
	-- Capped so one pathological name does not push the counts off the pane.
	width = math.min(width, 48)

	local lines = { comment(("%s: %s"):format(title, table.concat(summary, ", "))), "--" }
	-- In the driver's reported order: reordering would stop matching the level below.
	for index, record in ipairs(known) do
		if index > LISTED then
			lines[#lines + 1] = "--"
			lines[#lines + 1] = ("--   %d more"):format(#known - LISTED)
			break
		end
		local columns = #(record.columns or {})
		lines[#lines + 1] = ("--   %s %-" .. width .. "s  %s"):format(
			KIND_ICON[tostring(record.kind or "table")] or icons.file,
			tostring(record.name or ""),
			columns > 0 and ("%d column%s"):format(columns, columns == 1 and "" or "s") or "-"
		)
	end
	return lines
end

--- The engine's own DDL for a table, when this driver can produce one; the
--- callback fires only when there is something to show.
--- @param callback fun(ddl: string)
function M.native_ddl(connection, context, table_name, callback)
	if type(schema.native_ddl) ~= "function" then
		return
	end
	pcall(schema.native_ddl, connection, context.schema, table_name, function(ddl, _err)
		if type(ddl) == "string" and vim.trim(ddl) ~= "" then
			pcall(callback, ddl)
		end
	end, context.catalog)
end

--- Replace a document's contents, leaving it read-only again.
function M.fill(bufnr, lines)
	if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
		return false
	end
	vim.bo[bufnr].modifiable = true
	vim.bo[bufnr].readonly = false
	local ok = pcall(vim.api.nvim_buf_set_lines, bufnr, 0, -1, false, lines)
	vim.bo[bufnr].modifiable = false
	vim.bo[bufnr].readonly = true
	vim.bo[bufnr].modified = false
	return ok
end

--- Everything a document buffer is, besides its lines.
local function dress(bufnr, parsed)
	vim.bo[bufnr].buftype = "nofile"
	vim.bo[bufnr].swapfile = false
	-- A buffer with no filetype was why the old DDL window came out grey.
	vim.bo[bufnr].filetype = "sql"
	vim.bo[bufnr].modified = false
	vim.bo[bufnr].modifiable = false
	vim.bo[bufnr].readonly = true

	local connection = parsed and parsed.connection
	if connection then
		-- Without the dialect layer, engine functions highlight as generic ANSI SQL.
		pcall(require("neogrip.ui.syntax").attach, bufnr, connection.driver)
		pcall(require("neogrip.connections.resolve").bind, bufnr, connection.id)
	end
end

--- The definition as catalog/ddl.lua writes it; required late to keep the
--- dependency one-way.
local function definition(parsed, details)
	local ok, lines =
		pcall(require("neogrip.catalog.ddl").details, parsed.connection, parsed.schema, parsed.table, details)
	if ok and type(lines) == "table" then
		return lines
	end
	return { comment(lines) }
end

--- Fill `bufnr` with the document `uri` names; a BufReadCmd must leave a
--- usable buffer synchronously, so a placeholder goes up first.
--- @param on_done fun(lines: string[])|nil fires once, with what was written
function M.render(uri, bufnr, on_done)
	local function finish(lines)
		M.fill(bufnr, lines)
		if on_done then
			on_done(lines)
		end
	end

	local ready = pending[uri]
	if ready then
		return finish(ready)
	end

	local parsed = M.parse(uri)
	if not parsed then
		return finish({
			comment(uri),
			"-- No connection of that name is configured any more.",
		})
	end

	if parsed.kind == "schema" then
		local ok, lines = pcall(M.schema_lines, parsed.connection, parsed.catalog, parsed.schema)
		return finish(ok and lines or { comment(lines) })
	end

	M.fill(bufnr, { comment(("reading %s..."):format(tostring(parsed.table))) })

	schema.details(parsed.connection, parsed.schema, parsed.table, function(details, err)
		if err or type(details) ~= "table" then
			return finish({
				comment(schema.qualify(parsed.connection, parsed.schema, parsed.table)),
				comment(err or "the server reported nothing about this table"),
			})
		end
		local lines = definition(parsed, details)
		finish(lines)

		-- The server's own DDL is a second round trip, appended when it lands
		-- rather than holding the buffer up for it.
		M.native_ddl(parsed.connection, parsed, parsed.table, function(ddl)
			-- A copy: the details may be the cache's own table, and this field
			-- must not be written back to it.
			local whole = vim.tbl_extend("force", {}, details, { native_ddl = ddl })
			M.fill(bufnr, (definition(parsed, whole)))
		end)
	end, parsed.catalog)
end

--- Matched by full name: bufnr() takes a pattern and could return a different
--- table's buffer.
local function buffer_named(name)
	for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
		if vim.api.nvim_buf_get_name(bufnr) == name then
			return bufnr
		end
	end
	return nil
end

local function window_showing(bufnr)
	for _, winid in ipairs(vim.api.nvim_list_wins()) do
		if vim.api.nvim_win_get_buf(winid) == bufnr then
			return winid
		end
	end
	return nil
end

local function switch(uri, existing)
	if existing and vim.api.nvim_buf_is_loaded(existing) then
		-- Only :buffer sets the alternate file, which makes <C-^> the way back.
		return vim.cmd(("buffer %d"):format(existing))
	end
	if not existing then
		-- Made here because :edit reuses an empty unnamed buffer, renaming what
		-- you were looking at instead of leaving it as the alternate file.
		vim.fn.bufadd(uri)
	end
	-- File magic off, so % and # in a percent-encoded name reach :edit as spelled.
	return vim.cmd({ cmd = "edit", args = { uri }, magic = { file = false } })
end

--- Open `uri` in the current window, replacing it the way :edit would; a
--- window already showing it is focused instead.
--- @param lines string[]|nil lines the caller has already rendered
--- @return integer|nil bufnr, integer|nil winid
function M.open(uri, lines)
	-- A caller can be loaded and used before db/init.lua registers the reader.
	if not reading then
		M.setup()
	end

	local bufnr = buffer_named(uri)
	local winid = bufnr and window_showing(bufnr) or nil

	if winid then
		vim.api.nvim_set_current_win(winid)
	else
		pending[uri] = lines
		local ok = pcall(switch, uri, bufnr)
		if not ok then
			-- :edit can refuse to switch; see doc/internals.md#document-buffers.
			bufnr = buffer_named(uri)
			if not bufnr then
				bufnr = vim.api.nvim_create_buf(true, false)
				pcall(vim.api.nvim_buf_set_name, bufnr, uri)
			end
			if not pcall(vim.api.nvim_win_set_buf, 0, bufnr) then
				pending[uri] = nil
				return nil, nil
			end
			dress(bufnr, M.parse(uri))
			pcall(M.render, uri, bufnr)
		end
		pending[uri] = nil
		bufnr, winid = vim.api.nvim_get_current_buf(), vim.api.nvim_get_current_win()
	end

	if lines then
		M.fill(bufnr, lines)
	end
	return bufnr, winid
end

--- The identifier a rendered column entry opens with, in this engine's quoting
--- (mongodb quotes with nothing at all).
local function leading_identifier(line)
	local text = vim.trim(line)
	return text:match('^"(.-)"')
		or text:match("^`(.-)`")
		or text:match("^%[(.-)%]")
		or text:match("^([%w_$]+)")
end

--- The 1-based line a column sits on in a rendered table document, or nil;
--- read back out of the text because the renderer may omit or reorder a column.
--- @return integer|nil
function M.column_line(lines, column_name)
	local want = tostring(column_name or "")
	if want == "" then
		return nil
	end
	for index, line in ipairs(lines or {}) do
		if line == ");" then
			-- Past the column list: indexes and inbound references name columns too.
			return nil
		end
		if line:sub(1, 4) == "    " and leading_identifier(line) == want then
			return index
		end
	end
	return nil
end

--- Register the reader. Called from db/init.lua.
function M.setup()
	reading = true
	vim.api.nvim_create_autocmd("BufReadCmd", {
		group = vim.api.nvim_create_augroup("NeogripDocument", { clear = true }),
		pattern = { "neogrip://table/*", "neogrip://schema/*" },
		callback = function(event)
			-- Guarded whole: a BufReadCmd that raises leaves behind a buffer
			-- nothing will ever fill.
			local parsed = M.parse(event.file)
			pcall(dress, event.buf, parsed)
			pcall(M.render, event.file, event.buf)
		end,
	})
end

return M
