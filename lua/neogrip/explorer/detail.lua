-- What a table looks like, as a read-only SQL buffer.
--
-- JDBC has no "show me the DDL", but it has every piece one is written from,
-- so the CREATE TABLE here is rendered rather than fetched. That is the honest
-- trade: it is the server's own answer about columns, keys, indexes and
-- comments, spelled in this dialect's quoting, and it is never passed off as
-- the exact text the server would print. Where the server will print its own
-- text cheaply, that is appended underneath, verbatim, so the two can be
-- compared rather than confused.
--
-- The rule the whole file is written to: every line that is not a comment is
-- runnable SQL. So a key the server named is a named CONSTRAINT, an index is a
-- CREATE INDEX, a column remark is a COMMENT ON -- and anything reported
-- without enough detail to spell (a generated column whose expression JDBC
-- does not carry) is said in a comment rather than guessed at.
--
-- The buffer is a real 'sql' buffer and a real db:// document: naming and
-- filling it is db/document.lua's job, so the explorer's <CR> and an :edit of
-- the same URI from anywhere else land in the one buffer.
local neogrip = require("neogrip")
local document = require("neogrip.document")
local icons = require("neogrip.icons")
local schema = require("neogrip.schema")

local M = {}

-- Past this, a foreign key's REFERENCES clause moves onto a line of its own. A
-- definition is read in a window, and a window is not 160 columns wide.
local WIDTH = 100

-- How this engine spells an auto-numbered column. ANSI identity is the
-- default, because Postgres, Oracle, DB2 and H2 all take it.
local IDENTITY = {
	mysql = "AUTO_INCREMENT",
	mariadb = "AUTO_INCREMENT",
	sqlite = "AUTOINCREMENT",
	mssql = "IDENTITY",
}

local function quote(driver, name)
	return schema.quote(driver, tostring(name))
end

