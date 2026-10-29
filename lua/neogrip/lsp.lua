-- A language server for SQL, running in this process.
--
-- There is no SQL language server worth installing here: the ones that exist
-- either want a connection of their own or answer about syntax only, and
-- neither can say what "users" means in this buffer. The thing that can is the
-- catalog :NGripIntrospect already wrote to disk, and a server whose every answer
-- is a table lookup in memory has no business being a process. vim.lsp.start
-- takes a function for `cmd` that returns an in-process client instead -- see
-- lua/servers/jdtls.lua for the same hook used the ordinary way -- which is
-- what this is.
--
-- One client per connection, named after it and shared by every buffer bound
-- to that connection: the catalog is per connection and nothing else here is
-- per buffer. Being in-process it keeps no copy of any document either; a
-- request names a uri, and the buffer behind it is always more current than a
-- synchronised copy would be.
--
-- What it does not advertise matters as much as what it does. Completion stays
-- with the cmp source in db/completion.lua, because two sources would offer
-- every table twice, and semantic tokens would paint at priority 125, over the
-- dialect layer db/dialect.lua draws at 110.
local neogrip = require("neogrip")
local identifier = require("neogrip.sql.identifier")
local schema = require("neogrip.schema")
local split = require("neogrip.sql.split")

local M = {}

local KIND = vim.lsp.protocol.SymbolKind

local CAPABILITIES = {
	definitionProvider = true,
	hoverProvider = true,
	referencesProvider = true,
	documentSymbolProvider = true,
	workspaceSymbolProvider = true,
	-- Byte columns on both sides of the protocol, which is what every other
	-- module here already measures a line in. The alternative is converting
	-- every position twice for no reader's benefit.
	positionEncoding = "utf-8",
}

-- A column's line is a line of its table's rendered definition, so answering
-- for one means rendering that document, and rendering a table the sweep never
-- reached asks the server. A reply cannot wait on a round trip: whatever has
-- not arrived by here lands on the definition's first line instead.
local RENDER_DEADLINE_MS = 250

-- Every table, view and column of a warehouse is not a list anyone reads, and
-- the client holds whatever comes back in memory.
local SYMBOL_LIMIT = 200

-- A statement's name in the outline is its first line, and an outline is only
-- readable while its entries fit on one.
local NAME_LIMIT = 72

-- Enough foreign keys to see the shape of a table, in a window that is still
-- a hover and not a report.
local KEY_LIMIT = 8

local NOT_SWEPT = "Not introspected yet -- run `:NGripIntrospect`."

--- db/document.lua renders the db:// buffers these answers point at. It is
--- asked for rather than required, because every answer that needs it is
--- better left empty than raised into the LSP loop.
local function documents()
	local ok, module = pcall(require, "neogrip.document")
	return ok and module or nil
end

--- A zero-width range at the start of a line.
--- @param line integer 0-based
local function at_line(line)
	return {
		start = { line = line, character = 0 },
		["end"] = { line = line, character = 0 },
	}
end

--- The identifier a request points at.
--- @return neogrip.Identifier|nil
local function target_of(params)
	local uri = params.textDocument and params.textDocument.uri
	if not uri then
		return nil
	end
	local bufnr = vim.uri_to_bufnr(uri)
	if not vim.api.nvim_buf_is_loaded(bufnr) then
		return nil
	end
	local position = params.position or {}
	return identifier.at_cursor(bufnr, {
		line = (position.line or 0) + 1,
		col = position.character or 0,
	})
end

--- schema.table, as a reader writes it rather than as the engine quotes it.
local function qualified(schema_name, table_name)
	if schema_name and schema_name ~= "" then
		return ("%s.%s"):format(schema_name, table_name)
	end
	return tostring(table_name)
end

local function counted(count, noun)
	return ("%d %s%s"):format(count, noun, count == 1 and "" or "s")
end

--- The other end of a foreign key.
local function key_target(key, column_name)
	local name = qualified(key.schema, key.table)
	if column_name then
		return ("%s.%s"):format(name, column_name)
	end
	return name
end

