-- Colour in the result grid.
--
-- A cell is painted for what it holds -- a number, a date, a boolean, NULL --
-- in the colour the colourscheme already gives that kind of literal in a
-- buffer, so a result reads like the rest of the editor instead of like a
-- second theme. Text is the exception and is left on the plain foreground: it
-- is most of a result and it is what you are actually reading, so it keeps the
-- best contrast there is.
--
-- The table's furniture is pushed the other way. The rule and the │ between
-- columns drop to the colour of a window separator: they are there to be
-- looked past, and drawn in a plain or a bright colour they end up louder than
-- the values they are separating.
--
-- Every group is defined with `default = true`, so
-- `vim.api.nvim_set_hl(0, "NGripGridNumber", { fg = "#ff0000" })` from init.lua
-- wins, and rebuilt on ColorScheme because :colorscheme clears every group --
-- a link included -- and the colours here are resolved, not linked.
local config = require("neogrip.config")

local M = {}

local ELLIPSIS = "…"

-- Where the parts of the table are. The header is line 1, the rule line 2, and
-- the rows follow; layout.render builds them in that order.
local HEADER_LINE = 1
local RULE_LINE = 2

-- Below treesitter's 100, so a stripe tints the row without touching any
-- foreground; the cell under the cursor is painted over everything at 150.
local STRIPE_PRIORITY = 90
local CONTENT_PRIORITY = 100
local ELLIPSIS_PRIORITY = 105

--- @type table<string, { fg: string[]|nil, bg: string[]|nil, link: string|nil }>
--- fg/bg list the groups a colour is taken from, best first: the first one that
--- has that attribute, and has it different from Normal, wins. So a
--- colourscheme that never heard of @boolean still lands on Boolean, and one
--- where @string.special is just the plain foreground falls through to Special
--- rather than painting a date in the colour it already was.
local SPEC = {
	NGripGridHeader = { fg = { "@attribute", "Function", "Identifier" }, bold = true },
	-- The column the result is ordered by, which is otherwise invisible once
	-- the rows come back sorted. Same colour as the other names, underlined:
	-- one hue in the header row is enough.
	NGripGridHeaderSorted = { fg = { "@attribute", "Function", "Identifier" }, bold = true, underline = true },
	NGripGridRule = { fg = { "WinSeparator", "VertSplit", "NonText" } },
	NGripGridSeparator = { fg = { "WinSeparator", "VertSplit", "NonText" } },
	-- Every other row, in whatever tint the colourscheme uses for the cursor
	-- line: the one thing that keeps a wide row readable all the way across.
	NGripGridStripe = { bg = { "CursorLine", "ColorColumn" } },
	NGripGridEllipsis = { fg = { "NonText", "Comment" } },
	NGripGridCell = { link = "Visual" },

	NGripGridNull = { fg = { "Comment" }, italic = true },
	NGripGridNumber = { fg = { "@number", "Number" } },
	NGripGridBoolean = { fg = { "@boolean", "Boolean", "Keyword" } },
	NGripGridTemporal = { fg = { "Special", "@string.special", "Constant" } },
	NGripGridUuid = { fg = { "@constant", "@constant.macro", "Constant" } },
	NGripGridJson = { fg = { "@property", "Identifier", "Type" } },
	NGripGridBinary = { fg = { "DiagnosticWarn", "WarningMsg" } },

	NGripGridFooter = { fg = { "Comment" } },
	NGripGridConnection = { fg = { "@module", "Identifier" } },
	NGripGridProduction = { fg = { "DiagnosticError", "ErrorMsg" }, bold = true },
	NGripGridCount = { fg = { "@number", "Number" } },
	NGripGridElapsed = { fg = { "Comment" } },
	NGripGridSlow = { fg = { "DiagnosticWarn", "WarningMsg" } },
}

--- What value.kind says a cell is -> the group that paints it. "text" is
--- deliberately absent: a name, an address or a description keeps Normal.
local KIND_GROUPS = {
	null = "NGripGridNull",
	number = "NGripGridNumber",
	boolean = "NGripGridBoolean",
	date = "NGripGridTemporal",
	timestamp = "NGripGridTemporal",
	time = "NGripGridTemporal",
	uuid = "NGripGridUuid",
	json = "NGripGridJson",
	binary = "NGripGridBinary",
}

local function resolve(name)
	local ok, hl = pcall(vim.api.nvim_get_hl, 0, { name = name, link = false, create = false })
	return ok and type(hl) == "table" and hl or {}
