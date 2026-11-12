-- A hand-written lexer: the treesitter sql parser fails on T-SQL (see doc/internals.md#lsp), and
-- what breaks a naive split (dollar quoting, DELIMITER, GO, nested block comments) a lexer can
-- track; visual mode bypasses it.
local M = {}

-- Only MySQL treats a backslash in a string as an escape; elsewhere consuming what follows one
-- would swallow the closing quote and hand the file's whole tail to the driver as one statement.
local BACKSLASH_ESCAPES = {
	mysql = true,
	mariadb = true,
}

--- @class neogrip.Statement
--- @field text string
--- @field start_line integer 1-based
--- @field end_line integer 1-based
--- @field start_offset integer 0-based byte offset into the buffer text
--- @field end_offset integer

local function line_of(offsets, offset)
	-- offsets[i] is the byte offset where line i starts.
	local low, high = 1, #offsets
	while low < high do
		local middle = math.floor((low + high + 1) / 2)
		if offsets[middle] <= offset then
			low = middle
		else
			high = middle - 1
		end
	end
	return low
end

--- Split a whole buffer text into statements.
--- @param text string
--- @param dialect string|nil
--- @return neogrip.Statement[]
function M.statements(text, dialect)
	local offsets = { 1 }
	for position in text:gmatch("()\n") do
		offsets[#offsets + 1] = position + 1
	end

	local statements = {}
	local backslash_escapes = BACKSLASH_ESCAPES[dialect] or false
	local delimiter = ";"
	local index, length = 1, #text
	local statement_start = 1

	local function flush(stop, next_index)
		local raw = text:sub(statement_start, stop)
		if vim.trim(raw) ~= "" then
			-- Trim leading blank space so the reported line is the first real one.
			local leading = raw:match("^%s*")
			local body = vim.trim(raw)
			local from = statement_start + #leading
			statements[#statements + 1] = {
				text = body,
				start_offset = from,
				end_offset = from + #body - 1,
				start_line = line_of(offsets, from),
				end_line = line_of(offsets, from + #body - 1),
			}
		end
		statement_start = next_index
	end

	while index <= length do
		local char = text:sub(index, index)
		local two = text:sub(index, index + 1)

		if two == "--" then
			local stop = text:find("\n", index, true)
			index = stop and stop + 1 or length + 1
		elseif two == "/*" then
			-- Block comments nest in Postgres and SQL Server.
			local depth = 1
			index = index + 2
			while index <= length and depth > 0 do
				local pair = text:sub(index, index + 1)
				if pair == "/*" then
					depth = depth + 1
					index = index + 2
				elseif pair == "*/" then
					depth = depth - 1
					index = index + 2
				else
					index = index + 1
				end
			end
		elseif char == "'" or char == '"' or char == "`" then
			local closing = char
			index = index + 1
			while index <= length do
				local inner = text:sub(index, index)
				if inner == "\\" and backslash_escapes and closing ~= "`" then
					index = index + 2
				elseif inner == closing then
					-- A doubled quote is an escaped one, not the end.
					if text:sub(index + 1, index + 1) == closing then
						index = index + 2
					else
						index = index + 1
						break
					end
				else
					index = index + 1
				end
			end
		elseif char == "[" and dialect == "mssql" then
			local closing = text:find("]", index, true)
			index = closing and closing + 1 or length + 1
		elseif char == "$" then
			local tag = text:match("^%$[%w_]*%$", index)
			if tag then
				local closing = text:find(tag, index + #tag, true)
				index = closing and closing + #tag or length + 1
			else
				index = index + 1
			end
		elseif text:sub(index, index + #delimiter - 1) == delimiter then
			flush(index - 1, index + #delimiter)
			index = index + #delimiter
		else
			-- DELIMITER // (MySQL) changes the terminator for what follows.
			local at_line_start = index == 1 or text:sub(index - 1, index - 1) == "\n"
			if at_line_start then
				local new_delimiter = text:match("^[Dd][Ee][Ll][Ii][Mm][Ii][Tt][Ee][Rr]%s+(%S+)", index)
				if new_delimiter then
					local stop = text:find("\n", index, true) or length + 1
					flush(index - 1, stop + 1)
					delimiter = new_delimiter
					index = stop + 1
					goto continue
				end
				-- GO on a line of its own is a batch separator in SQL Server.
				local go_end = text:match("^[Gg][Oo][ \t]*\n()", index)
					or text:match("^[Gg][Oo][ \t]*()$", index)
				if go_end then
					flush(index - 1, go_end)
					index = go_end
					goto continue
				end
			end
			index = index + 1
		end
		::continue::
	end

	flush(length, length + 1)
	return statements
end

return M
