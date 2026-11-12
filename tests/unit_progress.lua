-- Routing of gripd's status frames and the progress frames protocol 5 added:
-- a frame about one result must reach only the request waiting on that result.
local support = require("tests.support")
local check = support.check
local runner = require("neogrip.gripd.runner")
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

local function started(connection)
	local phases = {}
	local handle = runner.run({
		connection = connection,
		sql = "select 1",
		mode = "query",
		limit = 10,
		-- Disarms the watchdog, since every request here deliberately never answers.
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

-- The tree and dialect probes open named results nothing listens for, so no listener, no raise.
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

-- The stub answers synchronously on purpose: gripd.request does so when the process is gone,
-- making finish run inside runner.run.
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
