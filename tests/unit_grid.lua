-- Measuring and drawing cells.
local support = require("tests.support")
local check = support.check
local neogrip = require("neogrip")
local layout = require("neogrip.grid.layout")

support.describe("grid/layout: making a value printable")
check("newline", layout.sanitize("li\nnha"), "li↵nha")
check("terminal escapes removed", layout.sanitize("\27[31mred\27[0m"), "red")
check("control bytes", layout.sanitize("a\1b"), "a·b")
check("tab", layout.sanitize("a\tb"), "a b")
check("null", layout.sanitize(neogrip.NULL, "NULL"), "NULL")
check("number", layout.sanitize(42), "42")
check("boolean", layout.sanitize(true), "true")
check("a big integer is not rendered in exponent form", layout.sanitize(1234567890123), "1234567890123")

support.describe("grid/layout: truncating by display width")
check("ascii", layout.truncate("abcdefghij", 5), "abcd…")
check("exact fit", layout.truncate("abcde", 5), "abcde")
check("cjk", layout.truncate("日本語テキスト", 7), "日本語…")
check("cjk width", vim.fn.strdisplaywidth(layout.truncate("日本語テキスト", 7)), 7)
check(
	"emoji stays within the width",
	vim.fn.strdisplaywidth(layout.truncate("🚀🔥🚀🔥", 5)) <= 5,
	true
)
-- A cell far wider than the column: the point is that truncate measures by
-- binary search rather than walking the string, which used to be asserted with
-- a 50 ms wall clock. That failed whenever the machine was busy - six database
-- containers and a live suite were enough - so the shape of the answer is
-- asserted instead, with a budget loose enough to catch only a return to
-- something quadratic.
local huge = string.rep("x", 200000)
local started = vim.uv.hrtime()
local cut = layout.truncate(huge, 40)
local elapsed = (vim.uv.hrtime() - started) / 1e6
check("a huge cell is cut to the column", vim.fn.strdisplaywidth(cut), 40)
check("ending in the ellipsis", cut:sub(-#"…"), "…")
check("and nothing of the rest is carried", #cut < 100, true)
check("without walking the whole string", elapsed < 2000, true)

support.describe("grid/layout: widths and rendering")
local columns = { "id", "cjk", "txt" }
local rows = { { 1, "日本語", "a" }, { 2, "ab", neogrip.NULL } }
local computed = layout.compute(columns, rows, {})
check("a cjk column counts double", computed.widths[2], 6)
local lines, spans = layout.render(computed, columns, rows, {})
local widths = vim.tbl_map(vim.fn.strdisplaywidth, lines)
check("every line is the same width on screen", #vim.fn.uniq(vim.deepcopy(widths)), 1)
check("the header is there", lines[1]:find("cjk") ~= nil, true)
check("NULL is shown", lines[4]:find("NULL") ~= nil, true)
check("the span lands on a cjk cell", vim.trim(lines[3]:sub(spans[3][2][1] + 1, spans[3][2][2])), "日本語")
check("and on an ascii cell", vim.trim(lines[4]:sub(spans[4][2][1] + 1, spans[4][2][2])), "ab")
check("and on the header", vim.trim(lines[1]:sub(spans[1][2][1] + 1, spans[1][2][2])), "cjk")

local capped = layout.compute({ "x" }, { { string.rep("y", 500) } }, { max_width = 20 })
check("width is capped", capped.widths[1], 20)
check("and marked as truncated", capped.truncated[1], true)

support.describe("grid/layout: bytes that are not text")
check("a replacement character", layout.looks_binary("\1\2\239\191\189"), true)
check("plain text is not binary", layout.looks_binary("日本語"), false)
check("a number is not binary", layout.looks_binary(42), false)

support.describe("value: what a cell holds")
local value_module = require("neogrip.value")
check("null", value_module.kind(neogrip.NULL), "null")
check("a boolean", value_module.kind(true), "boolean")
check("a boolean the driver sent as text", value_module.kind("false"), "boolean")
check("an integer", value_module.kind(42), "number")
check("a decimal sent as exact text", value_module.kind("1234.5600"), "number")
check("a negative", value_module.kind("-7"), "number")
check("a zero-padded id is numeric", value_module.kind("05277982"), "number")
check("a date", value_module.kind("2026-10-06"), "date")
check("a timestamp", value_module.kind("2026-10-06 13:45:01.22"), "timestamp")
check("a timestamp with a T", value_module.kind("2026-10-06T13:45:01Z"), "timestamp")
check("a time", value_module.kind("13:45:01"), "time")
check("a uuid", value_module.kind("4f1d9c3e-2a7b-4c51-9f10-8d2e6b7a1c44"), "uuid")
check("json", value_module.kind('{"a": 1}'), "json")
check("an array", value_module.kind("[1, 2, 3]"), "json")
check("a table arrives as json", value_module.kind({ a = 1 }), "json")
check("a name is text", value_module.kind("JOÃO FELIPE PEREIRA DE ARAUJO"), "text")
check("a version is not a number", value_module.kind("1.2.3"), "text")
check(
	"prose that opens with a date is still prose",
	value_module.kind("2026-10-06 was when the migration ran and everything moved to the new schema"),
	"text"
)

support.describe("grid/layout: a cell's kind comes back with the lines")
local kind_columns = { "n", "flag", "when", "who", "nothing" }
local kind_rows = {
	{ 1, true, "2026-10-06", "MOTOR", neogrip.NULL },
	{ 2, false, "2026-10-07", "JOÃO FELIPE PEREIRA DE ARAUJO", "ok" },
}
local kind_layout = layout.compute(kind_columns, kind_rows, {})
local _, kind_spans, kinds = layout.render(kind_layout, kind_columns, kind_rows, {})
check("the header has no kinds", kinds[1], nil)
check("keyed by line, like the spans", vim.tbl_count(kinds), #kind_rows)
check("number", kinds[3][1], "number")
check("boolean", kinds[3][2], "boolean")
check("date", kinds[3][3], "date")
check("text", kinds[3][4], "text")
check("null", kinds[3][5], "null")

local binary_row = { { "ab99189" } }
local _, _, binary_kinds = layout.render(layout.compute({ "b" }, binary_row, {}), { "b" }, binary_row, {})
check("bytes that were never text beat any shape they match", binary_kinds[3][1], "binary")

support.describe("grid/highlight: painting the table")
local highlight = require("neogrip.grid.highlight")
local paint_lines = layout.render(kind_layout, kind_columns, kind_rows, {})
table.insert(paint_lines, "")
table.insert(paint_lines, "conn [trino]  ·  1-2  ·  12 ms")
local paint_buf = vim.api.nvim_create_buf(false, true)
vim.api.nvim_buf_set_lines(paint_buf, 0, -1, false, paint_lines)
local namespace = vim.api.nvim_create_namespace("neogrip_grid_test")
highlight.paint(paint_buf, namespace, {
	lines = paint_lines,
	spans = kind_spans,
	kinds = kinds,
	rows = #kind_rows,
	sorted_column = 3,
	footer = { line = #paint_lines, segments = { { 0, 12, "NGripGridConnection" } } },
})

-- Several marks can start at the same byte -- a stripe, the leading space and
-- the cell itself all begin the line -- so these are sets, not lookups.
local painted, mark_count = {}, {}
for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(paint_buf, namespace, 0, -1, { details = true })) do
	local line, column, group = mark[2] + 1, mark[3], mark[4].hl_group
	painted[("%d:%d:%s"):format(line, column, group)] = true
	mark_count[("%d:%d"):format(line, column)] = (mark_count[("%d:%d"):format(line, column)] or 0) + 1
end

local function painted_at(line, column, group)
	return painted[("%d:%d:%s"):format(line, kind_spans[line][column][1], group)] == true
end

check("the columns are named, not shouted", painted_at(1, 1, "NGripGridHeader"), true)
check("the column the rows are ordered by says so", painted_at(1, 3, "NGripGridHeaderSorted"), true)
check("the rule is furniture", painted["2:0:NGripGridRule"], true)
check("a number", painted_at(3, 1, "NGripGridNumber"), true)
check("a boolean", painted_at(3, 2, "NGripGridBoolean"), true)
check("a date", painted_at(3, 3, "NGripGridTemporal"), true)
check("null", painted_at(3, 5, "NGripGridNull"), true)
check("the │ between columns is dimmed", painted["3:0:NGripGridSeparator"], true)
check("text keeps the plain foreground", mark_count[("3:%d"):format(kind_spans[3][4][1])], nil)
check("every other row is tinted", painted["4:0:NGripGridStripe"], true)
check("and the one above it is not", painted["3:0:NGripGridStripe"], nil)
check("the footer is dim", painted[("%d:0:NGripGridFooter"):format(#paint_lines)], true)
check(
	"and names the connection that answered",
	painted[("%d:0:NGripGridConnection"):format(#paint_lines)],
	true
)

local number_hl = vim.api.nvim_get_hl(0, { name = "NGripGridNumber" })
check("the groups resolve to a real colour", number_hl.fg ~= nil, true)
check(
	"the cell under the cursor follows Visual",
	vim.api.nvim_get_hl(0, { name = "NGripGridCell", link = true }).link,
	"Visual"
)
vim.api.nvim_buf_delete(paint_buf, { force = true })

support.describe("grid/highlight: a truncated cell")
local narrow_columns = { "who" }
local narrow_rows = { { "JONATHAN RODRIGUES JESUS DE ASSUNCAO" } }
local narrow_layout = layout.compute(narrow_columns, narrow_rows, { max_width = 12 })
local narrow_lines, narrow_spans, narrow_kinds = layout.render(narrow_layout, narrow_columns, narrow_rows, {})
local narrow_buf = vim.api.nvim_create_buf(false, true)
vim.api.nvim_buf_set_lines(narrow_buf, 0, -1, false, narrow_lines)
highlight.paint(narrow_buf, namespace, {
	lines = narrow_lines,
	spans = narrow_spans,
	kinds = narrow_kinds,
	rows = #narrow_rows,
})
local ellipsis_marks = {}
for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(narrow_buf, namespace, 0, -1, { details = true })) do
	if mark[4].hl_group == "NGripGridEllipsis" then
		ellipsis_marks[#ellipsis_marks + 1] = { mark[2] + 1, mark[3], mark[4].end_col }
	end
end
check("the … that says the value goes on is dimmed", #ellipsis_marks, 1)
check("and only the … is", narrow_lines[3]:sub(ellipsis_marks[1][2] + 1, ellipsis_marks[1][3]), "…")
vim.api.nvim_buf_delete(narrow_buf, { force = true })

support.describe("grid: the optional row-number gutter")

local grid = require("neogrip.grid")
-- A fabricated state: three data rows under the two header lines. show() opens
-- the tab, so there is no buffer to hand it.
grid.show({
	columns = { "a" },
	rows = { { 1 }, { 2 }, { 3 } },
	connection = { name = "x", driver = "duckdb" },
}, { focus = false })
local gb = grid.current_buf()
check("header line has no number", grid.row_number_for(gb, 1), "")
check("rule line has no number", grid.row_number_for(gb, 2), "")
check("first data row is 1", grid.row_number_for(gb, 3), "   1 ")
check("third data row is 3", grid.row_number_for(gb, 5), "   3 ")
check("past the data is blank", grid.row_number_for(gb, 6), "")

-- The gutter width must not change while the result is being read: it used to
-- come straight from the row count, so crossing row 100 moved every line of
-- the table one cell to the right (ADR-0040).
local wide = {}
for index = 1, 99 do
	wide[index] = { index }
end
grid.add_page(gb, { rows = wide, done = false })
local at_99 = grid.row_number_for(gb, 3)
grid.add_page(gb, { rows = { { 100 } }, done = true })
check("the gutter is the same width at 100 rows as at 99", grid.row_number_for(gb, 3), at_99)
check("and it is the floor until four digits are needed", at_99, "   1 ")
grid.close(gb)

support.describe("grid: the winbar")

-- Asserted with no window at all: winbar_text takes a buffer and returns a
-- string, which is what keeps a redraw out of the test (ADR-0043).
grid.show({
	columns = { "a" },
	rows = { { 1 }, { 2 } },
	done = false,
	elapsed_ms = 7,
	connection = { name = "pg", driver = "postgres" },
}, { focus = false })
local bb = grid.current_buf()
local bar = grid.winbar_text(bb)
check("it names the connection and its driver", bar:find("pg [postgres]", 1, true) ~= nil, true)
check("counts the rows it holds", bar:find("2 rows", 1, true) ~= nil, true)
check("still promises more, as the footer does", bar:find("(more)", 1, true) ~= nil, true)
check("and ends in the elapsed time", bar:find("7 ms", 1, true) ~= nil, true)
check("each part carries its own group", bar:find("%%#NGripGridConnection#") ~= nil, true)
check("the slow time is marked as slow", bar:find("NGripGridSlow") == nil, true)

-- The footer and the winbar say the same things, from the same parts, so the
-- two cannot drift apart.
local footer_line = vim.api.nvim_buf_get_lines(bb, 0, -1, false)
footer_line = footer_line[#footer_line]
check("the winbar says what the footer says", (bar:gsub("%%#[%w]+#", "")), footer_line)

-- A per cent in a connection name would be read as the start of an item.
grid.state(bb).result.connection = { name = "100%", driver = "duckdb" }
check("a per cent in a name is escaped", grid.winbar_text(bb):find("100%%%%", 1, false) ~= nil, true)

check("a buffer with no result has no winbar", grid.winbar_text(vim.api.nvim_create_buf(false, true)), "")
grid.close(bb)

support.describe("grid: the tab list")

check("no result means no tabs", #grid.tabs(), 0)
check("and nothing active", grid.active_tab(), 0)

grid.show({
	columns = { "a" },
	rows = { { 1 } },
	connection = { name = "x", driver = "duckdb" },
}, { focus = false })
local only = grid.current_buf()
check("showing a result opens a tab", #grid.tabs(), 1)
check("which is the active one", grid.active_tab(), 1)
check("and is what current_buf answers", grid.tabs()[1], only)

-- Each tab's buffer name has to be its own: a hidden one the user has not
-- deleted still holds its name, and a duplicate name is an error.
local only_name = vim.api.nvim_buf_get_name(only)
check("the buffer is named after its number", only_name:find("neogrip://result/") ~= nil, true)

grid.close(only)
check("closing the last tab empties the list", #grid.tabs(), 0)
check("and leaves nothing active", grid.active_tab(), 0)
check("and nothing to answer with", grid.current_buf(), nil)
-- Reached again through BufDelete once the buffer is gone, so it has to be
-- harmless the second time.
check("forgetting it twice is harmless", pcall(grid.close, only), true)

support.describe("grid: appending a batch keeps the marks on the row before it")

-- The incremental clear is indexed off the rule line, and used to start one
-- line too early: it cleared the last row of the previous batch, which the
-- repaint loop never reaches because that starts at the first new row. Every
-- append therefore stripped the stripe, the separators and the value colour off
-- the row it appended after - invisible to every text assertion, so it is
-- asserted on the extmarks.
local append_ns = vim.api.nvim_create_namespace("neogrip_grid")
local function marks_on(bufnr, line)
	local out = {}
	for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(bufnr, append_ns, 0, -1, { details = true })) do
		if mark[2] + 1 == line then
			out[#out + 1] = ("%d:%s"):format(mark[3], mark[4].hl_group)
		end
	end
	table.sort(out)
	return out
end

grid.show({
	columns = { "n", "s" },
	rows = { { 1, "a" }, { 2, "b" }, { 3, "c" }, { 4, "d" } },
	done = false,
	connection = { name = "x", driver = "duckdb" },
}, { focus = false })
local append_buf = grid.current_buf()
-- Row 4 is even, so it carries a stripe, and it is the last one drawn.
local before_append = marks_on(append_buf, 4 + 2)
check("the last row is painted", #before_append > 0, true)

grid.add_page(append_buf, { rows = { { 5, "e" }, { 6, "f" } }, done = true })
check("it is still painted after the append", marks_on(append_buf, 4 + 2), before_append)
check("and the appended rows were painted too", #marks_on(append_buf, 6 + 2) > 0, true)
grid.close(append_buf)
