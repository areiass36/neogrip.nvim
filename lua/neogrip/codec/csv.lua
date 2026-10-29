-- CSV, RFC 4180: used to export a result and to read one back.
--
-- The parser takes bytes, not lines, because a quoted field can contain a
-- newline -- splitting the text on "\n" first would cut rows in half. It can be
-- fed in chunks, which also means it has to survive a chunk boundary landing
-- inside a quoted field, or between the \r and the \n of a line ending.
--
-- It scans with string.find rather than character by character: a per-character
-- loop over a few megabytes takes seconds in Lua.
local db = require("neogrip")

local M = {}

--- @class neogrip.CsvParser
--- @field delimiter string
--- @field quote string
--- @field null_marker string|nil text that means SQL NULL rather than a string
local Parser = {}
Parser.__index = Parser

function M.new(opts)
	opts = opts or {}
	return setmetatable({
		delimiter = opts.delimiter or ",",
		quote = opts.quote or '"',
		null_marker = opts.null_marker,
		buffer = "",
		row = {},
		started = false,
		pending_cr = false,
		rows = {},
	}, Parser)
end

function Parser:_push_field(value, quoted)
	if not quoted and self.null_marker and value == self.null_marker then
		value = db.NULL
	end
	self.row[#self.row + 1] = value
	self.started = true
end

function Parser:_end_row()
	if self.started or #self.row > 0 then
		self.rows[#self.rows + 1] = self.row
		self.row = {}
		self.started = false
	end
end

--- Consume as much of the buffer as forms complete records.
--- @return boolean whether progress was made
function Parser:_consume()
	local buffer = self.buffer
	local length = #buffer
	local index = 1
	local quote, delimiter = self.quote, self.delimiter
	local stop_pattern = "[" .. delimiter:gsub("(%W)", "%%%1") .. "\r\n]"

	while index <= length do
		if self.pending_cr then
			-- The previous chunk ended with \r: a \n here belongs to it.
			if buffer:sub(index, index) == "\n" then
				index = index + 1
			end
			self.pending_cr = false
		end
		if index > length then
			break
		end

		local char = buffer:sub(index, index)
		local value, quoted

		if char == quote then
			local parts = {}
			local scan = index + 1
			while true do
				local closing = buffer:find(quote, scan, true)
				if not closing then
					-- The field is not finished in this chunk.
					self.buffer = buffer:sub(index)
					return index > 1
				end
				if buffer:sub(closing + 1, closing + 1) == quote then
					parts[#parts + 1] = buffer:sub(scan, closing)
					scan = closing + 2
				elseif closing == length and not self.final then
					-- Could be the start of an escaped quote split across chunks.
					self.buffer = buffer:sub(index)
					return index > 1
				else
					parts[#parts + 1] = buffer:sub(scan, closing - 1)
					scan = closing + 1
					break
				end
			end
			value, quoted = table.concat(parts), true
			index = scan
		else
			local stop = buffer:find(stop_pattern, index)
			if not stop then
				if not self.final then
					self.buffer = buffer:sub(index)
					return index > 1
				end
				value, quoted = buffer:sub(index), false
				index = length + 1
			else
				value, quoted = buffer:sub(index, stop - 1), false
				index = stop
			end
		end

		self:_push_field(value, quoted)

		local separator = buffer:sub(index, index)
		if separator == delimiter then
			index = index + 1
		elseif separator == "\r" then
			self:_end_row()
			if index == length and not self.final then
				self.pending_cr = true
				self.buffer = ""
				return true
			end
			if buffer:sub(index + 1, index + 1) == "\n" then
				index = index + 2
			else
				index = index + 1
			end
		elseif separator == "\n" then
			self:_end_row()
			index = index + 1
		elseif index > length then
			if self.final then
				self:_end_row()
			end
		end
	end

	self.buffer = ""
	return true
end

--- @param chunk string
--- @return string[][] rows completed by this chunk
function Parser:feed(chunk)
	self.buffer = self.buffer .. chunk
	self.rows = {}
	self:_consume()
	local rows = self.rows
	self.rows = {}
	return rows
end

--- Flush whatever is left: a last line with no trailing newline.
--- @return string[][]
function Parser:finish()
	self.final = true
	self.rows = {}
	if #self.buffer > 0 then
		self:_consume()
	end
	self:_end_row()
	local rows = self.rows
	self.rows = {}
	return rows
end

--- @return string[][]
function M.decode(text, opts)
	local parser = M.new(opts)
	local rows = parser:feed(text)
	vim.list_extend(rows, parser:finish())
	return rows
end

--- Quote a value only when it needs it, and double any quote inside it.
function M.encode_value(value, opts)
	opts = opts or {}
	local delimiter = opts.delimiter or ","
	if value == db.NULL or value == nil then
		return opts.null_marker or ""
	end
	if type(value) == "boolean" then
		value = tostring(value)
	elseif type(value) == "number" then
		value = tostring(value)
	elseif type(value) ~= "string" then
		value = vim.json.encode(value)
	end
	if
		value:find('[",\r\n]')
		or value:find(delimiter, 1, true)
		or value:match("^%s")
		or value:match("%s$")
	then
		return '"' .. value:gsub('"', '""') .. '"'
	end
	return value
end

function M.encode_row(values, opts)
	local out = {}
	for index = 1, (opts and opts.count or #values) do
		out[index] = M.encode_value(values[index], opts)
	end
	return table.concat(out, (opts and opts.delimiter) or ",")
end

return M
