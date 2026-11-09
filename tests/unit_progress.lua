-- What gripd says on its own: the status frame it has always sent, and the
-- progress frame protocol 5 added (ADR-0042). The point of the routing is that
-- a frame about one result reaches the request waiting on that result and no
-- other, so most of this suite is about frames that must be ignored.
local support = require("tests.support")
local check = support.check
local runner = require("neogrip.runner")
local gripd = require("neogrip.gripd")
local neogrip = require("neogrip")

local one = { id = "__progress_one__", name = "one", driver = "postgres" }
local two = { id = "__progress_two__", name = "two", driver = "duckdb" }

local saved = {
	request = gripd.request,
	is_connected = gripd.is_connected,
	is_connected_to = gripd.is_connected_to,
	notify = neogrip.notify,
}

local notices = {}
neogrip.notify = function(message)
	notices[#notices + 1] = message
end
gripd.is_connected = function()
	return true
end
gripd.is_connected_to = function()
	return true
end
-- Never calls back: every handle below has to stay live while frames arrive.
gripd.request = function()
	return 1
end

--- Start a query and collect the phases it is told about.
--- @return table handle, table phases
local function started(connection)
	local phases = {}
	local handle = runner.run({
		connection = connection,
		sql = "select 1",
		mode = "query",
		limit = 10,
		-- The watchdog would restart gripd ten seconds after a request that
		-- never answers, and every request here never answers.
		timeout_ms = 0,
		on_progress = function(event)
			phases[#phases + 1] = event.phase
		end,
	}, function() end)
	return handle, phases
end

support.describe("progress: a status frame still reaches the editor")

gripd.notification(one, "status", { phase = "transaction", message = "idle transaction rolled back" })
check(
	"the notice names the connection that said it",
	notices[#notices],
	"one: idle transaction rolled back"
)

local before = #notices
gripd.notification(one, "status", { phase = "transaction" })
check("a status frame with no message says nothing", #notices, before)

support.describe("progress: a frame finds the request waiting on that result")

local first, first_phases = started(one)
check("the request is out", first_phases[#first_phases], "sent")

gripd.notification(one, "progress", { hash = first.hash, phase = "executing" })
check("the phase arrived", first_phases[#first_phases], "executing")
check("and the handle carries it", first.phase, "executing")

local count = #first_phases
gripd.notification(one, "progress", { hash = first.hash, phase = "executing" })
check("a second frame is passed on as well, because a refill sends one", #first_phases, count + 1)

support.describe("progress: and reaches no other request")

local second, second_phases = started(two)
local second_count = #second_phases
gripd.notification(one, "progress", { hash = first.hash, phase = "executing" })
check("the other result hears nothing", #second_phases, second_count)

support.describe("progress: what is ignored")

local quiet = #first_phases
gripd.notification(one, "progress", { hash = "deadbeefcafe", phase = "executing" })
check("an unknown name is ignored", #first_phases, quiet)

-- The tree and the dialect probes open named results too, and nothing listens
-- for theirs, so a frame with no listener must not raise either.
local ok = pcall(gripd.notification, one, "progress", { phase = "executing" })
check("a frame with no name does not raise", ok, true)
check("nor does an unknown method", pcall(gripd.notification, one, "log", { message = "x" }), true)

-- A hash is minted per client, so two processes could mint the same one.
gripd.notification(two, "progress", { hash = first.hash, phase = "executing" })
check("a frame from another connection is ignored", #first_phases, quiet)

runner.cancel(first)
local after_finish = #first_phases
gripd.notification(one, "progress", { hash = first.hash, phase = "executing" })
check("a frame for a finished request is ignored", #first_phases, after_finish)

support.describe("progress: a request that dies on dispatch stays dead")

-- gripd.request answers synchronously when the process is gone, so finish runs
-- inside runner.run. Nothing may be reported after that: the caller has already
-- drawn the error.
gripd.request = function(_, _, _, callback)
	callback(nil, { message = "not connected" })
	return 1
end
local dead, dead_phases = started(one)
check("the handle is finished", dead.done, true)
check("and was never told it was sent", vim.tbl_contains(dead_phases, "sent"), false)
gripd.request = function()
	return 1
end

support.describe("progress: the phases the client knows by itself")

-- The queue serializes one request per connection, so the second one waits and
-- is owed a word about it: the window it opened cannot show a number yet.
local third, third_phases = started(two)
check("a request behind an active one says so", third_phases[1], "queued")
check("and does not claim to have been sent", third_phases[#third_phases], "queued")

runner.cancel(second)
check("which lets the queued one go out", third_phases[#third_phases], "sent")

runner.cancel(third)

gripd.request = saved.request
gripd.is_connected = saved.is_connected
gripd.is_connected_to = saved.is_connected_to
neogrip.notify = saved.notify
