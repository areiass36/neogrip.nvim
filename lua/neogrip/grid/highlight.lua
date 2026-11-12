-- Colour in the result grid: cells painted in the colourscheme's own literal
-- colours, the table's furniture dimmed to the window-separator colour.
local config = require("neogrip.config")

local M = {}

local ELLIPSIS = "…"

local HEADER_LINE = 1
local RULE_LINE = 2

-- The layers tint below and paint over treesitter; see doc/internals.md#grid.
local STRIPE_PRIORITY = 90
local CONTENT_PRIORITY = 100
local ELLIPSIS_PRIORITY = 105

--- @type table<string, { fg: string[]|nil, bg: string[]|nil, link: string|nil }>
--- fg/bg list the source groups, best first: the first whose attribute differs
--- from Normal's wins, so a cell is never painted the colour it already was.
local SPEC = {
	NGripGridHeader = { fg = { "@attribute", "Function", "Identifier" }, bold = true },
	-- The column the result is ordered by, otherwise invisible once the rows come back sorted.
	NGripGridHeaderSorted = { fg = { "@attribute", "Function", "Identifier" }, bold = true, underline = true },
	NGripGridRule = { fg = { "WinSeparator", "VertSplit", "NonText" } },
	NGripGridSeparator = { fg = { "WinSeparator", "VertSplit", "NonText" } },
	-- The stripe is what keeps a wide row readable all the way across.
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

	-- The winbar's tab strip (ADR-0045), in the native tabline's faces; named
	-- in the statusline string itself rather than painted with extmarks.
	NGripGridTab = { link = "TabLine" },
	NGripGridTabActive = { link = "TabLineSel" },
	NGripGridTabFill = { link = "TabLineFill" },
	NGripGridTabRunning = { fg = { "@number", "Number" }, bg = { "TabLine", "StatusLineNC" } },
	NGripGridTabError = { fg = { "DiagnosticError", "ErrorMsg" }, bg = { "TabLine", "StatusLineNC" } },
}

--- value.kind -> the group that paints it. "text" is deliberately absent: it keeps Normal.
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

--- The first of `names` that carries `field` with a value different from Normal's.
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

--- Define the groups; `default = true` makes a second call a no-op and lets a user override win.
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

	-- :colorscheme clears every group and the colours here are resolved, not
	-- linked, so they are rebuilt on ColorScheme.
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

--- `grid.from` paints and clears only from that row down; the stripe parity is
--- the absolute row number, which holds because rows accumulate and never shift (ADR-0040).
--- @param grid { lines: string[], spans: table, kinds: table, rows: integer,
--- sorted_column: integer|nil, footer: { line: integer, segments: table }|nil,
--- from: integer|nil }
function M.paint(bufnr, namespace, grid)
	if not vim.api.nvim_buf_is_valid(bufnr) then
		return
	end
	M.setup()
	local first_row = math.max(grid.from or 1, 1)
	if first_row == 1 then
		vim.api.nvim_buf_clear_namespace(bufnr, namespace, 0, -1)
	else
		-- Clear from the batch's own first line; see doc/internals.md#grid.
		vim.api.nvim_buf_clear_namespace(bufnr, namespace, first_row + RULE_LINE - 1, -1)
	end

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

	-- Everything on the line that is not a cell.
	local function furniture(line, line_spans)
		local previous = 0
		for _, span in ipairs(line_spans) do
			mark(line, previous, span[1], "NGripGridSeparator")
			previous = span[2]
		end
		mark(line, previous, #(lines[line] or ""), "NGripGridSeparator")
	end

	if first_row == 1 then
		local header_spans = grid.spans[HEADER_LINE] or {}
		for index, span in ipairs(header_spans) do
			local sorted = grid.sorted_column == index
			mark(HEADER_LINE, span[1], span[2], sorted and "NGripGridHeaderSorted" or "NGripGridHeader")
		end
		furniture(HEADER_LINE, header_spans)
		mark(RULE_LINE, 0, #(lines[RULE_LINE] or ""), "NGripGridRule")
	end

	for row = first_row, grid.rows do
		local line = row + RULE_LINE
		local line_spans = grid.spans[line] or {}
		local kinds = grid.kinds[line] or {}
		if striped and row % 2 == 0 then
			mark(line, 0, #(lines[line] or ""), "NGripGridStripe", STRIPE_PRIORITY)
		end
		furniture(line, line_spans)
		for index, span in ipairs(line_spans) do
			mark(line, span[1], span[2], KIND_GROUPS[kinds[index]])
			-- Dim the ellipsis so a truncated cell is obvious without reading it.
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

--- Clear and repaint one status line (ADR-0045); see doc/internals.md#grid.
function M.paint_line(bufnr, namespace, line, text, segments)
	if not vim.api.nvim_buf_is_valid(bufnr) then
		return
	end
	M.setup()
	vim.api.nvim_buf_clear_namespace(bufnr, namespace, line - 1, line)
	local function mark(from, to, group, priority)
		if not group or from >= to then
			return
		end
		pcall(vim.api.nvim_buf_set_extmark, bufnr, namespace, line - 1, from, {
			end_col = to,
			hl_group = group,
			priority = priority or CONTENT_PRIORITY,
		})
	end
	mark(0, #text, "NGripGridFooter")
	for _, segment in ipairs(segments or {}) do
		mark(segment[1], segment[2], segment[3], ELLIPSIS_PRIORITY)
	end
end

return M
