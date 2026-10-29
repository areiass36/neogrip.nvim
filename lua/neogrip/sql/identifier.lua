-- Which database object the cursor is on.
--
-- Scoped to the statement the cursor is in rather than to the buffer: a script
-- holds twenty statements, each with its own FROM, and an alias bound in one of
-- them says nothing about the same letter in another. db/completion.lua reads
-- the whole buffer for a FROM naming the alias, which is why "select u." in a
-- file that also joins unit_prices somewhere below can answer with the wrong
-- table's columns.
--
-- Nothing here asks the server. Every answer comes out of the catalog
-- :NGripIntrospect already wrote (neogrip/schema/store.lua), so resolving a name costs
-- a handful of table lookups and is safe to do from inside an LSP request.
local dialect = require("neogrip.dialect")
local resolve = require("neogrip.resolve")
local schema = require("neogrip.schema")
local split = require("neogrip.sql.split")

local M = {}

-- The quoting each engine's identifiers come in, which is db/schema.lua's
-- M.quote read backwards: what that function writes is what this has to
-- accept. A driver with no entry gets the SQL standard's own quote, and
-- MongoDB has no quoted identifiers at all.
local QUOTES = {
	mysql = { "`", "`" },
	mariadb = { "`", "`" },
	mssql = { "[", "]" },
	mongodb = {},
}

-- Words that follow a table reference without being its alias.
local NOT_AN_ALIAS = {}
for _, word in ipairs({
	"as",
	"on",
	"using",
	"where",
	"group",
	"order",
	"having",
	"limit",
	"offset",
	"fetch",
	"union",
	"except",
	"intersect",
	"join",
	"inner",
	"left",
	"right",
	"full",
	"cross",
	"outer",
	"natural",
	"lateral",
	"straight_join",
	"window",
	"qualify",
	"into",
	"values",
	"set",
	"returning",
	"for",
	"with",
	"select",
	"tablesample",
	"partition",
}) do
	NOT_AN_ALIAS[word] = true
end

--- @param bufnr integer
--- @return string|nil open, string|nil close
local function quoting(bufnr)
	local pair = QUOTES[vim.b[bufnr].neogrip_dialect or ""]
	if pair then
		return pair[1], pair[2]
	end
	return '"', '"'
end

