-- The path a command takes: statement under the cursor, grid, paging, server
-- side sorting. Grid actions and the DuckDB requery are exercised in their own
-- suites once those phases land.
local support = require("tests.support")
local check, note = support.check, support.note
local neogrip = require("neogrip")

support.describe("live/flow")
if not support.has_jdk() then
	note("skipped: no JDK available (set NEOGRIP_TEST_JDK)")
	return
end
support.seed_secrets()

local connections = support.connections()
local pg = connections.postgres
if not support.reachable(pg) then
	note("skipped: nothing listening (tests/containers.sh up)")
	return
end

local execute = require("neogrip.execute")
local grid = require("neogrip.grid")
local resolve = require("neogrip.resolve")
local connections_module = require("neogrip.connections")

-- Make the test connection resolvable by id, the way a project file would.
connections_module.register(pg)

local bufnr = vim.api.nvim_create_buf(false, true)
vim.bo[bufnr].filetype = "sql"
vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {
	"-- a comment with a ; in it",
	"select id, s_comma, s_null, cjk from torture order by id;",
	"",
	"select count(*) as n from torture;",
})
vim.api.nvim_set_current_buf(bufnr)
resolve.bind(bufnr, pg.id)

vim.api.nvim_win_set_cursor(0, { 2, 0 })
local ran = support.sync(function(done)
	execute.run({ bufnr = bufnr, on_done = done })
end)
check("the first statement ran", ran ~= nil, true)

local result_buf = grid.current_buf()
check("a grid was opened", result_buf ~= nil, true)
local state = grid.state(result_buf)
check("columns", state.columns, { "id", "s_comma", "s_null", "cjk" })
check("rows", #state.rows, 2)
check("NULL is kept as NULL in the state", state.rows[1][3] == neogrip.NULL, true)

local lines = vim.api.nvim_buf_get_lines(result_buf, 0, -1, false)
check("the header names a column", lines[1]:find("s_comma") ~= nil, true)
check("NULL is drawn", lines[3]:find("NULL") ~= nil, true)
check("the footer names the connection", lines[#lines]:find(pg.name, 1, true) ~= nil, true)
check("the result buffer is its own filetype", vim.bo[result_buf].filetype, "neogrip-grid")
check("and not editable", vim.bo[result_buf].modifiable, false)

support.describe("live/flow: the cursor picks the statement")
vim.api.nvim_set_current_buf(bufnr)
vim.api.nvim_win_set_cursor(0, { 4, 0 })
support.sync(function(done)
	execute.run({ bufnr = bufnr, on_done = done })
end)
state = grid.state(grid.current_buf())
check("the second statement ran", state.columns, { "n" })
check("its value", state.rows[1][1], 2)

support.describe("live/flow: readonly refuses writes in layers")
local readonly = vim.tbl_extend("force", vim.deepcopy(pg), { id = "test-pg-ro", readonly = true })
connections_module.register(readonly)
-- The Lua classifier is the first layer.
local _, lua_refused = support.run(readonly, "delete from torture", { mode = "exec" })
-- The classifier never sees this path (support.run goes straight to the
-- runner), so the sidecar's own keyword check answers.
check("the sidecar refuses a write on a readonly connection", lua_refused ~= nil, true)
if lua_refused then
	note("refusal: " .. tostring(lua_refused.message))
end
local still_there = support.scalar(readonly, "select count(*) from torture")
check("and the rows are still there", still_there, 2)

support.describe("live/flow: paging")
-- A table with more rows than one page.
support.run(pg, "drop table if exists paging", { mode = "exec" })
support.run(pg, "create table paging as select generate_series(1, 25) as n", { mode = "exec" })

local paging_buf = vim.api.nvim_create_buf(false, true)
vim.bo[paging_buf].filetype = "sql"
vim.api.nvim_buf_set_lines(paging_buf, 0, -1, false, { "select n from paging order by n;" })
vim.api.nvim_set_current_buf(paging_buf)
resolve.bind(paging_buf, pg.id)

support.sync(function(done)
	execute.run({ bufnr = paging_buf, limit = 10, on_done = done })
end)
local page_buf = grid.current_buf()
state = grid.state(page_buf)
check("a full page", #state.rows, 10)
check("first row", state.rows[1][1], 1)
check("and the result stays open", state.result.done, false)
local page_lines = vim.api.nvim_buf_get_lines(page_buf, 0, -1, false)
check("the footer says which rows", page_lines[#page_lines]:find("1%-10") ~= nil, true)

local before_rows = vim.deepcopy(state.rows)
execute.page(state, 1)
support.wait(function()
	local current = grid.state(grid.current_buf())
	return current and current.rows[1] and current.rows[1][1] ~= before_rows[1][1]
end, 20000)
state = grid.state(grid.current_buf())
check("the next page starts where the last ended", state.rows[1][1], 11)
check("and still has more", state.result.done, false)
check("without running the statement again", #state.pages, 2)

execute.page(state, 1)
support.wait(function()
	local current = grid.state(grid.current_buf())
	return current and current.rows[1] and current.rows[1][1] == 21
end, 20000)
state = grid.state(grid.current_buf())
check("the last page is short", #state.rows, 5)
check("and says so", state.result.done, true)

-- Going back is a redraw of rows that never left the editor, so it is
-- synchronous: there is nothing to wait for (ADR-0031).
execute.page(grid.state(grid.current_buf()), -1)
check("and going back works", grid.state(grid.current_buf()).rows[1][1], 11)
check("with no fourth request for three pages", #grid.state(grid.current_buf()).pages, 3)

support.describe("live/flow: sorting is done by the server")
state = grid.state(grid.current_buf())
execute.sort(state, "n", true)
support.wait(function()
	local current = grid.state(grid.current_buf())
	return current and current.rows[1] and current.rows[1][1] == 25
end, 20000)
state = grid.state(grid.current_buf())
check("descending starts at the highest row of the whole table", state.rows[1][1], 25)
-- A sort is a different result, so the pages of the old one go with it.
check("not just of the page", state.page, 1)
check("and the old pages are gone", #state.pages, 1)
support.run(pg, "drop table if exists paging", { mode = "exec" })
