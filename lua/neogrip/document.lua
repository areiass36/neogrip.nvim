-- A table or a schema as a document you can :edit.
--
-- The explorer used to name its definition buffer itself and write the lines
-- straight into it. The name looked like a URI but was not one: nothing could
-- be pointed at it, so a jump from a table name in a query, or a buffer
-- recovered from a session, had nowhere to land.
--
-- Here the name is the document. db://table/<conn>/<catalog>/<schema>/<table>
-- and db://schema/<conn>/<catalog>/<schema> are read by a BufReadCmd, so
-- :edit of one fills it whoever asked and whenever -- the explorer's <CR>, a
-- go-to-definition, or :bufdo after a restart all end up in the one buffer.
--
-- Every segment is percent-encoded and the shape is fixed, with catalogs and
-- schemas present as empty segments where the engine has none. Joining them
-- with dots the way the old buffer name did was ambiguous the moment a schema
-- or a table had a dot in it, and leaving the empty ones out made the rest
-- impossible to read positionally.
local icons = require("neogrip.icons")
local schema = require("neogrip.schema")

local M = {}

-- rfc2396 rather than vim.uri_encode's default rfc3986, which leaves "/" and
-- ":" alone -- and a schema called "a/b" would then spell a path separator.
local ENCODING = "rfc2396"

-- How many tables a schema listing spells out. A swept warehouse schema holds
-- hundreds, and a pane you scroll for a minute is no more use than a count.
local LISTED = 40

-- Lines the caller already has in hand, waiting for the BufReadCmd that is
-- about to run. The explorer fetches a table's details before opening it, and
-- a document that went and fetched them again would pay for the same answer
-- twice.
local pending = {}

-- Whether the reader is registered. M.setup is what registers it, but nothing
-- can be read before it has run, so M.open makes sure.
local reading = false

--- Something a document can say in passing, as a SQL comment.
---
--- Flattened, because a driver's message often runs over several lines and a
--- buffer line cannot hold one: unflattened it would raise out of a BufReadCmd
--- instead of being read.
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

--- A caller holding only an id -- a bound buffer, say -- should not have to
--- look the connection up to be able to spell a document's name.
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

--- What a neogrip:// name means, or nil when it is not one of ours.
---
--- A connection that no longer exists reads as nil rather than raising, so a
--- buffer left over from a session whose connections have been edited since
--- degrades into a note instead of an error on startup.
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
	-- Empty back to nil, because nil is how the rest of the module spells "no
	-- catalog" and "no schema": sqlite has neither, mysql has no catalog.
	local catalog, schema_name = decode(segments[2]), decode(segments[3])
	if catalog == "" then
		-- A name spelled by something that only knew the connection -- a jump
		-- from a query buffer, say -- still has to find the sweep, and the
		-- sweep is keyed by the catalog the connection means.
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

-- What the explorer draws beside a table of each kind. The same mapping rather
-- than one of its own: a view has to look like a view in both places.
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

-- Tables first and the derived things after, so the header reads the same way
-- for every engine however the driver happened to order its answer.
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
		-- An engine with no schemas: its one database is the thing being
		-- listed, and for sqlite not even that.
		where = catalog
	end
	if where == nil or where == "" then
		return tostring(connection.name or connection.id or "?")
	end
	return schema.quote(connection.driver, where)
end

--- One schema, as a listing of what is in it.
---
--- Comments throughout: this is a 'sql' buffer like every other document here,
--- and a listing is not a statement. Shared with the preview pane, so resting
--- on a schema and opening it cannot describe it two different ways.
---
--- @param tables table[]|nil the schema's tables, in the shape the store keeps
--- them. Read from the swept catalog when not given, which is the synchronous
--- case; the preview hands in the answer of its own warm-up when there is no
--- sweep to read.
--- @return string[]
function M.schema_lines(connection, catalog, schema_name, tables)
	connection = connection or {}
	-- The sweep is keyed by the catalog the connection means, so a caller that
	-- did not say which reads nothing at all unless it is filled in here.
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
	-- Capped, because one pathological name should not push every column count
	-- off the right of the pane.
	width = math.min(width, 48)

	local lines = { comment(("%s: %s"):format(title, table.concat(summary, ", "))), "--" }
	-- In the order the driver reported them, which JDBC groups by kind and then
	-- by name: reordering here would stop matching the level below.
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

--- The engine's own DDL for a table, when this driver can produce one.
---
--- Optional in every sense: the driver may have nothing of the kind and the
--- server may refuse, so the callback fires only when there is something to
--- show and nothing ever waits on it.
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
	-- A real 'sql' buffer, so treesitter and the dialect layer in
	-- db/dialect.lua highlight it the way a query buffer is highlighted -- a
	-- buffer with no filetype was why the old DDL window came out grey.
	vim.bo[bufnr].filetype = "sql"
	vim.bo[bufnr].modified = false
	vim.bo[bufnr].modifiable = false
	vim.bo[bufnr].readonly = true

	local connection = parsed and parsed.connection
	if connection then
		-- Without the dialect layer this engine's own functions and types are
		-- highlighted as generic ANSI SQL.
		pcall(require("neogrip.dialect").attach, bufnr, connection.driver)
		pcall(require("neogrip.resolve").bind, bufnr, connection.id)
	end

	-- No keymaps here (ADR-0017): leaving the document is :b# or whatever the
	-- user mapped.
