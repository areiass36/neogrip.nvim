-- Dialect-specific highlighting, and the T-SQL fallback.
local support = require("tests.support")
local check = support.check
local dialect = require("neogrip.dialect")

support.describe("dialect: the extra keyword layer")
local bufnr = vim.api.nvim_create_buf(false, true)
vim.bo[bufnr].filetype = "sql"
vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {
	"select jsonb_agg(x) from t where a ilike 'jsonb_agg'",
	"-- jsonb_agg in a comment",
})
dialect.attach(bufnr, "postgres")
check("the dialect is recorded on the buffer", vim.b[bufnr].neogrip_dialect, "postgres")

local marks = dialect.draw_now(bufnr)
local function marked_text(mark)
	local row, col = mark[2], mark[3]
	local line = vim.api.nvim_buf_get_lines(bufnr, row, row + 1, false)[1]
	return line:sub(col + 1, mark[4].end_col), row
end

local highlighted = {}
for _, mark in ipairs(marks) do
	local text, row = marked_text(mark)
	highlighted[#highlighted + 1] = { text = text, row = row, group = mark[4].hl_group }
end

local found_function = false
for _, mark in ipairs(highlighted) do
	if mark.text == "jsonb_agg" and mark.row == 0 and mark.group == "@function.builtin" then
		found_function = true
	end
end
check("a postgres function is highlighted", found_function, true)
check(
	"priority above treesitter",
	marks[1]
		and vim.api.nvim_buf_get_extmarks(
			bufnr,
			vim.api.nvim_create_namespace("neogrip_dialect"),
			0,
			-1,
			{ details = true }
		)[1][4].priority,
	110
)

support.describe("dialect: priorities in this neovim")
check("treesitter highlights at 100", vim.hl.priorities.treesitter, 100)
check("so 110 wins without hiding diagnostics", vim.hl.priorities.diagnostics > 110, true)

support.describe("dialect: sql server uses the syntax file, not treesitter")
local tsql_buf = vim.api.nvim_create_buf(false, true)
vim.bo[tsql_buf].filetype = "sql"
vim.api.nvim_buf_set_lines(tsql_buf, 0, -1, false, { "select top 10 [order] from dbo.t where @id = 1" })
dialect.attach(tsql_buf, "mssql")
-- Applying the syntax is scheduled: doing it inline would be undone by the
-- runtime's own syntax autocommand.
support.wait(function()
	return vim.bo[tsql_buf].syntax == "tsql"
end, 2000)
check("syntax switched", vim.bo[tsql_buf].syntax, "tsql")
check("the dialect is recorded", vim.b[tsql_buf].neogrip_dialect, "mssql")

-- and back again
dialect.attach(tsql_buf, "postgres")
support.wait(function()
	return vim.bo[tsql_buf].syntax ~= "tsql"
end, 2000)
check("switching back gives up the tsql syntax", vim.bo[tsql_buf].syntax ~= "tsql", true)

support.describe("dialect: mongo is javascript")
local mongo_buf = vim.api.nvim_create_buf(false, true)
dialect.attach(mongo_buf, "mongodb")
check("filetype", vim.bo[mongo_buf].filetype, "mongodb")

support.describe("dialect: keywords inside a string or comment are left alone")
local tricky = vim.api.nvim_create_buf(false, true)
vim.bo[tricky].filetype = "sql"
vim.api.nvim_buf_set_lines(tricky, 0, -1, false, {
	"select jsonb_agg(id), ilike_not_a_func from t where x ilike 'jsonb_agg' -- jsonb_agg",
	"-- jsonb_agg in a comment",
	"select 'it''s jsonb_agg' as s",
})
dialect.attach(tricky, "postgres")
local drawn = dialect.draw_now(tricky)
local by_text = {}
for _, mark in ipairs(drawn) do
	local line = vim.api.nvim_buf_get_lines(tricky, mark[2], mark[2] + 1, false)[1]
	by_text[#by_text + 1] = { text = line:sub(mark[3] + 1, mark[4].end_col), row = mark[2], col = mark[3] }
end

local function marked_at(row, col)
	for _, mark in ipairs(by_text) do
		if mark.row == row and mark.col == col then
			return mark.text
		end
	end
	return nil
end

check("the function call is highlighted", marked_at(0, 7), "jsonb_agg")
check("ilike is highlighted", marked_at(0, 54), "ilike")
check("a longer identifier is not split", marked_at(0, 22), nil)
check("the keyword inside the string is not", marked_at(0, 61), nil)
check("nor the one in the trailing comment", marked_at(0, 75), nil)
check("nor one in a whole-line comment", marked_at(1, 3), nil)
check("nor one inside a string with a doubled quote", marked_at(2, 13), nil)
check("so only two marks on the first line", #vim.tbl_filter(function(mark)
	return mark.row == 0
end, by_text), 2)
