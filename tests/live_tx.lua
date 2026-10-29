-- Transactions through the interceptor (ADR-0013): BEGIN pins the session,
-- ROLLBACK undoes, COMMIT keeps, and the state is visible to the statusline.
-- DuckDB supports all of it and needs no server.
local support = require("tests.support")
local check, note = support.check, support.note

support.describe("live/tx")
if not support.has_jdk() then
	note("skipped: no JDK available (set NEOGRIP_TEST_JDK)")
	return
end
support.seed_secrets()

local duck = support.connections().duckdb
local runner = require("neogrip.runner")
require("neogrip.connections").register(duck)

support.run(duck, "create or replace table ledger(amount int)", { mode = "exec", timeout = 90000 })
support.run(duck, "insert into ledger values (10)", { mode = "exec" })

local begun = support.run(duck, "BEGIN;", { mode = "exec" })
check("BEGIN is intercepted and reports an open transaction", begun and begun.transaction, true)
check("which the runner now knows", runner.in_transaction(duck.id), true)

support.run(duck, "insert into ledger values (20)", { mode = "exec" })
local inside = support.scalar(duck, "select count(*) from ledger")
check("the session sees its own uncommitted write", inside, 2)

local rolled = support.run(duck, "rollback", { mode = "exec" })
check("ROLLBACK closes the transaction", rolled and rolled.transaction, false)
check("and the runner knows that too", runner.in_transaction(duck.id), false)
check("the write is gone", support.scalar(duck, "select count(*) from ledger"), 1)

support.run(duck, "begin transaction", { mode = "exec" })
support.run(duck, "insert into ledger values (30)", { mode = "exec" })
local committed = support.run(duck, "COMMIT;", { mode = "exec" })
check("COMMIT closes the transaction", committed and committed.transaction, false)
check("and the write stays", support.scalar(duck, "select count(*) from ledger"), 2)

-- Spellings the interceptor must leave alone.
local through = support.run(duck, "select 'begin' as word", { limit = 1 })
check("a statement that merely contains the word passes through", through.rows[1][1], "begin")

support.run(duck, "drop table ledger", { mode = "exec" })