end

--- The definition, as the renderer in db/explorer/detail.lua writes it.
---
--- Required here rather than at the top of the file: that module names this one
--- to open what it has rendered, and one of the two has to be the late one.
local function definition(parsed, details)
	local context = {
		connection = parsed.connection,
		catalog = parsed.catalog,
		schema = parsed.schema,
	}
	local ok, lines =
		pcall(require("neogrip.explorer.detail").render, parsed.connection, context, parsed.table, details)
	if ok and type(lines) == "table" then
		return lines, context
	end
	return { comment(lines) }, context
end

--- Fill `bufnr` with the document `uri` names.
---
--- Not necessarily before it returns: a table's definition can be a round trip
--- away and a BufReadCmd has to leave a usable buffer behind synchronously, so
--- a placeholder goes up first and the answer replaces it when it lands.
--- @param on_done fun(lines: string[])|nil fires once, with what was written
function M.render(uri, bufnr, on_done)
	local function finish(lines)
		M.fill(bufnr, lines)
		if on_done then
			on_done(lines)
		end
	end

	-- Already rendered by whoever is opening this: the answer is in hand, so
	-- there is nothing to ask and nothing to wait for.
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
		local lines, context = definition(parsed, details)
		finish(lines)

		-- The server's own DDL is a second round trip, and the definition reads
		-- perfectly without it, so it is appended when it lands rather than
		-- holding the buffer up for it.
		M.native_ddl(parsed.connection, context, parsed.table, function(ddl)
			-- A copy, because the details may be the per-question cache's own
			-- table and this field has no business being written back to it.
			local whole = vim.tbl_extend("force", {}, details, { native_ddl = ddl })
			M.fill(bufnr, (definition(parsed, whole)))
		end)
	end, parsed.catalog)
end

--- Matched by full name rather than with bufnr(), which takes its argument as
--- a pattern and would happily return a different table's buffer.
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
		-- :buffer rather than nvim_win_set_buf, because only the command sets
		-- the alternate file, and that is what makes <C-^> the way back.
		return vim.cmd(("buffer %d"):format(existing))
	end
	if not existing then
		-- The buffer is made here rather than by the :edit, because :edit
		-- reuses the current buffer when that one is empty and unnamed -- which
		-- renames whatever you were looking at instead of leaving it behind as
		-- the alternate file, and the alternate file is the way back.
		vim.fn.bufadd(uri)
	end
	-- File magic off: a percent-encoded name has to reach :edit as it was
	-- spelled, with % and # left alone rather than expanded into the current
	-- and alternate file names.
	return vim.cmd({ cmd = "edit", args = { uri }, magic = { file = false } })
end

--- Open `uri` in the current window.
---
--- In this window and not a split of it: a document is a buffer like any other
--- and replaces what you were looking at, the way :edit would. A window that
--- already shows it is focused instead, so walking back into the same table
--- does not move anything.
--- @param lines string[]|nil lines the caller has already rendered
--- @return integer|nil bufnr, integer|nil winid
function M.open(uri, lines)
	-- :edit is the only way into a document, so opening one has to know the
	-- reader is there: db/init.lua registers it at startup, but the explorer
	-- can be loaded and used before that has happened.
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
			-- :edit will not leave a modified buffer behind when 'hidden' is
			-- off. The document still opens; only the way back is lost.
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

--- The identifier a rendered column entry opens with, in whatever this engine
--- quotes with -- and mongodb quotes with nothing at all.
local function leading_identifier(line)
	local text = vim.trim(line)
	return text:match('^"(.-)"')
		or text:match("^`(.-)`")
		or text:match("^%[(.-)%]")
		or text:match("^([%w_$]+)")
end

--- The 1-based line a column sits on in a rendered table document, or nil.
---
--- Read back out of the rendered text rather than counted from the details,
--- because the renderer is free to leave a column out or to reorder one, and a
--- jump that lands a line off is worse than one that does not land at all.
--- @return integer|nil
function M.column_line(lines, column_name)
	local want = tostring(column_name or "")
	if want == "" then
		return nil
	end
	for index, line in ipairs(lines or {}) do
		if line == ");" then
			-- Past the column list. An index and an inbound reference name
			-- columns too, and neither is where the column is defined.
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
			-- nothing will ever fill, and the user looking at a traceback
			-- instead of a table.
			local parsed = M.parse(event.file)
			pcall(dress, event.buf, parsed)
			pcall(M.render, event.file, event.buf)
		end,
	})
end

return M
