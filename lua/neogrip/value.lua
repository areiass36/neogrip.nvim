-- How a value is written out.
--
-- Converting types is the Java side's job now - it has the column type from
-- JDBC, so a decimal arrives as exact text and a binary column as hex. What
-- is left here is turning whatever arrived into the string a cell, a CSV
-- field or the clipboard should hold.
local db = require("neogrip")

local M = {}

function M.display(value, null_text)
	if value == db.NULL or value == nil or value == vim.NIL then
		return null_text or "NULL"
	end
	if type(value) == "boolean" then
		return value and "true" or "false"
	end
	if type(value) == "number" then
		-- An integer prints as an integer: 1, not 1.0.
		if value == math.floor(value) and math.abs(value) < 2 ^ 53 then
			return ("%d"):format(value)
		end
		return ("%.14g"):format(value)
	end
	if type(value) == "string" then
		return value
	end
	local ok, encoded = pcall(vim.json.encode, value)
	return ok and encoded or tostring(value)
end

-- The shapes a type prints in, for M.kind. Matched in order, so uuid is tried
-- before the date patterns and nothing hex-looking is read as a number.
local TEXT_KINDS = {
	{ "number", "^[-+]?%d+$" },
	{ "number", "^[-+]?%d*%.%d+$" },
	{ "number", "^[-+]?%d+%.%d*$" },
	{ "number", "^[-+]?%d+%.?%d*[eE][-+]?%d+$" },
	{ "uuid", "^%x%x%x%x%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%x%x%x%x%x%x%x%x$" },
	{ "date", "^%d%d%d%d%-%d%d%-%d%d$" },
	{ "timestamp", "^%d%d%d%d%-%d%d%-%d%d[ T]%d%d:%d%d" },
	{ "time", "^%d%d:%d%d$" },
	{ "time", "^%d%d:%d%d:%d%d" },
}

-- Past this a cell is prose, whatever it starts with: a comment field that
-- opens with a date is a comment field, not a timestamp.
local TEXT_LIMIT = 64

--- What a cell holds, as a name the grid colours by: "null", "boolean",
--- "number", "date", "timestamp", "time", "uuid", "json" or "text".
---
--- The type has to be read back off the value because that is all the grid
--- gets: the Java side knows the column type from JDBC but sends a row as
--- JSON, where a decimal, a date, a uuid and a name are all strings. Guessing
--- from the text is only ever used to pick a colour -- yanking, exporting and
--- the WHERE clauses built in navigate.lua all read the stored value.
function M.kind(value)
	if value == db.NULL or value == nil or value == vim.NIL then
		return "null"
	end
	local lua_type = type(value)
	if lua_type == "boolean" then
		return "boolean"
	end
	if lua_type == "number" then
		return "number"
	end
	if lua_type ~= "string" then
		-- A table: an array or an object the driver sent whole, which display
		-- encodes back to JSON.
		return "json"
	end
	if value:find("^%s*[{%[]") and value:find("[}%]]%s*$") then
		return "json"
	end
	if #value <= TEXT_LIMIT then
		local lower = value:lower()
		if lower == "true" or lower == "false" then
			return "boolean"
		end
		for _, entry in ipairs(TEXT_KINDS) do
			if value:find(entry[2]) then
				return entry[1]
			end
		end
	end
	return "text"
end

return M
