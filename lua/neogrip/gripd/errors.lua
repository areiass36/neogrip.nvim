-- An error the editor can point at. Hunting for an identifier in the message is only a
-- fallback for drivers that report no structured position.
local dsn = require("neogrip.gripd.dsn")

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
	local protocol = require("neogrip.gripd.protocol")
	local data = type(err.data) == "table" and err.data or {}
	local message = dsn.redact(err.message or "error", context.password)
	-- Drivers append their own position line; the structured field already carries it.
	local first_line = message:match("^[^\n]+") or message

	return {
		message = vim.trim(first_line),
		state = data.state ~= "null" and data.state or nil,
		code = data.vendorCode ~= 0 and data.vendorCode or nil,
		-- The envelope's code, kept apart from the driver's: a continuation whose result is
		-- gone answers -32600, which doc/protocol.md pins as the contract.
		rpc_code = err.code,
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

--- Where to underline, in buffer coordinates; a server position is an offset into the sent
--- statement, so it only applies while the buffer still holds that statement.
--- @param error_ neogrip.QueryError
--- @param statement table { text, start_line, end_line }
--- @param line_at fun(lnum: integer): string the buffer line at a 0-based number
--- @return integer line, integer col_start, integer col_end all 0-based
function M.locate(error_, statement, line_at)
	local first = (statement.start_line or 1) - 1
	local last = (statement.end_line or statement.start_line or 1) - 1

	if error_.position and statement.text then
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
		local text = line_at(target)
		local from = math.max(0, math.min(column, #text))
		local word_end = text:find("[^%w_%.]", from + 1)
		local to = word_end and (word_end - 1) or #text
		return target, from, math.max(to, from + 1)
	end

	if error_.token then
		for lnum = first, last do
			local from = line_at(lnum):find(error_.token, 1, true)
			if from then
				return lnum, from - 1, from - 1 + #error_.token
			end
		end
	end

	if error_.line then
		local target = math.min(first + error_.line - 1, last)
		local text = line_at(target)
		return target, 0, math.max(#text, 1)
	end

	local text = line_at(first)
	return first, 0, math.max(#text, 1)
end

return M
