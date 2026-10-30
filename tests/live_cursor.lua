-- A result is a cursor the client names (ADR-0031), against real servers: the
-- open-continue-finish cycle on every engine, the window refill that crosses
-- two executions, and the lifetime rules that keep a forgotten result from
-- living forever.
local support = require("tests.support")
local check, note = support.check, support.note
local sidecar = require("neogrip.sidecar")

if not support.has_jdk() then
	support.describe("live/cursor")
	note("skipped: no JDK available (set NEOGRIP_TEST_JDK)")
	return
end
support.seed_secrets()

local connections = support.connections()
local order = { "postgres", "mysql", "mssql", "sqlite", "duckdb", "mongodb" }

for _, driver in ipairs(order) do
	local connection = connections[driver]
	support.describe("live/cursor/" .. driver)

	if not support.reachable(connection) then
		note("skipped: nothing listening (tests/containers.sh up)")
	else
		if driver == "duckdb" then
			-- The file has to be written by the driver that reads it, so the
			-- fixture is created here rather than by tests/containers.sh.
			support.run(
				connection,
				"create or replace table torture as select * from " .. "(values (1,'a'),(2,'b')) t(id,s)",
				{ mode = "exec" }
			)
		end

		local sql = driver == "mongodb" and "db.orders.find({})" or "select * from torture order by id"
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
				-- The shape was described when the result was opened; only a
				-- document result that grew its own columns sends it again.
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

-- More rows than one execution is allowed to hand out, with a batch smaller
-- than the window so several batches come out of each execution: 2050 rows in
-- batches of 300 crosses the 1000-row window twice. The opening execution asks
-- for the batch and one row more; the window arrives with the first
-- continuation, and the re-executions behind it are invisible from here -
-- which is the property under test (ADR-0031).
local TOTAL, PAGE = 2050, 300
support.run(pg, "drop table if exists window_probe", { mode = "exec" })
support.run(
	pg,
	("create table window_probe as select generate_series(1, %d) as n"):format(TOTAL),
	{ mode = "exec" }
)

local sql = "select n from window_probe order by n"
local batch, batch_err = support.run(pg, sql, { limit = PAGE, timeout = 90000 })
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
		-- Every batch but the last is full: a batch that straddles the window
		-- must refill mid-collection, not stop at the row the old execution
		-- had left over.
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
		local continued, err = support.next_batch(pg, batch.hash, PAGE)
		if err then
			support.fail("batch " .. (batches + 1), err.message)
			break
		end
		batch = continued
	end

	check("every row arrived exactly once, in order", ok, true)
	check("all of them", expected - 1, TOTAL)
	-- The batch sizes depend only on the page size, never on the window: that
	-- is what "the refill is invisible" means.
	check("every batch but the last was full", full, true)
	check("so the count is the page size and nothing else", batches, math.ceil(TOTAL / PAGE))
	check("and the last one carries the remainder", #batch.rows, TOTAL % PAGE)
end

support.describe("live/cursor: a continuation does not run the statement again")

-- The only way to prove it from outside is to change the table between two
-- pages: a row inserted after the result was opened cannot appear in a later
-- batch of the same cursor, and would appear if the page had re-executed with
-- a skip. This is a regression test with a measurement behind it - opening a
-- continuable result with only `limit + 1` rows made the second page drain the
-- execution and refill, which cost a 226s Trino aggregate a second full run.
support.run(pg, "drop table if exists continuity_probe", { mode = "exec" })
support.run(pg, "create table continuity_probe as select generate_series(2, 9) * 10 as n", { mode = "exec" })

local opened = support.run(pg, "select n from continuity_probe order by n", { limit = 3 })
check("the first page is the lowest three", opened.rows, { { 20 }, { 30 }, { 40 } })
support.run(pg, "insert into continuity_probe values (25)", { mode = "exec" })
local continued = support.next_batch(pg, opened.hash, 3)
check("the second page continues past them", continued.rows, { { 50 }, { 60 }, { 70 } })
-- A re-execution would have sorted 25 into third place and handed back
-- 30, 40, 50 instead.
check("and never sees the row inserted meanwhile", continued.rows[1][1] ~= 30, true)
support.run(pg, "drop table if exists continuity_probe", { mode = "exec" })

support.describe("live/cursor: lifetime")

local open = support.run(pg, sql, { limit = 10 })
local cancelled = support.sync(function(done)
	sidecar.request(pg, "cancel", { hash = open.hash }, function(result, err)
		done(result, err)
	end)
end)
check("cancelling by name answers that it closed something", cancelled and cancelled.cancelled, true)
local _, after_cancel = support.next_batch(pg, open.hash, 10)
check("and the result is gone", after_cancel ~= nil, true)

local _, unknown = support.next_batch(pg, "000000000000", 10)
check("a name nobody opened is refused", unknown ~= nil, true)

-- Opening a second result under a live name is a client bug, and the refusal
-- must not cost the result that already holds the name.
local held = support.run(pg, sql, { limit = 10 })
local _, duplicate = support.sync(function(done)
	require("neogrip.runner").run({
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

-- Four live results per connection: a fifth closes the oldest, which is the
-- only protection against a client that stops closing them.
local hashes = {}
for index = 1, 5 do
	local extra = support.run(pg, sql, { limit = 1 })
	hashes[index] = extra and extra.hash
end
local _, evicted = support.next_batch(pg, hashes[1], 1)
check("the oldest result is closed when a fifth is opened", evicted ~= nil, true)
local newest = support.next_batch(pg, hashes[5], 1)
check("and the newest is still open", newest ~= nil and #newest.rows, 1)

support.run(pg, "drop table if exists window_probe", { mode = "exec" })
