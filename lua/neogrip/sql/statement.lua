-- A statement to start from, as text and nothing else.
--
-- This was inside the explorer, which built the text and then opened a buffer
-- with it. The text is the useful half and it is not UI (ADR-0037): the client
-- decides where it goes - a buffer, the register, a floating window, straight
-- into a prompt.
--
-- Nothing produced here is runnable on purpose. The values are named
-- placeholders, so a statement that would rewrite a table cannot be executed
-- by accident: it is a statement you finish.
local schema = require("neogrip.schema")

local M = {}

--- `:name`, which no engine executes and every reader understands.
local PLACEHOLDER = ":%s"

--- @param kind string "select" | "insert" | "update" | "delete"
--- @param columns table[]|nil the set's columns, when they are known
--- @param catalog string|nil the catalog, where a query names one (ADR-0039)
--- @return string
function M.for_set(connection, namespace, set, kind, columns, catalog)
	if kind == "select" or kind == nil then
		return schema.select_statement(connection, namespace, set, columns, catalog)
	end

	local qualified = schema.qualify(connection, namespace, set, catalog)
	local driver = connection.driver
	local keys, writable = {}, {}
	for _, column in ipairs(columns or {}) do
		local name = tostring(column.name)
		if column.is_pk == true or column.is_pk == 1 or column.is_pk == "1" then
			keys[#keys + 1] = name
		end
		-- A column the server writes itself is not one you supply.
		if not column.auto_increment and not column.generated then
			writable[#writable + 1] = name
		end
	end

	local lines = {}
	if #keys == 0 and (kind == "update" or kind == "delete") then
		lines[#lines + 1] = "-- No primary key reported for this table: the WHERE below has to be"
		lines[#lines + 1] = "-- written by hand, and without one this rewrites every row."
	end

	local function conditions()
		local parts = {}
		for _, key in ipairs(keys) do
			parts[#parts + 1] = ("%s = %s"):format(schema.quote(driver, key), PLACEHOLDER:format(key))
		end
		return #parts > 0 and table.concat(parts, " AND ") or ""
	end

	if kind == "insert" then
		local names, values = {}, {}
		for _, name in ipairs(writable) do
			names[#names + 1] = schema.quote(driver, name)
			values[#values + 1] = PLACEHOLDER:format(name)
		end
		lines[#lines + 1] = ("INSERT INTO %s (%s)"):format(qualified, table.concat(names, ", "))
		lines[#lines + 1] = ("VALUES (%s);"):format(table.concat(values, ", "))
	elseif kind == "update" then
		lines[#lines + 1] = ("UPDATE %s SET"):format(qualified)
		local assignments = {}
		for _, name in ipairs(writable) do
			assignments[#assignments + 1] = ("    %s = %s"):format(
				schema.quote(driver, name),
				PLACEHOLDER:format(name)
			)
		end
		lines[#lines + 1] = table.concat(assignments, ",\n")
		lines[#lines + 1] = ("WHERE %s;"):format(conditions())
	elseif kind == "delete" then
		lines[#lines + 1] = ("DELETE FROM %s"):format(qualified)
		lines[#lines + 1] = ("WHERE %s;"):format(conditions())
	else
		return schema.select_statement(connection, namespace, set, columns, catalog)
	end

	return table.concat(lines, "\n")
end

return M
