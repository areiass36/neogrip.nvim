-- Type conversion is the Java side's job (a decimal arrives as exact text, binary as hex);
-- this only turns what arrived into the string a cell, a CSV field or the clipboard holds.
local M = {}

-- SQL NULL as a unique table: nil would leave a hole in a row array and "" is a different value.
M.NULL = setmetatable({}, {
	__tostring = function()
		return "NULL"
	end,
})

function M.display(value, null_text)
	if value == M.NULL or value == nil or value == vim.NIL then
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

-- Matched in order, so uuid is tried before the date patterns and nothing hex-looking reads as a number.
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

-- Past this a cell is prose: a comment field that opens with a date is not a timestamp.
local TEXT_LIMIT = 64

--- The kind a cell holds, for the grid to colour by; guessed from the text because JSON rows
--- stringify every type, and only ever used for colour - yank, export and navigate read the stored value.
function M.kind(value)
	if value == M.NULL or value == nil or value == vim.NIL then
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
		-- An array or object the driver sent whole.
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
