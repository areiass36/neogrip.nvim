-- Turning rows into aligned text.
--
-- Widths are measured with strdisplaywidth, never with # or strchars: a CJK
-- character occupies two cells, a combining mark none, and counting bytes would
-- bend every separator out of line.
local config = require("neogrip.config")
local value_module = require("neogrip.value")

local M = {}

local ELLIPSIS = "…"

--- @class neogrip.Layout
--- @field widths integer[]
--- @field truncated boolean[]
--- @field columns string[]

--- Make a value safe to measure and to print on one line.
function M.sanitize(value, null_text)
	local text = value_module.display(value, null_text)
	if type(text) ~= "string" then
		text = tostring(text)
	end
	-- Terminal escapes would move the cursor around inside the buffer.
	text = text:gsub("\27%[[%d;?]*[ -/]*[@-~]", "")
	text = text:gsub("\r\n", "\n"):gsub("\r", "\n"):gsub("\n", "↵")
	-- A tab's width depends on where it lands, which would make the measurement
	-- a lie; a control byte can be a binary value that was never text.
	text = text:gsub("\t", " ")
	text = text:gsub("%z", "·"):gsub("[\1-\8\11\12\14-\31]", "·")
	return text
end

--- True when a value carries bytes that are not text. Postgres bytea arrives
--- through the JSON driver with its invalid bytes already replaced by U+FFFD,
--- so the original cannot be recovered -- better to say so than to show noise.
function M.looks_binary(value)
	if type(value) ~= "string" then
		return false
	end
	return value:find("\239\191\189", 1, true) ~= nil or value:find("[\1-\8\14-\31]") ~= nil
end

local function display_width(text)
	return vim.fn.strdisplaywidth(text)
end

--- Longest prefix of `text` that fits in `width` display cells, plus an
--- ellipsis. Binary search over character counts, because a 1 MB JSON value in
--- a cell is not unusual and walking it down one character at a time is slow.
function M.truncate(text, width)
	if display_width(text) <= width then
		return text
	end
	local room = width - display_width(ELLIPSIS)
	if room <= 0 then
		return ELLIPSIS:sub(1, width)
	end
	local low, high = 0, vim.fn.strchars(text)
	while low < high do
		local middle = math.floor((low + high + 1) / 2)
		if display_width(vim.fn.strcharpart(text, 0, middle)) <= room then
			low = middle
		else
			high = middle - 1
		end
	end
	return vim.fn.strcharpart(text, 0, low) .. ELLIPSIS
end

--- @return neogrip.Layout
function M.compute(columns, rows, opts)
	opts = opts or {}
	local settings = config.get()
	local max_width = opts.max_width or settings.max_column_width
	local min_width = opts.min_width or settings.min_column_width
	local sample = opts.sample or settings.width_sample
	local null_text = opts.null_text or settings.null_text

	local widths, truncated = {}, {}
	for index, column in ipairs(columns) do
		local width = display_width(tostring(column))
		local capped = false
		for row_index = 1, math.min(#rows, sample) do
			local cell = M.sanitize(rows[row_index][index], null_text)
			local cell_width = display_width(cell)
			if cell_width > width then
				width = cell_width
			end
			if width >= max_width then
				width = max_width
				capped = true
				break
			end
		end
		widths[index] = math.max(min_width, math.min(width, max_width))
		truncated[index] = capped
	end

	return { widths = widths, truncated = truncated, columns = columns }
end

local function pad(text, width)
	local padding = width - display_width(text)
	if padding <= 0 then
		return text
	end
	return text .. string.rep(" ", padding)
end

--- Render the header, the rule and one line per row.
---
--- The byte span of a column is computed per line, not once for the table: a
--- cell holding CJK is the same number of display cells as an ASCII one but a
--- different number of bytes, so a single span would miss by a few bytes on
--- every row that is not pure ASCII.
---
--- @return string[] lines
--- @return table spans spans[line][column] = { start_byte, end_byte } 0-based, end exclusive
--- @return table kinds kinds[line][column] = what the cell holds, for colouring
function M.render(layout, columns, rows, opts)
	opts = opts or {}
	local settings = config.get()
	local null_text = opts.null_text or settings.null_text
	local widths = layout.widths
	local SEPARATOR = " │ "

	local lines, spans, kinds = {}, {}, {}

	local function compose(parts, line_index)
		local line_spans = {}
		local offset = 1 -- the leading space
		for index, part in ipairs(parts) do
			line_spans[index] = { offset, offset + #part }
			offset = offset + #part + #SEPARATOR
		end
		spans[line_index] = line_spans
		return " " .. table.concat(parts, SEPARATOR) .. " "
	end

	local header_parts, separator_parts = {}, {}
	for index, column in ipairs(columns) do
		header_parts[index] = pad(M.truncate(tostring(column), widths[index]), widths[index])
		separator_parts[index] = string.rep("─", widths[index])
	end
	lines[1] = compose(header_parts, 1)
	lines[2] = "─" .. table.concat(separator_parts, "─┼─") .. "─"

	for row_index, row in ipairs(rows) do
		local parts, row_kinds = {}, {}
		for index = 1, #columns do
			local raw = row[index]
			local text = M.sanitize(raw, null_text)
			parts[index] = pad(M.truncate(text, widths[index]), widths[index])
			-- Bytes that were never text beat any shape they happen to match.
			row_kinds[index] = M.looks_binary(raw) and "binary" or value_module.kind(raw)
		end
		kinds[row_index + 2] = row_kinds
		lines[row_index + 2] = compose(parts, row_index + 2)
	end

	return lines, spans, kinds
end

return M