local function quote_list(driver, names)
	local parts = {}
	for _, name in ipairs(names or {}) do
		parts[#parts + 1] = quote(driver, name)
	end
	return table.concat(parts, ", ")
end

--- A reported string, or nil when there is nothing in it.
---
--- Flattened, because a remark or an index filter can run over several lines
--- and a buffer line cannot hold one: unflattened it would raise rather than
--- be read. "nil" is checked for because that is how an absent name reaches
--- Lua from the Java side.
local function named(value)
	if value == nil then
		return nil
	end
	local text = vim.trim((tostring(value):gsub("%s+", " ")))
	if text == "" or text == "nil" then
		return nil
	end
	return text
end

--- A referential action, when it is one worth writing down.
---
--- "no action" is every engine's default, so spelling it out adds a clause to
--- every foreign key and tells the reader nothing.
local function action(value)
	local text = named(value)
	if not text then
		return nil
	end
	local normal = text:lower()
	if normal == "no action" or normal == "none" or normal == "unknown" then
		return nil
	end
	return text:upper()
end

--- A SQL string literal, with the quote doubled as SQL doubles it.
local function literal(text)
	return "'" .. (tostring(text):gsub("'", "''")) .. "'"
end

--- An expression in brackets, but only one pair of them: a server reports a
--- generation expression both ways, and two pairs reads as a mistake.
local function grouped(expression)
	if expression:sub(1, 1) == "(" then
		local depth = 0
		for position = 1, #expression do
			local char = expression:sub(position, position)
			if char == "(" then
				depth = depth + 1
			elseif char == ")" then
				depth = depth - 1
				if depth == 0 then
					-- The opening bracket closes before the end, so the whole
					-- of it is not one group: "(a) + (b)" needs its own.
					return position == #expression and expression or ("(%s)"):format(expression)
				end
			end
		end
	end
	return ("(%s)"):format(expression)
end

--- The columns in the order the table declares them.
---
--- JDBC answers in ordinal order already; sorting on the position it reports is
--- what keeps that true when an answer arrives from somewhere else, such as a
--- snapshot merged out of a parallel sweep. Only when every position is a
--- distinct number above zero, because a driver that will not say reports zero
--- for all of them and table.sort is not stable: sorting on that would shuffle
--- a perfectly good order into an arbitrary one. Sorted on a copy, because
--- M.render is pure and the details table belongs to its caller.
local function ordered(columns)
	local seen = {}
	for _, column in ipairs(columns) do
		local position = column.position
		if type(position) ~= "number" or position < 1 or seen[position] then
			return columns
		end
		seen[position] = true
	end
	local copy = vim.list_slice(columns, 1, #columns)
	table.sort(copy, function(left, right)
		return left.position < right.position
	end)
	return copy
end

--- One column of the CREATE TABLE, as { text, note }.
---
--- The note is for what the server reported but did not report enough of to
--- spell: a generated column whose expression JDBC does not carry cannot be
--- written as SQL, and inventing one would break the rule the file is written
--- to.
local function column_entry(driver, column, widths)
	local parts = {
		("%-" .. widths.name .. "s %-" .. widths.type .. "s"):format(
			quote(driver, column.name),
			column.type or ""
		),
	}
	local note = nil

	if column.nullable == false or column.nullable == 0 then
		parts[#parts + 1] = "NOT NULL"
	end

	local default = named(column.default_expr)
	if column.auto_increment == true or column.auto_increment == 1 then
		-- The sequence behind a serial column is the default, and the identity
		-- clause is the same statement said portably, so only one goes in.
		parts[#parts + 1] = IDENTITY[driver] or "GENERATED BY DEFAULT AS IDENTITY"
	elseif column.generated == true or column.generated == 1 then
		if default then
			parts[#parts + 1] = "GENERATED ALWAYS AS " .. grouped(default)
		else
			note = "generated"
		end
	elseif default then
		parts[#parts + 1] = "DEFAULT " .. default
	end

	return { text = vim.trim(table.concat(parts, " ")), note = note }
end

--- The declared keys, as named constraints where a name was reported.
---
--- Unnamed where it was not, which is what this file emitted before names were
--- available at all: a bare PRIMARY KEY (...) is still correct, it just cannot
--- be dropped by name.
local function constraints(connection, context, details)
	local driver = connection.driver
	local primary = details.primary_key or {}
	local keys = details.foreign_keys or {}
	local entries = {}

	local primary_name = named(details.primary_key_name)
	if primary_name == "PRIMARY" and (driver == "mysql" or driver == "mariadb") then
		-- Not a name the user gave it and not one MySQL will accept back: every
		-- primary key there is reported as PRIMARY, which is the engine saying
		-- the key has no name of its own.
		primary_name = nil
	end

	-- The constraint names line up with each other rather than with the columns
	-- above: they are a block of their own and are read down it.
	local width = 1
	local names = {}
	if #primary > 0 then
		names[#names + 1] = primary_name
	end
	for _, key in ipairs(keys) do
		names[#names + 1] = named(key.name)
	end
	for _, name in ipairs(names) do
		width = math.max(width, #quote(driver, name))
	end

	local function head(name, keyword)
		if not name then
			return keyword
		end
		return ("CONSTRAINT %-" .. width .. "s %s"):format(quote(driver, name), keyword)
	end

	if #primary > 0 then
		entries[#entries + 1] = {
			text = ("%s (%s)"):format(head(primary_name, "PRIMARY KEY"), quote_list(driver, primary)),
		}
	end

	for _, key in ipairs(keys) do
		local target = ("REFERENCES %s (%s)"):format(
			schema.qualify(connection, key.schema or context.schema, key.table),
			quote_list(driver, key.ref_columns)
		)
		local on_delete, on_update = action(key.on_delete), action(key.on_update)
		if on_delete then
			target = ("%s ON DELETE %s"):format(target, on_delete)
		end
		if on_update then
			target = ("%s ON UPDATE %s"):format(target, on_update)
		end

		local declaration = ("%s (%s)"):format(
			head(named(key.name), "FOREIGN KEY"),
			quote_list(driver, key.columns)
		)
		-- The comma is allowed for, so whether a key wraps does not depend on
		-- it happening to be the last entry.
		if #declaration + #target + 6 <= WIDTH then
			entries[#entries + 1] = { text = ("%s %s"):format(declaration, target) }
		else
			entries[#entries + 1] = { text = declaration, continuation = target }
		end
	end

	return entries
end

--- The CREATE TABLE, from the columns and the keys they declare.
local function create_table(connection, context, table_name, details)
	local driver = connection.driver
	local columns = ordered(details.rows or {})
	local lines = { ("CREATE TABLE %s ("):format(schema.qualify(connection, context.schema, table_name)) }

	-- Line the names and the types up, so a wide table can be read down the
	-- column rather than across every row of it.
	local widths = { name = 1, type = 1 }
	for _, column in ipairs(columns) do
		widths.name = math.max(widths.name, #quote(driver, column.name))
		widths.type = math.max(widths.type, #tostring(column.type or ""))
	end

	local entries = {}
	for _, column in ipairs(columns) do
		entries[#entries + 1] = column_entry(driver, column, widths)
	end
	vim.list_extend(entries, constraints(connection, context, details))

	for index, entry in ipairs(entries) do
		local tail = (index < #entries and "," or "") .. (entry.note and ("  -- " .. entry.note) or "")
		if entry.continuation then
			lines[#lines + 1] = "    " .. entry.text
			lines[#lines + 1] = "        " .. entry.continuation .. tail
		else
			lines[#lines + 1] = "    " .. entry.text .. tail
		end
	end
	lines[#lines + 1] = ");"
	return lines
end

--- The indexes, as the statements that would create them.
---
--- Statements rather than the comments this used to write: an index is part of
--- how a table is defined, and the one worth copying into a migration is the
--- one the server already has.
local function indexes(connection, context, table_name, details)
	local driver = connection.driver
	local qualified = schema.qualify(connection, context.schema, table_name)
	local primary = table.concat(details.primary_key or {}, "\1")
	local lines = {}

	for _, index in ipairs(details.indexes or {}) do
		local columns = {}
		for position, column in ipairs(index.columns or {}) do
			local direction = tostring((index.order or {})[position] or ""):lower()
			columns[#columns + 1] = quote(driver, column) .. (direction == "desc" and " DESC" or "")
		end
		local spelled = table.concat(columns, ", ")

		-- An index that implements the primary key is already stated by the
		-- constraint above, and written twice it reads as two different things.
		local implements_key = primary ~= "" and table.concat(index.columns or {}, "\1") == primary
		local name = named(index.name)

		local worth_writing = not implements_key and #columns > 0
		if worth_writing and not name then
			-- With no name there is no statement to write, so what is known
			-- goes down as a note instead.
			lines[#lines + 1] = ("--   an unnamed %sindex on (%s)"):format(
				index.unique and "unique " or "",
				spelled
			)
		elseif worth_writing then
			local statement = ("CREATE %sINDEX %s ON %s (%s)"):format(
				index.unique and "UNIQUE " or "",
				quote(driver, name),
				qualified,
				spelled
			)
			local filter = named(index.filter)
			if filter then
				statement = ("%s WHERE %s"):format(statement, filter)
			end
			statement = statement .. ";"
			-- The kind is not syntax any two engines share -- USING btree is
			-- Postgres, CLUSTERED is T-SQL and goes in a different place -- so
			-- it is said rather than spelled.
			local kind = named(index.kind)
			if kind and kind ~= "other" then
				statement = ("%s  -- %s"):format(statement, kind)
			end
			lines[#lines + 1] = statement
		end
	end

	return lines
end

--- The remarks, as COMMENT ON.
---
--- Standard SQL, which Postgres, Oracle and DB2 all take. MySQL and SQLite
--- spell a comment inside the column definition instead; rather than guess at
--- which of those this driver is, the portable form is written and the reader
--- can see what the server said.
local function comments(connection, context, table_name, details)
	local driver = connection.driver
	local qualified = schema.qualify(connection, context.schema, table_name)
	local lines = {}

	local remarks = named(details.remarks)
	if remarks then
		lines[#lines + 1] = ("COMMENT ON TABLE %s IS %s;"):format(qualified, literal(remarks))
	end
	for _, column in ipairs(details.rows or {}) do
		local note = named(column.remarks)
		if note then
			lines[#lines + 1] = ("COMMENT ON COLUMN %s.%s IS %s;"):format(
				qualified,
				quote(driver, column.name),
				literal(note)
			)
		end
	end

	return lines
end

--- What points at this table, as comments: it describes the table rather than
--- recreating it, and a buffer you might yank out of should not hand you
--- statements that belong to someone else's table.
local function annotations(connection, context, details)
	local driver = connection.driver
	local lines = {}

	local inbound = details.referenced_by or {}
	if #inbound > 0 then
		lines[#lines + 1] = ("-- Referenced by (%d)"):format(#inbound)
		for _, key in ipairs(inbound) do
			-- Read as: that table's column points at this table's column. The
			-- trailing space goes when there is no name to put after it, so an
			-- unnamed key does not leave whitespace at the end of the line.
			lines[#lines + 1] = (
				("--   %s (%s) -> (%s)   %s")
					:format(
						schema.qualify(connection, key.schema or context.schema, key.table),
						quote_list(driver, key.ref_columns),
						quote_list(driver, key.columns),
						named(key.name) or ""
					)
					:gsub("%s+$", "")
			)
		end
	end

	if #(details.indexes or {}) == 0 and #inbound == 0 and #(details.foreign_keys or {}) == 0 then
		-- No blank line of its own: this branch is only reached when the block
		-- above wrote nothing, so one here would double the gap M.render
		-- already puts between sections.
		lines[#lines + 1] = "-- No indexes, foreign keys or inbound references reported."
		lines[#lines + 1] = "-- A query engine such as Trino has none to report."
	end

	return lines
end

--- The server's own DDL, where it gave one.
---
--- Verbatim, because the whole point of it is that it is the server's answer
--- and not this file's rendering of one: the two disagreeing is the thing worth
--- seeing, and a check constraint is only ever in this half.
local function native(details)
	local text = details.native_ddl
	if type(text) ~= "string" or vim.trim(text) == "" then
		return {}
	end
	local lines = { "-- As the server writes it" }
	for _, line in ipairs(vim.split(text, "\n", { plain = true })) do
		lines[#lines + 1] = (line:gsub("\r$", ""))
	end
	return lines
end

--- @return string[] lines
function M.render(connection, context, table_name, details)
	local columns = details.rows or {}
	if #columns == 0 then
		return { ("-- %s: no columns reported"):format(tostring(table_name)) }
	end
	-- One blank line between sections, decided here and nowhere else: this is a
	-- buffer somebody reads, four kinds of statement run together are hard to
	-- take in, and a section that spaced itself as well would double the gap.
	-- Trailing blanks are trimmed off each section for the same reason, so the
	-- document never ends in whitespace either.
	local lines = {}
	for _, section in ipairs({
		create_table(connection, context, table_name, details),
		indexes(connection, context, table_name, details),
		comments(connection, context, table_name, details),
		annotations(connection, context, details),
		native(details),
	}) do
		while #section > 0 and section[#section] == "" do
			table.remove(section)
		end
		if #section > 0 then
			if #lines > 0 then
				lines[#lines + 1] = ""
			end
			vim.list_extend(lines, section)
		end
	end
	return lines
end

--- Open the rendered definition as a read-only buffer in the current window.
---
--- A thin wrapper over db/document.lua, which owns the naming, the reader and
--- everything a definition buffer is: <CR> here and an :edit of the same db://
--- URI from anywhere else have to be the one buffer, not two that look alike.
function M.open(connection, context, table_name, lines)
	return document.open(document.table_uri(connection, context.catalog, context.schema, table_name), lines)
end

--- Fetch and show. The one round trip this costs is for a table someone opened.
--- @param on_done fun(lines: string[], bufnr: integer)|nil
function M.show(context, table_name, on_done)
	local connection = context.connection

	local function draw(details, failure)
		local lines = M.render(connection, context, table_name, details or {})
		if failure then
			table.insert(lines, 1, ("-- %s"):format(failure))
			table.insert(lines, 2, "")
		end
		local bufnr = M.open(connection, context, table_name, lines)
		neogrip.notify(("%s %s"):format(icons.table, table_name))
		if on_done then
			on_done(lines, bufnr)
		end
		return bufnr
	end

	schema.details(connection, context.schema, table_name, function(details, err)
		if err then
			-- Opening anyway, with the columns and a line saying what was not
			-- available. The five metadata calls a definition is written from
			-- fail independently -- a query engine answers for columns and
			-- refuses keys and indexes outright -- so one refusal is no reason
			-- to show nothing at all. It is also the difference between a
			-- notification that scrolls past and a buffer that says why.
			return schema.columns(connection, context.schema, table_name, function(columns, column_err)
				draw({ rows = columns or {} }, column_err and ("%s / %s"):format(err, column_err) or err)
			end, context.catalog)
		end
		details = details or {}
		local bufnr = draw(details, nil)

		-- The server's own DDL is a second round trip and the definition reads
		-- perfectly without it, so it is appended when it lands rather than
		-- holding the buffer up for it.
		document.native_ddl(connection, context, table_name, function(ddl)
			-- A copy, because the details may be the per-question cache's own
			-- table and this field has no business being written back to it.
			local whole = vim.tbl_extend("force", {}, details, { native_ddl = ddl })
			document.fill(bufnr, M.render(connection, context, table_name, whole))
		end)
	end, context.catalog)
end

return M
