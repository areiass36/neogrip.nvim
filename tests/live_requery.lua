-- Grid actions and the DuckDB requery, end to end with no server: a DuckDB
-- result becomes a grid, the grid becomes CSV, the CSV becomes views, and the
-- views answer SQL - including a standalone CSV from disk (ADR-0021).
local support = require("tests.support")
local check, note = support.check, support.note
support.describe("live/requery")
if not support.has_jdk() then
	note("skipped: no JDK available (set NEOGRIP_TEST_JDK)")
	return
end
support.seed_secrets()
local duck = support.connections().duckdb
local connections_module = require("neogrip.connections")
connections_module.register(duck)
local created = support.run(
	duck,
	"create or replace table torture as select * from "
		.. "(values (1,NULL,'','a,b','日本語'),(2,NULL,'','x','中文')) t(id,s_null,s_empty,s_comma,cjk)",
	{ mode = "exec", timeout = 90000 }
)
if not created then
	support.fail("duckdb table", "could not create the fixture table")
	return
end
local execute = require("neogrip.execute")
local grid = require("neogrip.grid")
local resolve = require("neogrip.resolve")
local actions = require("neogrip.grid.actions")
local bufnr = vim.api.nvim_create_buf(false, true)
vim.bo[bufnr].filetype = "sql"
vim.api.nvim_buf_set_lines(
	bufnr,
	0,
	-1,
	false,
	{ "select id, s_comma, s_null, cjk from torture order by id;" }
)
vim.api.nvim_set_current_buf(bufnr)
resolve.bind(bufnr, duck.id)
support.sync(function(done)
	execute.run({ bufnr = bufnr, on_done = done })
end, 90000)
local result_buf = grid.current_buf()
check("a grid was opened", result_buf ~= nil, true)
local state = grid.state(result_buf)
support.describe("live/requery: taking values out through actions")
state.row, state.column = 1, 2
actions.yank_cell(result_buf)
check("a cell yanks its stored value", vim.fn.getreg('"'), "a,b")
state.column = 3
actions.yank_cell(result_buf)
check("a NULL cell", vim.fn.getreg('"'), "NULL")
actions.yank_row(result_buf)
check("a row yanks as csv", vim.fn.getreg('"'), '1,"a,b",,日本語')
state.column = 4
actions.yank_column(result_buf)
check("a column yanks every value", vim.fn.getreg('"'), "日本語\n中文")
-- A truncated cell must still yank in full.
local long = string.rep("z", 300)
state.rows[1][2] = long
grid.refresh(result_buf)
state.row, state.column = 1, 2
actions.yank_cell(result_buf)
check("a truncated cell yanks untruncated", vim.fn.getreg('"'), long)
state.rows[1][2] = "a,b"
grid.refresh(result_buf)
support.describe("live/requery: cell navigation through actions")
state.row, state.column = 1, 1
actions.next_column(result_buf)
check("moving right", state.column, 2)
actions.down(result_buf)
check("moving down", state.row, 2)
actions.move(result_buf, 5, 5)
check("stops at the last row", state.row, #state.rows)
check("and the last column", state.column, #state.columns)
actions.move(result_buf, -10, -10)
check("and at the first", { state.row, state.column }, { 1, 1 })
actions.last_column(result_buf)
check("jump to the last column", state.column, #state.columns)
actions.first_row(result_buf)
check("jump to the first row", state.row, 1)
support.describe("live/requery: the result becomes a queryable CSV")
local export = require("neogrip.grid.export")
local requery = require("neogrip.grid.requery")
local path = ("%s/test.csv"):format(export.results_dir())
export.page_to_csv(state, path)
check("a csv was written", vim.fn.filereadable(path), 1)
local csv_lines = vim.fn.readfile(path)
check("with a header", csv_lines[1], "id,s_comma,s_null,cjk")
check("and the null marker", csv_lines[2]:find("\\N", 1, true) ~= nil, true)
local view, register_err = support.sync(function(done)
	requery.register(path, { name = "testview" }, function(name, err)
		done(name, err)
	end)
end, 90000)
check("registered as a view", view, "testview")
if register_err then
	note(tostring(register_err))
end
local count = support.scalar(requery.connection(), "select count(*) from testview")
check("the view has the rows", count, 2)
local cjk = support.scalar(requery.connection(), "select max(cjk) from testview")
check("utf-8 survived the round trip", cjk, "日本語")
local nulls = support.scalar(requery.connection(), "select count(*) from testview where s_null is null")
check("and so did NULL, as NULL", nulls, 2)
local commas = support.scalar(requery.connection(), "select count(*) from testview where s_comma = 'a,b'")
check("a comma inside a value survived", commas, 1)
local alias = support.scalar(requery.connection(), "select count(*) from last")
check("the stable alias points at the latest result", alias, 2)
support.describe("live/requery: column names are made safe for SQL")
check(
	"mixed case and punctuation",
	export.safe_columns({ "Total $", "count(*)", "1st" }),
	{ "total__", "count___", "c_1st" }
)
check("duplicates are numbered", export.safe_columns({ "a", "a", "a" }), { "a", "a_2", "a_3" })
support.describe("live/requery: a standalone CSV from disk")
local standalone = vim.fn.tempname() .. ".csv"
vim.fn.writefile({ "name,qty", "ana,3", '"li,nha",5' }, standalone)
local csv_buf = support.sync(function(done)
	requery.query_csv(vim.fs.normalize(standalone), done)
end, 90000)
check("a query buffer opened on the csv", csv_buf ~= nil, true)
local qty = support.scalar(requery.connection(), "select sum(cast(qty as int)) from last")
check("the csv answers sql", qty, 8)
vim.fn.delete(standalone)
support.describe("live/requery: a materialised result is queried through its own connection")
local view_connection = requery.connection()
check("the scratch connection is registered", connections_module.get(view_connection.id) ~= nil, true)
local scratch_query = require("neogrip.buffer").new_query(view_connection, "select 1 as a;")
check("a buffer opened on it resolves to it", resolve.for_buf(scratch_query).id, view_connection.id)
check("and not to the project's database", resolve.for_buf(scratch_query).driver, "duckdb")
support.describe("live/requery: the full export streams from the sidecar")
vim.api.nvim_set_current_buf(bufnr)
support.sync(function(done)
	execute.run({ bufnr = bufnr, on_done = done })
end, 90000)
state = grid.state(grid.current_buf())
local full = ("%s/full.csv"):format(export.results_dir())
local exported = support.sync(function(done)
	require("neogrip.runner").run({
		connection = duck,
		sql = state.result.sql,
		mode = "export",
		limit = 0,
		out_file = full,
		null_marker = "\\N",
	}, done)
end, 90000)
check("the export reports its row count", exported and exported.rows_written, 2)
check("and the file is in place", vim.fn.filereadable(full), 1)
local exported_json = support.sync(function(done)
	require("neogrip.runner").run({
		connection = duck,
		sql = state.result.sql,
		mode = "export",
		format = "json",
		limit = 0,
		out_file = ("%s/full.json"):format(export.results_dir()),
	}, done)
end, 90000)
check("a json export too", exported_json and exported_json.rows_written, 2)
local decoded =
	vim.json.decode(table.concat(vim.fn.readfile(("%s/full.json"):format(export.results_dir())), "\n"))
check("whose rows decode", { #decoded, decoded[1].cjk, decoded[1].s_null }, { 2, "日本語", vim.NIL })
