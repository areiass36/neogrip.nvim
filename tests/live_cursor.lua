-- The result cursor against real servers: open-continue-finish on every
-- engine, the window refill, and the lifetime rules.
local support = require("tests.support")
local check, note = support.check, support.note
local gripd = require("neogrip.gripd")

if not support.has_jdk() then
	support.describe("live/cursor")
	note("skipped: no JDK available (set NEOGRIP_TEST_JDK)")
	return
end
support.seed_secrets()

local connections = support.connections()
local order = { "postgres", "mysql", "mariadb", "mssql", "sqlite", "duckdb", "mongodb", "trino" }

for _, driver in ipairs(order) do
	local connection = connections[driver]
	support.describe("live/cursor/" .. driver)

	if not support.reachable(connection) then
		note("skipped: nothing listening (tests/containers.sh up)")
	else
		support.ensure_fixture(connection)
		if driver == "duckdb" then
			-- DuckDB refuses a file written by another driver version.
			support.run(
				connection,
				"create or replace table torture as select * from " .. "(values (1,'a'),(2,'b')) t(id,s)",
				{ mode = "exec" }
			)
		end

		local probe = driver == "trino" and "memory.default.torture" or "torture"
		local sql = driver == "mongodb" and "db.orders.find({})"
			or ("select * from %s order by id"):format(probe)
		local first, first_err = support.run(connection, sql, { limit = 1, timeout = 90000 })
		if first_err then
			support.fail("opening a result", first_err.message)
		else
			check("the first batch is one row", #first.rows, 1)
			check("the result stays open", first.done, false)
			check("and carries the name the client gave it", type(first.hash), "string")
			check("the shape arrives with the first batch", #(first.columns or {}) > 0, true)

			local second, second_err = support.next_batch(connection, first.hash, 1)
			if second_err then
				support.fail("continuing a result", second_err.message)
			else
				check("the second batch is the next row", #second.rows, 1)
				check("a different row", second.rows[1][1] ~= first.rows[1][1], true)
				check("the fixtures have two, so it is finished", second.done, true)
				-- Only a document result that grew its columns re-sends the shape.
				check("and the shape is not repeated", second.columns, nil)
			end

			local gone, gone_err = support.next_batch(connection, first.hash, 1)
			check("a finished result is closed", gone, nil)
			check("and continuing it is refused", gone_err ~= nil, true)
		end
	end
end

local pg = connections.postgres
if not support.reachable(pg) then
	support.describe("live/cursor: the window")
	note("skipped: postgres is where the window is measured")
	return
end

support.describe("live/cursor: the window refills without the client noticing")

-- 2050 rows in batches of 300 cross the 1000-row window twice, and the refills must
-- leave no mark on the rows or the batch sizes (ADR-0031). More than one progress
-- frame for the same hash is the only direct proof the emission sits inside Cursor (ADR-0042).
local TOTAL, PAGE = 2050, 300
local executions = 0
local function count_executing(event)
	if event.phase == "executing" then
		executions = executions + 1
	end
end
support.run(pg, "drop table if exists window_probe", { mode = "exec" })
support.run(
	pg,
	("create table window_probe as select generate_series(1, %d) as n"):format(TOTAL),
	{ mode = "exec" }
)

local sql = "select n from window_probe order by n"
local batch, batch_err =
	support.run(pg, sql, { limit = PAGE, timeout = 90000, on_progress = count_executing })
if batch_err then
	support.fail("opening the window probe", batch_err.message)
else
	local expected = 1
	local batches = 0
	local ok = true
	local full = true
	while batch do
		batches = batches + 1
		for _, row in ipairs(batch.rows) do
			if row[1] ~= expected then
				ok = false
			end
			expected = expected + 1
		end
		-- A batch straddling the window must refill mid-collection, not come up short.
		if not batch.done and #batch.rows ~= PAGE then
			full = false
		end
		if batch.done then
			break
		end
		if batches > 20 then
			support.fail("the window probe never finished", batches .. " batches")
			break
		end
		local continued, err = support.next_batch(pg, batch.hash, PAGE, { on_progress = count_executing })
		if err then
			support.fail("batch " .. (batches + 1), err.message)
			break
		end
		batch = continued
	end

	check("every row arrived exactly once, in order", ok, true)
	check("all of them", expected - 1, TOTAL)
	check("every batch but the last was full", full, true)
	check("so the count is the page size and nothing else", batches, math.ceil(TOTAL / PAGE))
	check("and the last one carries the remainder", #batch.rows, TOTAL % PAGE)
	-- "More than one" rather than exactly three, so the check is about the refill
	-- reporting at all and not about where the window falls.
	check("every execution announced itself, refills included", executions > 1, true)
end

support.describe("live/cursor: a continuation does not run the statement again")

-- A row inserted between pages is the only outside proof of no re-execution; the
-- regression behind it cost a 226s Trino aggregate a second full run.
support.run(pg, "drop table if exists continuity_probe", { mode = "exec" })
support.run(pg, "create table continuity_probe as select generate_series(2, 9) * 10 as n", { mode = "exec" })

local opened = support.run(pg, "select n from continuity_probe order by n", { limit = 3 })
check("the first page is the lowest three", opened.rows, { { 20 }, { 30 }, { 40 } })
support.run(pg, "insert into continuity_probe values (25)", { mode = "exec" })
local continued = support.next_batch(pg, opened.hash, 3)
check("the second page continues past them", continued.rows, { { 50 }, { 60 }, { 70 } })
-- A re-execution would have sorted 25 into third place and handed back 30, 40, 50.
check("and never sees the row inserted meanwhile", continued.rows[1][1] ~= 30, true)
support.run(pg, "drop table if exists continuity_probe", { mode = "exec" })

support.describe("live/cursor: lifetime")

local open = support.run(pg, sql, { limit = 10 })
local cancelled = support.sync(function(done)
	gripd.request(pg, "cancel", { hash = open.hash }, function(result, err)
		done(result, err)
	end)
end)
check("cancelling by name answers that it closed something", cancelled and cancelled.cancelled, true)
local _, after_cancel = support.next_batch(pg, open.hash, 10)
check("and the result is gone", after_cancel ~= nil, true)

local _, unknown = support.next_batch(pg, "000000000000", 10)
check("a name nobody opened is refused", unknown ~= nil, true)

-- The refusal of a duplicate name must not cost the result that already holds it.
local held = support.run(pg, sql, { limit = 10 })
local _, duplicate = support.sync(function(done)
	require("neogrip.gripd.runner").run({
		connection = pg,
		sql = sql,
		mode = "query",
		limit = 10,
		hash = held.hash,
	}, function(result, err)
		done(result, err)
	end)
end)
check("a name already in use is refused", duplicate ~= nil, true)
local survivor = support.next_batch(pg, held.hash, 10)
check("and the result that holds it is untouched", survivor ~= nil and #survivor.rows, 10)

-- No cap on live results any more: nothing evicts on the client's behalf (ADR-0041).
local hashes = {}
for index = 1, 10 do
	local extra = support.run(pg, sql, { limit = 1 })
	hashes[index] = extra and extra.hash
end
local oldest, oldest_err = support.next_batch(pg, hashes[1], 1)
check("the first of ten results is still open", oldest_err, nil)
check("and still answering", oldest ~= nil and #oldest.rows, 1)
local newest = support.next_batch(pg, hashes[10], 1)
check("so is the tenth", newest ~= nil and #newest.rows, 1)

-- Closed by hand: ten cursors on an hour-long idle window would outlive the run.
local runner_module = require("neogrip.gripd.runner")
for _, hash in ipairs(hashes) do
	runner_module.release(pg, hash)
end

support.run(pg, "drop table if exists window_probe", { mode = "exec" })
