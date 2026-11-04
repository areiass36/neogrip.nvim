-- The grid loading as the cursor goes down, against a real cursor on a real
-- server (ADR-0040): every row arriving exactly once and in order, the window
-- not jumping when a batch lands, and the idle sweep still closing a result
-- nobody reads - which with no cap on open results is the only automatic
-- reclamation left (ADR-0041).
local support = require("tests.support")
local check, note = support.check, support.note

support.describe("live/autoload")
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

local config = require("neogrip.config")
local execute = require("neogrip.execute")
local grid = require("neogrip.grid")
local resolve = require("neogrip.resolve")
local runner = require("neogrip.runner")
local connections_module = require("neogrip.connections")

connections_module.register(pg)

-- Past Cursor.WINDOW twice, so the refill gripd does every thousand rows has
-- to stay invisible to a reader scrolling through them (ADR-0031).
local TOTAL = 2050
support.run(pg, "drop table if exists autoload_probe", { mode = "exec" })
support.run(
	pg,
	("create table autoload_probe as select generate_series(1, %d) as n"):format(TOTAL),
	{ mode = "exec" }
)

local saved = config.get().auto_load_rows
config.setup({ auto_load_rows = 5, limit = 10 })

local bufnr = vim.api.nvim_create_buf(false, true)
vim.bo[bufnr].filetype = "sql"
vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "select n from autoload_probe order by n;" })
vim.api.nvim_set_current_buf(bufnr)
resolve.bind(bufnr, pg.id)
vim.api.nvim_win_set_cursor(0, { 1, 0 })

local ran = support.sync(function(done)
	execute.run({ bufnr = bufnr, limit = 10, on_done = done })
end, 90000)
check("the statement ran", ran ~= nil, true)

local gb = grid.current_buf()
local state = grid.state(gb)
check("the first batch is on screen", state and #state.rows, 10)
check("and the result stays open", state.result.done, false)

-- A real window and a real cursor, with the event delivered by hand.
--
-- Measured here: nvim_win_set_cursor moves the cursor but CursorMoved is not
-- emitted under --headless -l, so waiting for the autocommand to fire on its
-- own waits forever. Firing it explicitly still exercises everything this
-- suite is about - the callback, sync_from_cursor, and maybe_load_more reading
-- the window it was given rather than a line a test made up.
local winid = vim.fn.bufwinid(gb)
check("the grid has a window to scroll in", winid ~= -1, true)
if winid ~= -1 then
	vim.api.nvim_set_current_win(winid)

	local steps = 0
	repeat
		local before = #grid.state(gb).rows
		-- The last data row: line = row + 2.
		vim.api.nvim_win_set_cursor(winid, { before + 2, 0 })
		vim.api.nvim_exec_autocmds("CursorMoved", { buffer = gb })
		support.wait(function()
			local current = grid.state(gb)
			return current and (#current.rows > before or current.result.done ~= false)
		end, 30000)
		steps = steps + 1
		state = grid.state(gb)
	until state.result.done ~= false or #state.rows >= TOTAL or steps > 400

	check("scrolling reached the end of the result", state.result.done, true)
	check("and loaded every row", #state.rows, TOTAL)
	note(("%d rows over %d stops of the cursor"):format(#state.rows, steps))

	local ordered, missing = true, nil
	for index = 1, TOTAL do
		local row = state.rows[index]
		if not row or tonumber(row[1]) ~= index then
			ordered = false
			missing = index
			break
		end
	end
	-- Each row once and in order: a batch appended at the wrong offset, or a
	-- refill that resumed in the wrong place, shows up here and nowhere else.
	check("every row arrived once, in order", ordered, true)
	if not ordered then
		note(("first wrong row: %s"):format(tostring(missing)))
	end

	-- Header, rule, the rows, a blank and the footer.
	local lines = vim.api.nvim_buf_get_lines(gb, 0, -1, false)
	check("the buffer holds all of them", #lines, TOTAL + 4)
	check("the footer counts them", lines[#lines]:find("2050 rows", 1, true) ~= nil, true)
	check("and stops promising more", lines[#lines]:find("(more)", 1, true), nil)

	-- The cursor must not be moved by a batch arriving, which is the regression
	-- the whole change is about: goto_page used to put it back on row one.
	local held = #grid.state(gb).rows
	local resting = math.max(held - 3, 1) + 2
	vim.api.nvim_win_set_cursor(winid, { resting, 0 })
	vim.api.nvim_exec_autocmds("CursorMoved", { buffer = gb })
	support.wait(function()
		return false
	end, 400)
	check("the cursor is left where the reader put it", vim.api.nvim_win_get_cursor(winid)[1], resting)
	check("and a finished result loads nothing more", #grid.state(gb).rows, held)
end

grid.close(gb)
config.setup({ auto_load_rows = saved })

support.describe("live/autoload: the idle sweep still closes what nobody reads")
do
	-- With no cap on open results (ADR-0041) this sweep is the only automatic
	-- reclamation there is, and it had no live coverage at all.
	local idle = vim.tbl_extend("force", pg, { id = "test-pg-idle" })
	connections_module.register(idle)
	config.setup({ cursor_idle_seconds = 1 })

	local opened = support.run(idle, "select n from autoload_probe order by n", { limit = 5 })
	check("a result is open", opened ~= nil and opened.hash ~= nil, true)
	if opened and opened.hash then
		local more = support.next_batch(idle, opened.hash, 5)
		check("and answers while it is being read", more ~= nil and #more.rows, 5)

		-- The watchdog ticks every 15 s, so this waits past one tick.
		support.wait(function()
			return false
		end, 20000)
		local _, err = support.next_batch(idle, opened.hash, 5)
		check("an hour is the default, but one second closes it", err ~= nil, true)
		if err then
			check(
				"and the refusal names the result",
				err.message:find("no result is open under", 1, true) ~= nil,
				true
			)
			check("as a refusal, not a failed statement", err.rpc_code, -32600)
		end
	end
	config.setup({})
	require("neogrip.gripd").disconnect(idle.id)
end

support.run(pg, "drop table if exists autoload_probe", { mode = "exec" })
runner.cancel_all()