end

--- The first of `names` that carries `field`, skipping any that carries the
--- same value as Normal: a cell painted the colour it already was is not
--- painted at all, and a stripe the colour of the background is not a stripe.
local function attribute_of(field, names)
	local plain = resolve("Normal")[field]
	local fallback = nil
	for _, name in ipairs(names) do
		local value = resolve(name)[field]
		if value then
			if value ~= plain then
				return value
			end
			fallback = fallback or value
		end
	end
	return fallback
end

local watching = false

--- Define the groups. Idempotent: `default = true` means a second call is a
--- no-op until something clears them.
function M.setup()
	for name, spec in pairs(SPEC) do
		if spec.link then
			vim.api.nvim_set_hl(0, name, { link = spec.link, default = true })
		else
			vim.api.nvim_set_hl(0, name, {
				fg = spec.fg and attribute_of("fg", spec.fg) or nil,
				bg = spec.bg and attribute_of("bg", spec.bg) or nil,
				bold = spec.bold,
				italic = spec.italic,
				underline = spec.underline,
				default = true,
			})
		end
	end

	if not watching then
		watching = true
		vim.api.nvim_create_autocmd("ColorScheme", {
			group = vim.api.nvim_create_augroup("NGripGridHighlight", { clear = true }),
			desc = "Rebuild the result grid's highlight groups",
			callback = function()
				M.setup()
			end,
		})
	end
end

--- The groups this module defines, for :checkhealth and the docs.
function M.groups()
	return vim.tbl_keys(SPEC)
end

--- @param grid { lines: string[], spans: table, kinds: table, rows: integer,
--- sorted_column: integer|nil, footer: { line: integer, segments: table }|nil }
function M.paint(bufnr, namespace, grid)
	if not vim.api.nvim_buf_is_valid(bufnr) then
		return
	end
	M.setup()
	vim.api.nvim_buf_clear_namespace(bufnr, namespace, 0, -1)

	local lines = grid.lines
	local striped = config.get().stripe_rows

	local function mark(line, from, to, group, priority)
		if not group or from >= to then
			return
		end
		pcall(vim.api.nvim_buf_set_extmark, bufnr, namespace, line - 1, from, {
			end_col = to,
			hl_group = group,
			priority = priority or CONTENT_PRIORITY,
		})
	end

	-- The ` │ ` between two cells, plus the space at either edge: everything on
	-- the line that is not a cell.
	local function furniture(line, line_spans)
		local previous = 0
		for _, span in ipairs(line_spans) do
			mark(line, previous, span[1], "NGripGridSeparator")
			previous = span[2]
		end
		mark(line, previous, #(lines[line] or ""), "NGripGridSeparator")
	end

	local header_spans = grid.spans[HEADER_LINE] or {}
	for index, span in ipairs(header_spans) do
		local sorted = grid.sorted_column == index
		mark(HEADER_LINE, span[1], span[2], sorted and "NGripGridHeaderSorted" or "NGripGridHeader")
	end
	furniture(HEADER_LINE, header_spans)
	mark(RULE_LINE, 0, #(lines[RULE_LINE] or ""), "NGripGridRule")

	for row = 1, grid.rows do
		local line = row + RULE_LINE
		local line_spans = grid.spans[line] or {}
		local kinds = grid.kinds[line] or {}
		if striped and row % 2 == 0 then
			mark(line, 0, #(lines[line] or ""), "NGripGridStripe", STRIPE_PRIORITY)
		end
		furniture(line, line_spans)
		for index, span in ipairs(line_spans) do
			mark(line, span[1], span[2], KIND_GROUPS[kinds[index]])
			-- An ellipsis is the grid saying the value goes on, not part of the
			-- value: dim it so a truncated cell is obvious without reading it.
			local cell = lines[line]:sub(span[1] + 1, span[2]):gsub("%s+$", "")
			if #cell >= #ELLIPSIS and cell:sub(-#ELLIPSIS) == ELLIPSIS then
				local from = span[1] + #cell - #ELLIPSIS
				mark(line, from, from + #ELLIPSIS, "NGripGridEllipsis", ELLIPSIS_PRIORITY)
			end
		end
	end

	if grid.footer then
		local line = grid.footer.line
		mark(line, 0, #(lines[line] or ""), "NGripGridFooter")
		for _, segment in ipairs(grid.footer.segments or {}) do
			mark(line, segment[1], segment[2], segment[3], ELLIPSIS_PRIORITY)
		end
	end
end

return M