--- What the sweep knows about a table: its snapshot entry, and -- when the
--- detail pass reached it -- the keys and indexes with it. A table the budget
--- skipped still has its columns, which is most of what a hover says.
--- @return table|nil entry, table|nil details
local function known(connection, target)
	local entry, details
	pcall(function()
		for _, candidate in ipairs(schema.tables_known(connection, target.catalog, target.schema) or {}) do
			if candidate.name == target.table then
				entry = candidate
				break
			end
		end
		details = schema.details_ready(connection, target.catalog, target.schema, target.table)
	end)
	if not details and entry then
		details = { rows = entry.columns or {} }
	end
	return entry, details
end

local function column_markdown(target, details)
	local heading = ("**%s.%s**"):format(qualified(target.schema, target.table), target.column)
	if not details then
		return { heading, "", NOT_SWEPT }
	end
	local column
	for _, candidate in ipairs(details.rows or {}) do
		if candidate.name == target.column then
			column = candidate
			break
		end
	end
	if not column then
		return { heading, "", ("No such column of %s."):format(qualified(target.schema, target.table)) }
	end

	local facts = { column.nullable == false and "not null" or "nullable" }
	if column.is_pk then
		facts[#facts + 1] = "primary key"
	end
	if column.auto_increment then
		facts[#facts + 1] = "auto increment"
	end
	if column.generated then
		facts[#facts + 1] = "generated"
	end
	if column.default_expr then
		facts[#facts + 1] = ("default `%s`"):format(column.default_expr)
	end
	for _, key in ipairs(details.foreign_keys or {}) do
		for order, name in ipairs(key.columns or {}) do
			if name == column.name then
				facts[#facts + 1] = ("references `%s`"):format(
					key_target(key, (key.ref_columns or {})[order])
				)
			end
		end
	end

	local lines = {
		("%s `%s`"):format(heading, column.type or "?"),
		"",
		table.concat(facts, " · "),
	}
	if column.remarks then
		lines[#lines + 1] = ""
		lines[#lines + 1] = tostring(column.remarks)
	end
	return lines
end

local function table_markdown(target, entry, details)
	local heading = ("**%s**"):format(qualified(target.schema, target.table))
	if not entry or not details then
		return { heading, "", NOT_SWEPT }
	end

	local facts = { counted(#(details.rows or {}), "column") }
	if #(details.primary_key or {}) > 0 then
		facts[#facts + 1] = ("primary key (%s)"):format(table.concat(details.primary_key, ", "))
	end
	local lines = { ("%s `%s`"):format(heading, entry.kind or "table"), "", table.concat(facts, " · ") }
	if entry.remarks then
		lines[#lines + 1] = ""
		lines[#lines + 1] = tostring(entry.remarks)
	end

	local outbound = details.foreign_keys or {}
	if #outbound > 0 then
		lines[#lines + 1] = ""
		lines[#lines + 1] = ("Foreign keys (%d):"):format(#outbound)
		for order, key in ipairs(outbound) do
			if order > KEY_LIMIT then
				break
			end
			lines[#lines + 1] = ("- (%s) -> `%s` (%s)"):format(
				table.concat(key.columns or {}, ", "),
				key_target(key),
				table.concat(key.ref_columns or {}, ", ")
			)
		end
	end

	local inbound = details.referenced_by or {}
	if #inbound > 0 then
		lines[#lines + 1] = ""
		lines[#lines + 1] = ("Referenced by (%d):"):format(#inbound)
		for order, key in ipairs(inbound) do
			if order > KEY_LIMIT then
				break
			end
			-- Read as: that table's column points at this table's column.
			lines[#lines + 1] = ("- `%s` (%s) -> (%s)"):format(
				key_target(key),
				table.concat(key.ref_columns or {}, ", "),
				table.concat(key.columns or {}, ", ")
			)
		end
	end
	return lines
end

local function schema_markdown(connection, target)
	local tables
	pcall(function()
		tables = schema.tables_known(connection, target.catalog, target.schema)
	end)
	local heading = ("**%s**"):format(tostring(target.schema))
	if not tables then
		return { heading, "", NOT_SWEPT }
	end
	return { ("%s `schema`"):format(heading), "", counted(#tables, "table") }
end

local handlers = {}

--- A table or a schema is its own document; a column is a line of its table's.
handlers["textDocument/definition"] = function(connection, params, answer)
	local document = documents()
	local target = target_of(params)
	if not document or not target then
		return answer(nil)
	end

	if target.kind == "schema" then
		local uri = document.schema_uri(connection, target.catalog, target.schema)
		return answer({ uri = uri, range = at_line(0) })
	end

	local uri = document.table_uri(connection, target.catalog, target.schema, target.table)
	if target.kind ~= "column" then
		return answer({ uri = uri, range = at_line(0) })
	end

	vim.defer_fn(function()
		answer({ uri = uri, range = at_line(0) })
	end, RENDER_DEADLINE_MS)
	document.render(uri, vim.uri_to_bufnr(uri), function(lines)
		local line = document.column_line(lines or {}, target.column)
		answer({ uri = uri, range = at_line(math.max(0, (line or 1) - 1)) })
	end)
end

handlers["textDocument/hover"] = function(connection, params, answer)
	local target = target_of(params)
	if not target then
		return answer(nil)
	end

	local lines
	if target.kind == "schema" then
		lines = schema_markdown(connection, target)
	else
		local entry, details = known(connection, target)
		if target.kind == "column" then
			lines = column_markdown(target, details)
		else
			lines = table_markdown(target, entry, details)
		end
	end

	answer({
		contents = { kind = "markdown", value = table.concat(lines, "\n") },
		range = {
			start = { line = target.range.line - 1, character = target.range.from },
			["end"] = { line = target.range.line - 1, character = target.range.to },
		},
	})
end

--- What references a table is what its foreign keys say: the tables it points
--- at and the tables that point back at it. Neither is in this buffer, so
--- every answer is a location in another db:// document.
handlers["textDocument/references"] = function(connection, params, answer)
	local document = documents()
	local target = target_of(params)
	if not document or not target or not target.table then
		return answer(nil)
	end
	local _, details = known(connection, target)
	if not details then
		return answer(nil)
	end

	local locations, seen = {}, {}
	local function add(schema_name, table_name)
		if not table_name then
			return
		end
		local uri = document.table_uri(connection, target.catalog, schema_name or target.schema, table_name)
		if not seen[uri] then
			seen[uri] = true
			locations[#locations + 1] = { uri = uri, range = at_line(0) }
		end
	end
	for _, key in ipairs(details.foreign_keys or {}) do
		add(key.schema, key.table)
	end
	for _, key in ipairs(details.referenced_by or {}) do
		add(key.schema, key.table)
	end
	answer(#locations > 0 and locations or nil)
end

--- What the outline calls a statement.
---
--- A statement commonly opens with a comment about itself, and a list of
--- twenty comments is not an outline of a script, so the name is the first
--- line that is not one.
local function statement_name(text)
	local fallback
	for line in (text .. "\n"):gmatch("([^\n]*)\n") do
		local trimmed = vim.trim(line)
		if trimmed ~= "" then
			fallback = fallback or trimmed
			local opener = trimmed:sub(1, 2)
			if opener ~= "--" and opener ~= "/*" then
				return trimmed
			end
		end
	end
	return fallback or "statement"
end

--- One symbol per statement, so gO is an outline of a long script.
handlers["textDocument/documentSymbol"] = function(_, params, answer)
	local uri = params.textDocument and params.textDocument.uri
	local bufnr = uri and vim.uri_to_bufnr(uri)
	if not bufnr or not vim.api.nvim_buf_is_loaded(bufnr) then
		return answer(nil)
	end

	local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
	local statements = split.statements(table.concat(lines, "\n"), vim.b[bufnr].neogrip_dialect)
	local symbols = {}
	for _, statement in ipairs(statements) do
		local first = statement_name(statement.text)
		if #first > NAME_LIMIT then
			first = first:sub(1, NAME_LIMIT) .. "..."
		end
		local head = statement.start_line - 1
		local tail = statement.end_line - 1
		symbols[#symbols + 1] = {
			name = first,
			detail = head == tail and ("line %d"):format(statement.start_line)
				or ("lines %d-%d"):format(statement.start_line, statement.end_line),
			kind = KIND.Object,
			range = {
				start = { line = head, character = 0 },
				["end"] = { line = tail, character = #(lines[statement.end_line] or "") },
			},
			selectionRange = {
				start = { line = head, character = 0 },
				["end"] = { line = head, character = #(lines[statement.start_line] or "") },
			},
		}
	end
	answer(#symbols > 0 and symbols or nil)
end

--- Every table, view and column the sweep found, which is the search for an
--- object whose schema you cannot remember.
handlers["workspace/symbol"] = function(connection, params, answer)
	local document = documents()
	if not document then
		return answer(nil)
	end
	local catalog = schema.catalog_of(connection)
	local query = tostring(params.query or ""):lower()
	local function matches(name)
		return query == "" or tostring(name):lower():find(query, 1, true) ~= nil
	end

	local tables = {}
	for _, record in ipairs(schema.schemas_known(connection, catalog) or {}) do
		for _, entry in ipairs(schema.tables_known(connection, catalog, record.name) or {}) do
			tables[#tables + 1] = { schema = record.name, entry = entry }
		end
	end

	local symbols = {}
	local function document_of(item)
		return document.table_uri(connection, catalog, item.schema, item.entry.name)
	end

	-- Tables before columns: a query matching both is far more likely to have
	-- meant the table, and the cap is reached by the thousand on a warehouse.
	for _, item in ipairs(tables) do
		if #symbols >= SYMBOL_LIMIT then
			break
		end
		if matches(item.entry.name) then
			symbols[#symbols + 1] = {
				name = item.entry.name,
				kind = item.entry.kind == "view" and KIND.Interface or KIND.Class,
				containerName = item.schema,
				location = { uri = document_of(item), range = at_line(0) },
			}
		end
	end
	for _, item in ipairs(tables) do
		if #symbols >= SYMBOL_LIMIT then
			break
		end
		for _, column in ipairs(item.entry.columns or {}) do
			if #symbols >= SYMBOL_LIMIT then
				break
			end
			if matches(column.name) then
				symbols[#symbols + 1] = {
					name = column.name,
					kind = KIND.Field,
					containerName = qualified(item.schema, item.entry.name),
					location = { uri = document_of(item), range = at_line(0) },
				}
			end
		end
	end
	answer(#symbols > 0 and symbols or nil)
end

--- Answer a request, or answer nothing. Shutdown has nothing to answer with,
--- and a method that was never advertised is still asked about by some
--- clients: an empty answer is what the protocol has for "nothing here", while
--- an error would be read as a broken server.
local function dispatch(connection_id, method, params, answer)
	if method == "initialize" then
		-- A copy, not the table itself: nothing is serialised between an
		-- in-process server and its client, so the client resolves the
		-- capabilities it was handed in place -- it writes a textDocumentSync
		-- default into them -- and handing it the module's own constant would
		-- leave every later client reading what the first one was given.
		return answer({ capabilities = vim.deepcopy(CAPABILITIES), serverInfo = { name = "neogrip" } })
	end
	if not handlers[method] then
		return answer(nil)
	end
	local connection = require("neogrip.connections").get(connection_id)
	if not connection then
		return answer(nil)
	end
	handlers[method](connection, params or {}, answer)
end

--- A reply has to arrive exactly once: the client counts a request as pending
--- until its callback runs, and runs the handler on whatever the first call
--- hands over.
local function once(callback)
	local answered = false
	return function(result)
		if answered then
			return
		end
		answered = true
		callback(result)
	end
end

--- The server as vim.lsp.rpc.PublicClient, over no transport at all.
--- @return fun(dispatchers: table): table
local function in_process(connection_id)
	return function(dispatchers)
		local closing = false
		local last_id = 0

		local function close()
			if closing then
				return
			end
			closing = true
			-- Nothing else retires a client whose process never reported
			-- having gone away, and this one has no process to report it.
			vim.schedule(function()
				if dispatchers and dispatchers.on_exit then
					pcall(dispatchers.on_exit, 0, 0)
				end
			end)
		end

		return {
			request = function(method, params, callback, notify_reply_callback)
				last_id = last_id + 1
				local id = last_id
				local answer = once(function(result)
					if notify_reply_callback then
						notify_reply_callback(id)
					end
					callback(nil, result, id)
				end)
				-- Scheduled without exception, including for an answer this
				-- process already has: a reply handed back inside the call that
				-- asked for it runs the client's handler underneath itself.
				vim.schedule(function()
					local ok, err = pcall(dispatch, connection_id, method, params, answer)
					if not ok then
						-- An unanswered request is a client that waits for
						-- ever, so the failure is reported and the request is
						-- closed with nothing.
						neogrip.notify(("%s failed: %s"):format(method, err), vim.log.levels.DEBUG)
						answer(nil)
					end
				end)
				return true, id
			end,
			notify = function(method)
				if method == "exit" then
					close()
				end
				return true
			end,
			is_closing = function()
				return closing
			end,
			terminate = close,
		}
	end
end

local function client_name(connection_id)
	return "neogrip:" .. tostring(connection_id)
end

--- Start the server for this buffer's database, or attach the one already
--- running for it.
--- @return integer|nil client_id
function M.start(bufnr)
	bufnr = bufnr or vim.api.nvim_get_current_buf()
	local connection = require("neogrip.resolve").for_buf(bufnr)
	if not connection then
		return nil
	end
	local name = client_name(connection.id)

	-- A buffer pointed at another database must not keep the server that
	-- answers from the old one's catalog.
	for _, client in ipairs(vim.lsp.get_clients({ bufnr = bufnr })) do
		if vim.startswith(client.name, "neogrip:") and client.name ~= name then
			pcall(vim.lsp.buf_detach_client, bufnr, client.id)
		end
	end

	local ok, client_id = pcall(vim.lsp.start, {
		name = name,
		cmd = in_process(connection.id),
		-- No root directory: what this server reads is a catalog, not a tree
		-- of files, so there is nothing for a workspace folder to mean.
	}, {
		bufnr = bufnr,
		reuse_client = function(client)
			return client.name == name and not client:is_stopped()
		end,
		silent = true,
	})
	return ok and client_id or nil
end

function M.stop(connection_id)
	for _, client in ipairs(vim.lsp.get_clients({ name = client_name(connection_id) })) do
		pcall(function()
			client:stop()
		end)
	end
end

--- The uri an answer named, which survives the trip through a quickfix item
--- as the item's filename: vim.uri_to_fname leaves a uri it cannot turn into
--- a path alone.
local function uri_of(item)
	local location = item.user_data
	local uri = location and (location.uri or location.targetUri) or item.filename
	return type(uri) == "string" and uri:match("^neogrip://") and uri or nil
end

local function open(item)
	-- The jumplist entry is what makes <C-o> the way back.
	pcall(vim.cmd, "normal! m'")

	local uri = uri_of(item)
	local document = uri and documents()
	if not document then
		-- Not one of ours after all: opened the way the quickfix list would.
		pcall(vim.cmd, ("edit %s"):format(vim.fn.fnameescape(item.filename)))
	elseif not pcall(document.open, uri) then
		return
	end
	-- A document a round trip away is still a placeholder at this point, and
	-- the line the server named is not in it yet; landing on its first line is
	-- what that costs.
	pcall(vim.api.nvim_win_set_cursor, 0, {
		math.max(1, item.lnum or 1),
		math.max(0, (item.col or 1) - 1),
	})
	pcall(vim.cmd, "normal! zz")
end

--- One result is opened, several go to the quickfix list.
---
--- gd and gr are mapped globally to the Telescope pickers, whose previewer
--- wants a file on disk and would show a db:// result as an empty window. So
--- the answers from this server are handled here instead.
local function on_list(list)
	local items = list.items or {}
	if #items == 0 then
		return neogrip.notify("nothing to go to")
	end
	if #items == 1 then
		return open(items[1])
	end
	-- Walked from the quickfix list, where opening an entry is a read of its
	-- name and db/document.lua answers that itself.
	vim.fn.setqflist({}, " ", { title = list.title or "neogrip", items = items })
	vim.cmd("botright copen")
end

--- Jump to the database object under the cursor, routed through the list
--- handler that knows how to open neogrip:// documents. Public because the
--- plugin maps no keys (ADR-0017): `vim.keymap.set("n", "gd", lsp.definition)`
--- is the user's line to write. K and gO need nothing - Neovim maps them on
--- attach for a server that advertises hover and document symbols.
function M.definition()
	vim.lsp.buf.definition({ on_list = on_list })
end

--- The foreign-key neighbours of the object under the cursor, as a quickfix
--- list.
function M.references()
	vim.lsp.buf.references(nil, { on_list = on_list })
end

return M
