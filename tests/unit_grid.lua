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
local huge = string.rep("x", 200000)
local started = vim.uv.hrtime()
layout.truncate(huge, 40)
check("a huge cell truncates quickly", (vim.uv.hrtime() - started) / 1e6 < 50, true)

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
-- A fabricated state: three data rows under the two header lines.
local rownum_buf = vim.api.nvim_create_buf(false, true)
require("neogrip.grid").buf = rownum_buf
-- Reach into show() by faking a minimal result so states[buf] exists.
grid.show({
	columns = { "a" },
	rows = { { 1 }, { 2 }, { 3 } },
	connection = { name = "x", driver = "duckdb" },
}, { focus = false })
local gb = grid.current_buf()
check("header line has no number", grid.row_number_for(gb, 1), "")
check("rule line has no number", grid.row_number_for(gb, 2), "")
check("first data row is 1", grid.row_number_for(gb, 3), "1 ")
check("third data row is 3", grid.row_number_for(gb, 5), "3 ")
check("past the data is blank", grid.row_number_for(gb, 6), "")
grid.close(gb)