--- A quoted identifier starting at `index`, where a doubled closing character
--- is a literal one.
--- @return integer|nil to 1-based index of the closing character
--- @return string|nil name
local function read_quoted(text, index, _open, close)
	local parts = {}
	local cursor = index + 1
	while cursor <= #text do
		local char = text:sub(cursor, cursor)
		if char == close then
			if text:sub(cursor + 1, cursor + 1) == close then
				parts[#parts + 1] = close
				cursor = cursor + 2
			else
				return cursor, table.concat(parts)
			end
		else
			parts[#parts + 1] = char
			cursor = cursor + 1
		end
	end
	-- Unterminated, so the identifier is still being typed.
	return nil
end

--- One identifier, quoted or bare.
--- @return integer|nil to, string|nil name, boolean|nil quoted
local function read_part(text, index, open, close)
	if open and text:sub(index, index) == open then
		local to, name = read_quoted(text, index, open, close)
		if to then
			return to, name, true
		end
		return nil
	end
	local from, to = text:find("^[%a_][%w_]*", index)
	if from then
		return to, text:sub(from, to), false
	end
	return nil
end

--- A dotted chain of identifiers at `index`: catalog.schema.table and the rest.
--- @return integer|nil to, string[]|nil names
local function read_chain(text, index, open, close)
	local names, last = {}, nil
	local cursor = index
	while true do
		local to, name = read_part(text, cursor, open, close)
		if not to then
			break
		end
		names[#names + 1] = name
		last, cursor = to, to + 1
		if text:sub(cursor, cursor) ~= "." then
			break
		end
		cursor = cursor + 1
	end
	if #names == 0 then
		return nil
	end
	return last, names
end

--- Every dotted chain on one line, each part with the extent it occupies, so
--- the part the cursor sits in can be found and reported back.
--- @return table[][] chains of { name, from, to, quoted }, all 1-based
local function chains_of(line, open, close)
	local chains, current, previous = {}, nil, nil
	local index = 1
	while index <= #line do
		local to, name, quoted = read_part(line, index, open, close)
		if to then
			local part = { name = name, from = index, to = to, quoted = quoted }
			if current and previous and index == previous + 2 and line:sub(index - 1, index - 1) == "." then
				current[#current + 1] = part
			else
				current = { part }
				chains[#chains + 1] = current
			end
			previous = to
			index = to + 1
		else
			-- Only a dot continues a chain; anything else ends it.
			if line:sub(index, index) ~= "." then
				current, previous = nil, nil
			end
			index = index + 1
		end
	end
	return chains
end

--- @param col integer 0-based byte column
--- @return table[]|nil chain, integer|nil which part of it
local function part_at(line, col, open, close)
	local position = col + 1
	for _, chain in ipairs(chains_of(line, open, close)) do
		for order, part in ipairs(chain) do
			if position >= part.from and position <= part.to then
				return chain, order
			end
		end
	end
	return nil
end

--- The statement a line belongs to. db/sql/split.lua answers this for a
--- window; an LSP request has a position and no window to ask.
--- @return db.Statement|nil
local function statement_at(text, driver, line)
	local statements = split.statements(text, driver)
	local previous = statements[1]
	for _, statement in ipairs(statements) do
		if line >= statement.start_line and line <= statement.end_line then
			return statement
		end
		if statement.end_line <= line then
			previous = statement
		end
	end
	return previous
end

--- A table reference and the alias bound to it, at `index`.
--- @return table|nil { names, alias, to }
local function read_reference(text, index, open, close)
	local cursor = text:find("%S", index)
	if not cursor or text:sub(cursor, cursor) == "(" then
		-- A subquery or a table function names nothing this can resolve.
		return nil
	end
	local to, names = read_chain(text, cursor, open, close)
	if not to or NOT_AN_ALIAS[names[1]:lower()] then
		return nil
	end
	local reference = { names = names, to = to }

	local after = text:find("%S", to + 1)
	if not after then
		return reference
	end
	local word_to, word = read_part(text, after, open, close)
	if not word_to then
		return reference
	end
	if word:lower() == "as" then
		-- AS is optional in every one of these engines, and whatever follows
		-- it is the alias however it is spelled.
		after = text:find("%S", word_to + 1)
		word_to, word = nil, nil
		if after then
			word_to, word = read_part(text, after, open, close)
		end
		if word_to then
			reference.alias, reference.to = word, word_to
		end
		return reference
	end
	if not NOT_AN_ALIAS[word:lower()] and text:sub(word_to + 1, word_to + 1) ~= "(" then
		reference.alias, reference.to = word, word_to
	end
	return reference
end

--- The statement with its string literals and comments blanked out, exactly
--- as long as it was so every position still points where it did.
---
--- The alias scan below looks for the words FROM and JOIN, and a statement that
--- builds SQL in a string -- or a comment quoting one -- has those words in it
--- without binding anything. Left in, "select col from t where q = 'from users
--- u'" binds u to users, and a u.something later in the statement resolves to
--- the wrong table. Identifier quotes are deliberately untouched: a table may
--- well be called "my table", and that name has to stay readable.
local function without_literals(text)
	local length = #text
	local bytes = {}
	for index = 1, length do
		bytes[index] = text:sub(index, index)
	end

	local function blank(from, to)
		for position = math.max(from, 1), math.min(to, length) do
			bytes[position] = " "
		end
	end

	local index = 1
	while index <= length do
		local char = bytes[index]
		if char == "'" then
			-- Doubling is how SQL escapes the quote, so a pair is not the end.
			local stop = index + 1
			while stop <= length do
				if bytes[stop] == "'" then
					if bytes[stop + 1] == "'" then
						stop = stop + 2
					else
						break
					end
				else
					stop = stop + 1
				end
			end
			blank(index, stop)
			index = stop + 1
		elseif char == "-" and bytes[index + 1] == "-" then
			local stop = index
			while stop <= length and bytes[stop] ~= "\n" do
				stop = stop + 1
			end
			blank(index, stop - 1)
			index = stop
		elseif char == "/" and bytes[index + 1] == "*" then
			local closes = text:find("*/", index + 2, true)
			local stop = closes and closes + 1 or length
			blank(index, stop)
			index = stop + 1
		else
			index = index + 1
		end
	end

	return table.concat(bytes)
end

--- The tables a statement names, by alias and in the order they appear.
---
--- FROM and JOIN are the two places an alias is bound, and the comma form of a
--- join ("from users u, orders o") binds one per item.
--- @return table { by_alias: table<string, table>, list: table[] }
local function references_of(text, open, close)
	local by_alias, list = {}, {}

	local function record(reference)
		local names = reference.names
		local entry = {}
		if #names >= 3 then
			entry.catalog, entry.schema, entry.table = names[#names - 2], names[#names - 1], names[#names]
		elseif #names == 2 then
			entry.schema, entry.table = names[1], names[2]
		else
			entry.table = names[1]
		end
		list[#list + 1] = entry
		if reference.alias then
			by_alias[reference.alias:lower()] = entry
		end
	end

	-- The keywords are looked for in the masked copy and the references read
	-- out of the real text: the two are the same length, so a position found in
	-- one is the same position in the other.
	for position, word in without_literals(text):gmatch("()([%a_][%w_]*)") do
		local lowered = word:lower()
		if lowered == "from" or lowered == "join" then
			local cursor = position + #word
			while cursor do
				local reference = read_reference(text, cursor, open, close)
				if not reference then
					break
				end
				record(reference)
				local following = text:find("%S", reference.to + 1)
				cursor = following and text:sub(following, following) == "," and following + 1 or nil
			end
		end
	end

	return { by_alias = by_alias, list = list }
end

--- An unquoted identifier is case insensitive in every one of these engines,
--- while the snapshot holds whatever the server itself spells. The exact match
--- is tried first, so a database that really does have both "Users" and
--- "users" still answers for each.
local function same(left, right)
	if left == right then
		return true
	end
	return type(left) == "string" and type(right) == "string" and left:lower() == right:lower()
end

--- The snapshot's own spelling of a schema name.
--- @return string|nil
local function schema_named(connection, catalog, name)
	for _, record in ipairs(schema.schemas_known(connection, catalog) or {}) do
		if same(record.name, name) then
			return record.name
		end
	end
	return nil
end

--- Where an unqualified name is looked for, most likely first: the schema the
--- connection names, then the one a Postgres search path starts with, then
--- every schema the sweep found.
local function search_order(connection, catalog)
	local order, seen = {}, {}
	local function add(name)
		if name and not seen[name] then
			seen[name] = true
			order[#order + 1] = name
		end
	end
	add(connection.schema)
	add("public")
	for _, record in ipairs(schema.schemas_known(connection, catalog) or {}) do
		add(record.name)
	end
	return order
end

--- @return string|nil schema, table|nil the snapshot's entry for the table
local function table_entry(connection, catalog, schema_name, table_name)
	local order
	if schema_name then
		local found = schema_named(connection, catalog, schema_name)
		order = found and { found } or {}
	else
		order = search_order(connection, catalog)
	end
	for _, name in ipairs(order) do
		for _, entry in ipairs(schema.tables_known(connection, catalog, name) or {}) do
			if same(entry.name, table_name) then
				return name, entry
			end
		end
	end
	return nil
end

--- @return table|nil the snapshot's entry for the column
local function column_entry(entry, name)
	for _, column in ipairs(entry.columns or {}) do
		if same(column.name, name) then
			return column
		end
	end
	return nil
end

--- What a dotted chain means, read against the statement's own FROM list and
--- the swept catalog.
--- @param names string[] the chain, outermost first
--- @param order integer which of them the cursor is on
--- @return table|nil { kind, schema, table, column }
local function lookup(connection, catalog, references, names, order)
	if #names > 3 then
		return nil
	end

	if #names == 1 then
		-- One name is an alias, a table, a schema, or a column of a table the
		-- statement already names -- in that order, because an alias shadows
		-- everything and a column is the only one of them that needs the
		-- statement's help to be found.
		local alias = references.by_alias[names[1]:lower()]
		if alias then
			local owner, entry = table_entry(connection, catalog, alias.schema, alias.table)
			if entry then
				return { kind = "table", schema = owner, table = entry.name }
			end
			return { kind = "table", schema = alias.schema, table = alias.table }
		end
		local owner, entry = table_entry(connection, catalog, nil, names[1])
		if entry then
			return { kind = "table", schema = owner, table = entry.name }
		end
		local only = schema_named(connection, catalog, names[1])
		if only then
			return { kind = "schema", schema = only }
		end
		for _, reference in ipairs(references.list) do
			local holder, table_of = table_entry(connection, catalog, reference.schema, reference.table)
			local column = table_of and column_entry(table_of, names[1])
			if column then
				return { kind = "column", schema = holder, table = table_of.name, column = column.name }
			end
		end
		return nil
	end

	if #names == 2 then
		-- "u.id" and "users.id" ask the same thing of different names.
		local reference = references.by_alias[names[1]:lower()]
		if not reference then
			local owner, entry = table_entry(connection, catalog, nil, names[1])
			reference = entry and { schema = owner, table = entry.name } or nil
		end
		if reference then
			if order == 1 then
				return { kind = "table", schema = reference.schema, table = reference.table }
			end
			local owner, entry = table_entry(connection, catalog, reference.schema, reference.table)
			local column = entry and column_entry(entry, names[2])
			return {
				kind = "column",
				schema = owner or reference.schema,
				table = entry and entry.name or reference.table,
				column = column and column.name or names[2],
			}
		end
		local schema_name = schema_named(connection, catalog, names[1])
		if not schema_name then
			return nil
		end
		if order == 1 then
			return { kind = "schema", schema = schema_name }
		end
		local owner, entry = table_entry(connection, catalog, schema_name, names[2])
		if not entry then
			return nil
		end
		return { kind = "table", schema = owner, table = entry.name }
	end

	-- Three names are either schema.table.column or catalog.schema.table, and
	-- the snapshot is the only thing that can tell them apart.
	local schema_name = schema_named(connection, catalog, names[1])
	if schema_name then
		local owner, entry = table_entry(connection, catalog, schema_name, names[2])
		if entry then
			if order == 1 then
				return { kind = "schema", schema = owner }
			end
			if order == 2 then
				return { kind = "table", schema = owner, table = entry.name }
			end
			local column = column_entry(entry, names[3])
			return {
				kind = "column",
				schema = owner,
				table = entry.name,
				column = column and column.name or names[3],
			}
		end
	end
	-- Only the catalog the snapshot was taken for can be answered for: there
	-- is no second catalog on disk to read, and the cursor on the catalog
	-- itself has nothing to go to.
	if order == 1 or not same(names[1], catalog) then
		return nil
	end
	local owner = schema_named(connection, catalog, names[2])
	if not owner then
		return nil
	end
	if order == 2 then
		return { kind = "schema", schema = owner }
	end
	local found, entry = table_entry(connection, catalog, owner, names[3])
	if not entry then
		return nil
	end
	return { kind = "table", schema = found, table = entry.name }
end

--- @class neogrip.Identifier
--- @field kind "table"|"schema"|"column"
--- @field connection table the database it was resolved against
--- @field catalog string|nil
--- @field schema string|nil
--- @field table string|nil nil for a schema
--- @field column string|nil only for a column
--- @field range table { line (1-based), from, to } 0-based byte columns, end exclusive

--- The object a position names, resolved without a window so a request for a
--- buffer nobody is looking at is answered the same way.
--- @param text string the whole buffer, lines joined with newlines
--- @param line integer 1-based
--- @param col integer 0-based byte column
--- @return neogrip.Identifier|nil
function M.resolve(bufnr, text, line, col)
	local connection = resolve.for_buf(bufnr)
	if not connection then
		return nil
	end
	local source = vim.split(text, "\n", { plain = true })[line]
	if not source then
		return nil
	end

	local open, close = quoting(bufnr)
	local chain, order = part_at(source, col, open, close)
	if not chain then
		return nil
	end
	local part = chain[order]

	-- A word in a string or a comment is prose, not an identifier. The
	-- question is asked about the character before a quoted name, because its
	-- own opening quote is what a string starts with and asking about that
	-- would answer yes for every quoted identifier there is.
	local probe = part.quoted and math.max(0, part.from - 2) or part.from - 1
	local asked, hidden = pcall(dialect.in_string_or_comment, bufnr, line - 1, probe)
	if asked and hidden then
		return nil
	end

	local names = {}
	for _, entry in ipairs(chain) do
		names[#names + 1] = entry.name
	end

	local catalog = schema.catalog_of(connection)
	local statement = statement_at(text, vim.b[bufnr].neogrip_dialect, line)
	local references = references_of(statement and statement.text or source, open, close)
	local found = lookup(connection, catalog, references, names, order)
	if not found then
		return nil
	end

	found.connection = connection
	found.catalog = catalog
	-- The extent the scanner measured, which is this identifier and not the
	-- qualified name around it: on "u.id" the answer is "id".
	found.range = { line = line, from = part.from - 1, to = part.to }
	return found
end

--- The object under the cursor.
--- @param cursor table|nil { line (1-based), col (0-based byte) }, or the
---        current window's position
--- @return neogrip.Identifier|nil
function M.at_cursor(bufnr, cursor)
	bufnr = bufnr or vim.api.nvim_get_current_buf()
	if not cursor then
		local ok, position = pcall(vim.api.nvim_win_get_cursor, 0)
		if not ok then
			return nil
		end
		cursor = { line = position[1], col = position[2] }
	end
	local line = cursor.line or cursor[1]
	local col = cursor.col or cursor[2]
	if not line or not col then
		return nil
	end
	local text = table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), "\n")
	return M.resolve(bufnr, text, line, col)
end

return M
