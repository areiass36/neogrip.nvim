-- Which statement the user means: the one the cursor sits in, or the visual selection verbatim.
local split = require("neogrip.sql.split")

local M = {}

--- @return neogrip.Statement|nil
function M.at_cursor(bufnr, winid)
	bufnr = bufnr or vim.api.nvim_get_current_buf()
	winid = winid or vim.api.nvim_get_current_win()
	local text = table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), "\n")
	local dialect = vim.b[bufnr].neogrip_dialect
	local statements = split.statements(text, dialect)
	if #statements == 0 then
		return nil
	end

	local cursor = vim.api.nvim_win_get_cursor(winid)
	local line = cursor[1]

	for _, statement in ipairs(statements) do
		if line >= statement.start_line and line <= statement.end_line then
			return statement
		end
	end
	-- In blank space or a comment, take the statement above: it is what was just edited.
	local previous = statements[1]
	for _, statement in ipairs(statements) do
		if statement.end_line <= line then
			previous = statement
		end
	end
	return previous
end

--- The visual selection, verbatim.
--- @return neogrip.Statement|nil
function M.selection(bufnr)
	bufnr = bufnr or vim.api.nvim_get_current_buf()
	local from = vim.api.nvim_buf_get_mark(bufnr, "<")
	local to = vim.api.nvim_buf_get_mark(bufnr, ">")
	if from[1] == 0 or to[1] == 0 then
		return nil
	end
	local lines = vim.api.nvim_buf_get_lines(bufnr, from[1] - 1, to[1], false)
	if #lines == 0 then
		return nil
	end
	-- Column marks are byte indices; the end one can be huge for a linewise V.
	lines[#lines] = lines[#lines]:sub(1, math.min(to[2] + 1, #lines[#lines]))
	lines[1] = lines[1]:sub(from[2] + 1)
	local text = vim.trim(table.concat(lines, "\n"))
	-- The trailing terminator must go; see doc/internals.md#runner-and-execute.
	text = vim.trim((text:gsub(";%s*$", "")))
	if text == "" then
		return nil
	end
	return {
		text = text,
		start_line = from[1],
		end_line = to[1],
		start_offset = 0,
		end_offset = #text,
	}
end

return M
