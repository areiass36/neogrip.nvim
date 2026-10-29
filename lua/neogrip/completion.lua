-- Table and column completion from the schema cache, as an nvim-cmp source.
--
-- cmp is optional: setup() registers the source when cmp is around and does
-- nothing otherwise, and it never touches the user's source lists -
-- cmp.setup.filetype replaces them, which is not a plugin's call to make. The
-- README documents adding { name = "neogrip" } where wanted; is_available
-- keeps the source quiet outside SQL buffers either way.
local resolve = require("neogrip.resolve")
local schema = require("neogrip.schema")

local M = {}

local source = {}

function source.new()
	return setmetatable({}, { __index = source })
end

function source.is_available(_self)
	local filetype = vim.bo.filetype
	return filetype == "sql" or filetype == "mysql" or filetype == "plsql" or filetype == "mongodb"
end

function source.get_debug_name(_self)
	return "neogrip"
end

--- An alias before the dot tells us which table's columns to offer.
--- "select u.| from users u" -> users
local function table_for_alias(bufnr, alias)
	local text = table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), "\n")
	local pattern = ('[Ff][Rr][Oo][Mm]%%s+([%%w_%%."`%%[%%]]+)%%s+%%f[%%w]%s%%f[^%%w]'):format(alias)
	local found = text:match(pattern)
	if not found then
		pattern = ('[Jj][Oo][Ii][Nn]%%s+([%%w_%%."`%%[%%]]+)%%s+%%f[%%w]%s%%f[^%%w]'):format(alias)
		found = text:match(pattern)
	end
	if not found then
		return nil
	end
	-- Strip quoting and any schema qualifier.
	return (found:gsub('["`%[%]]', ""):gsub(".*%.", ""))
end

function source.complete(_self, request, callback)
	local bufnr = vim.api.nvim_get_current_buf()
	local connection = resolve.for_buf(bufnr)
	if not connection then
		return callback({ items = {}, isIncomplete = false })
	end

	local line = request.context.cursor_before_line or ""
	local alias = line:match("([%w_]+)%.$") or line:match("([%w_]+)%.[%w_]*$")

	local function finish(items)
		callback({ items = items, isIncomplete = false })
	end

	-- The catalog the sweep was keyed by, and the schema that actually holds
	-- the table. Asking with neither -- which is what this did -- means every
	-- keystroke misses the swept catalog entirely and waits on the server for
	-- an answer that was already on disk.
	local catalog = schema.catalog_of(connection)
	local function schema_of(table_name)
		return schema.locate_table(connection, catalog, table_name) or connection.schema
	end

	if alias then
		local table_name = table_for_alias(bufnr, alias) or alias
		return schema.columns(connection, schema_of(table_name), table_name, function(columns, err)
			if err or not columns then
				return finish({})
			end
			local items = {}
			for _, column in ipairs(columns) do
				items[#items + 1] = {
					label = tostring(column.name),
					kind = vim.lsp.protocol.CompletionItemKind.Field,
					detail = tostring(column.type or ""),
				}
			end
			finish(items)
		end, catalog)
	end

	-- Every schema the sweep found, not just the configured one: an
	-- unqualified name in a statement is resolved against all of them.
	local listed = {}
	local swept = schema.schemas_known(connection, catalog)
	if swept then
		for _, record in ipairs(swept) do
			local tables = schema.tables_known(connection, catalog, record.name)
			for _, table_record in ipairs(tables or {}) do
				listed[#listed + 1] = {
					label = tostring(table_record.name),
					kind = vim.lsp.protocol.CompletionItemKind.Class,
					detail = ("%s  %s"):format(tostring(table_record.kind or "table"), record.name),
				}
			end
		end
		return finish(listed)
	end

	schema.tables(connection, connection.schema, nil, function(tables, err)
		if err or not tables then
			return finish({})
		end
		local items = {}
		for _, record in ipairs(tables) do
			items[#items + 1] = {
				label = tostring(record.name),
				kind = vim.lsp.protocol.CompletionItemKind.Class,
				detail = tostring(record.kind or "table"),
			}
		end
		finish(items)
	end, catalog)
end

--- Exposed so the tests can ask it for completions without standing up cmp,
--- the same way db/explorer exposes its levels.
M.source = source

function M.setup()
	local ok, cmp = pcall(require, "cmp")
	if not ok then
		return
	end
	cmp.register_source("neogrip", source.new())
end

return M
