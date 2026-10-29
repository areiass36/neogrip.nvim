-- An error the editor can point at.
--
-- JDBC hands over far more than a command line client did: a SQLState, the
-- vendor's code, and - from PostgreSQL - the exact character position, which
-- the old usql path discarded entirely. So the guesswork that used to live
-- here (hunt for a quoted identifier in the message, search the buffer for it)
-- is now only a fallback for the drivers that report nothing.
local dsn = require("neogrip.dsn")

local M = {}

--- @class neogrip.QueryError
--- @field message string
--- @field state string|nil SQLState
--- @field code integer|nil vendor code
--- @field position integer|nil 0-based offset into the statement
--- @field line integer|nil 1-based line within the statement
--- @field token string|nil identifier to look for, when there is no position

-- The name is usually quoted; PostgreSQL writes a qualified one bare.
local UNQUOTED_PATTERNS = {
	"column%s+([%w_%.]+)%s+does not exist",
	"relation%s+([%w_%.]+)%s+does not exist",
	"table%s+([%w_%.]+)%s+doesn't exist",
	"no such column:%s*([%w_%.]+)",
	"no such table:%s*([%w_%.]+)",
	"near%s+([%w_%.]+)",
}

local function offending_token(text)
	local quoted = text:match('"([^"]+)"') or text:match("'([^']+)'") or text:match("`([^`]+)`")
	if quoted then
		return quoted
	end
	for _, pattern in ipairs(UNQUOTED_PATTERNS) do
		local match = text:match(pattern)
		if match then
			return match
		end
	end
	return nil
end

--- @param err table a JSON-RPC error object: { code, message, data }
--- @return neogrip.QueryError
function M.from_rpc(err, context)
	context = context or {}
	local protocol = require("neogrip.rpc.protocol")
	local data = type(err.data) == "table" and err.data or {}
	local message = dsn.redact(err.message or "error", context.password)
	-- Drivers like to append their own position line; the structured field is
	-- already there, so the text stays short.
	local first_line = message:match("^[^\n]+") or message

	return {
		message = vim.trim(first_line),
		state = data.state ~= "null" and data.state or nil,
		code = data.vendorCode ~= 0 and data.vendorCode or nil,
		position = data.position,
		line = data.line,
		cancelled = err.code == protocol.ERRORS.cancelled or nil,
		token = offending_token(message),
		raw = message,
	}
end

function M.from_message(message, context)
	return {
		message = dsn.redact(message or "error", (context or {}).password),
	}
end

--- Where to underline, in buffer coordinates.
---
--- A position from the server is an offset into the statement that was sent,
--- so it is only used when that statement is what the buffer holds; validation
--- sends the text untouched, which is why this works there too.
---
--- @param error_ neogrip.QueryError
--- @param statement table { text, start_line, end_line }
--- @param bufnr integer
--- @return integer line, integer col_start, integer col_end all 0-based
function M.locate(error_, statement, bufnr)
	local first = (statement.start_line or 1) - 1
	local last = (statement.end_line or statement.start_line or 1) - 1

	if error_.position and statement.text then
		-- Walk the statement's own text to turn an offset into a line and a
		-- column, then shift by where the statement starts in the buffer.
		local offset = error_.position
		local line_index, column = 0, offset
		for line in (statement.text .. "\n"):gmatch("([^\n]*)\n") do
			if column <= #line then
				break
			end
			column = column - (#line + 1)
			line_index = line_index + 1
		end
		local target = math.min(first + line_index, last)
		local text = vim.api.nvim_buf_get_lines(bufnr, target, target + 1, false)[1] or ""
		local from = math.max(0, math.min(column, #text))
		-- Underline the whole word the position lands on.
		local word_end = text:find("[^%w_%.]", from + 1)
		local to = word_end and (word_end - 1) or #text
		return target, from, math.max(to, from + 1)
	end

	if error_.token then
		local lines = vim.api.nvim_buf_get_lines(bufnr, first, last + 1, false)
		for offset, text in ipairs(lines) do
			local from = text:find(error_.token, 1, true)
			if from then
				return first + offset - 1, from - 1, from - 1 + #error_.token
			end
		end
	end

	if error_.line then
		local target = math.min(first + error_.line - 1, last)
		local text = vim.api.nvim_buf_get_lines(bufnr, target, target + 1, false)[1] or ""
		return target, 0, math.max(#text, 1)
	end

	local text = vim.api.nvim_buf_get_lines(bufnr, first, first + 1, false)[1] or ""
	return first, 0, math.max(#text, 1)
end

return M
