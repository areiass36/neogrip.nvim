-- JSON is the transport because CSV cannot tell NULL from an empty string. Column order is read
-- from the text (vim.json.decode loses it), and long integer literals are quoted before decoding;
-- see doc/internals.md#protocol.
local db = require("neogrip")

local M = {}

M.NULL = db.NULL

--- Hand every stretch outside a string literal to `transform`; string contents pass untouched.
local function outside_strings(text, transform)
	local out, index, length = {}, 1, #text
	while index <= length do
		local quote = text:find('"', index, true)
		if not quote then
			out[#out + 1] = transform(text:sub(index))
			break
		end
		out[#out + 1] = transform(text:sub(index, quote - 1))
		local scan = quote + 1
		while scan <= length do
			local char = text:sub(scan, scan)
			if char == "\\" then
				scan = scan + 2
			elseif char == '"' then
				break
			else
				scan = scan + 1
			end
		end
		out[#out + 1] = text:sub(quote, math.min(scan, length))
		index = scan + 1
	end
	return table.concat(out)
end

-- The digit count where a double starts lying; see doc/internals.md#protocol.
local BIG_INTEGER_DIGITS = 16

--- Quote integer literals too long for a double so they survive as text.
function M.quote_big_integers(text)
	return outside_strings(text, function(segment)
		return (
			segment:gsub("(%-?)(%d+)([%.eE]?)", function(sign, digits, suffix)
				if suffix == "" and #digits >= BIG_INTEGER_DIGITS then
					return ('"%s%s"'):format(sign, digits)
				end
				return sign .. digits .. suffix
			end)
		)
	end)
end

--- Column names in written order, read from the text because vim.json.decode loses it; only
--- depth-1 keys count, so nested objects' keys are not mistaken for columns.
function M.key_order(text)
	local keys, seen = {}, {}
	local object_depth = 0
	local index, length = 1, #text

	while index <= length do
		local char = text:sub(index, index)
		if char == "{" then
			object_depth = object_depth + 1
			index = index + 1
		elseif char == "}" then
			object_depth = object_depth - 1
			index = index + 1
		elseif char == '"' then
			local scan = index + 1
			local parts = {}
			while scan <= length do
				local inner = text:sub(scan, scan)
				if inner == "\\" then
					parts[#parts + 1] = text:sub(scan, scan + 1)
					scan = scan + 2
				elseif inner == '"' then
					break
				else
					parts[#parts + 1] = inner
					scan = scan + 1
				end
			end
			local after = text:find("[^ \t\r\n]", scan + 1)
			local is_key = after ~= nil and text:sub(after, after) == ":"
			if is_key and object_depth == 1 then
				local literal = table.concat(parts)
				local ok, decoded = pcall(vim.json.decode, '"' .. literal .. '"')
				local key = ok and decoded or literal
				if not seen[key] then
					seen[key] = true
					keys[#keys + 1] = key
				end
			end
			index = scan + 1
		else
			index = index + 1
		end
	end
	return keys
end

local function decode(text)
	local prepared = M.quote_big_integers(text)
	local ok, value = pcall(vim.json.decode, prepared)
	if not ok then
		return nil, ("could not decode the client's JSON: %s"):format(value)
	end
	return value
end

--- One decoded object as a row, recording any key the first object did not have.
local function row_of(object, columns, seen)
	for key in pairs(object) do
		if not seen[key] then
			seen[key] = true
			columns[#columns + 1] = key
		end
	end
	local row = {}
	for index, column in ipairs(columns) do
		local value = object[column]
		if value == nil or value == vim.NIL then
			row[index] = db.NULL
		else
			row[index] = value
		end
	end
	return row
end

--- Split into top-level JSON values by counting braces: duckdb pretty-prints one array across
--- many lines, so splitting on newlines would cut a value in half.
--- @return string[]
function M.split_values(text)
	local values = {}
	local depth, start = 0, nil
	local index, length = 1, #(text or "")

	while index <= length do
		local char = text:sub(index, index)
		if char == '"' then
			local scan = index + 1
			while scan <= length do
				local inner = text:sub(scan, scan)
				if inner == "\\" then
					scan = scan + 2
				elseif inner == '"' then
					break
				else
					scan = scan + 1
				end
			end
			index = scan + 1
		else
			if char == "[" or char == "{" then
				if depth == 0 then
					start = index
				end
				depth = depth + 1
			elseif char == "]" or char == "}" then
				depth = depth - 1
				if depth == 0 and start then
					values[#values + 1] = text:sub(start, index)
					start = nil
				end
			end
			index = index + 1
		end
	end
	return values
end

--- One result set per JSON value printed; a statement that returns nothing prints nothing.
--- @return table[] result sets, each { columns = string[], rows = any[][] }
--- @return string|nil error
function M.result_sets(text)
	local sets = {}
	for _, chunk in ipairs(M.split_values(text)) do
		local value, err = decode(chunk)
		if err then
			return sets, err
		end
		local objects = vim.islist(value) and value or { value }
		local columns, seen = {}, {}
		for _, key in ipairs(M.key_order(chunk)) do
			if not seen[key] then
				seen[key] = true
				columns[#columns + 1] = key
			end
		end
		local rows = {}
		for _, object in ipairs(objects) do
			if type(object) == "table" then
				rows[#rows + 1] = row_of(object, columns, seen)
			else
				-- A bare scalar array: one nameless column.
				columns[1] = columns[1] or "value"
				rows[#rows + 1] = { object == vim.NIL and db.NULL or object }
			end
		end
		sets[#sets + 1] = { columns = columns, rows = rows }
	end
	return sets
end

--- Canonical Extended JSON wraps every scalar in a type tag: unwrap the ones with an obvious
--- text form, keep the JSON shape otherwise so no information is invented.
function M.flatten_ejson(value)
	if type(value) ~= "table" then
		if value == vim.NIL then
			return db.NULL
		end
		return value
	end
	if value == db.NULL then
		return value
	end

	local single = nil
	local count = 0
	for key in pairs(value) do
		count = count + 1
		single = key
	end

	if count == 1 then
		local inner = value[single]
		if single == "$oid" or single == "$numberDecimal" or single == "$symbol" or single == "$code" then
			return inner
		end
		if single == "$numberInt" or single == "$numberLong" then
			return inner
		end
		if single == "$numberDouble" then
			return inner
		end
		if single == "$date" then
			local milliseconds = type(inner) == "table" and inner["$numberLong"] or inner
			if type(milliseconds) == "string" then
				milliseconds = tonumber(milliseconds)
			end
			if type(milliseconds) == "number" then
				return os.date("!%Y-%m-%dT%H:%M:%SZ", math.floor(milliseconds / 1000))
			end
			return tostring(inner)
		end
		if single == "$binary" then
			return "<binary>"
		end
		if single == "$timestamp" then
			return ("<timestamp %s>"):format(vim.json.encode(inner))
		end
	end

	if vim.islist(value) then
		return ("[%d]"):format(#value)
	end
	return "{…}"
end

--- A Mongo result, fields flattened one level for the grid; the untouched document stays
--- available for the detail view.
--- @return table { columns = string[], rows = any[][], documents = table[] }
function M.documents(text)
	local documents = {}
	for _, chunk in ipairs(M.split_values(text)) do
		local value, err = decode(chunk)
		if err then
			return { columns = {}, rows = {}, documents = {}, error = err }
		end
		if vim.islist(value) then
			vim.list_extend(documents, value)
		else
			documents[#documents + 1] = value
		end
	end

	local columns, seen, rows = {}, {}, {}
	for _, key in ipairs(M.key_order(text or "")) do
		if not seen[key] then
			seen[key] = true
			columns[#columns + 1] = key
		end
	end
	for _, document in ipairs(documents) do
		local row = {}
		for index, column in ipairs(columns) do
			-- Written out because the and/or idiom turns a false field into nil, drawn as NULL.
			local value
			if type(document) == "table" then
				value = document[column]
			end
			if value == nil or value == vim.NIL then
				row[index] = db.NULL
			else
				row[index] = M.flatten_ejson(value)
			end
		end
		rows[#rows + 1] = row
	end
	return { columns = columns, rows = rows, documents = documents }
end

return M
