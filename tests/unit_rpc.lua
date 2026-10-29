-- The rpc client against the mock sidecar: framing, correlation, errors,
-- server-initiated traffic and lifecycle. Everything here runs with no JVM and
-- no network - the mock is another headless nvim.
local support = require("tests.support")
local client = require("neogrip.rpc.client")

support.describe("rpc client")

local mock_path = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h") .. "/mock_sidecar.lua"
local mock_cmd = { vim.v.progpath, "--clean", "-l", mock_path }

local function start(handlers)
	local c = client.start(mock_cmd, handlers)
	local result, err = support.sync(function(done)
		c:request("initialize", { protocolVersion = 1, clientInfo = { name = "tests" } }, done)
	end, 20000)
	return c, result, err
end

-- Handshake.
local c, init_result, init_err = start()
support.check("initialize answers with the protocol version", init_err, nil)
support.check("initialize carries the version", init_result and init_result.protocolVersion, 1)

-- Correlation across several requests on one process.
local first = support.sync(function(done)
	c:request("echo", { n = 1 }, done)
end)
local second = support.sync(function(done)
	c:request("echo", { n = 2 }, done)
end)
support.check("responses correlate to their requests", { first.n, second.n }, { 1, 2 })

-- Error objects arrive as the err argument with data intact.
local failed_result, failed_err = support.sync(function(done)
	c:request("fail", {}, done)
end)
support.check("a failed request yields no result", failed_result, nil)
support.check(
	"the error carries code and message",
	{ failed_err.code, failed_err.message },
	{ -32010, "boom" }
)
support.check(
	"driver detail rides in error.data",
	{ failed_err.data.state, failed_err.data.vendorCode, failed_err.data.position },
	{ "42000", 7, 3 }
)

-- A notification from the process reaches the handler.
local notified = nil
local c2 = client.start(mock_cmd, {
	on_notification = function(method, params)
		notified = { method = method, message = params and params.message }
	end,
})
support.sync(function(done)
	c2:request("initialize", { protocolVersion = 1 }, done)
end, 20000)
support.sync(function(done)
	c2:request("emit_notification", {}, done)
end)
support.wait(function()
	return notified ~= nil
end, 5000)
support.check("notifications dispatch to the handler", notified, { method = "status", message = "hello" })

-- A server-initiated request gets answered through respond() and the answer
-- makes it back into the original request's response.
local c3 = client.start(mock_cmd, {
	on_request = function(method, _params, respond)
		if method == "input" then
			respond({ value = "42" })
		end
	end,
})
support.sync(function(done)
	c3:request("initialize", { protocolVersion = 1 }, done)
end, 20000)
local asked = support.sync(function(done)
	c3:request("ask", {}, done)
end)
support.check("server requests round-trip through on_request", asked and asked.received, "42")
c3:close()

-- Non-JSON lines on stdout are skipped, not fatal.
local after_garbage = support.sync(function(done)
	c2:request("garbage", {}, done)
end)
support.check("garbage lines are skipped", after_garbage ~= nil, true)

-- A payload far bigger than one pipe chunk reassembles across _consume calls.
local big = support.sync(function(done)
	c2:request("big", {}, done)
end)
support.check("a 200KB payload survives chunked reads", big and #big.blob, 200000)
c2:close()

-- A version the mock refuses: the error comes back, then the process exits.
local exit_code = nil
local c4 = client.start(mock_cmd, {
	on_exit = function(code)
		exit_code = code
	end,
})
local _, mismatch_err = support.sync(function(done)
	c4:request("initialize", { protocolVersion = 99 }, done)
end, 20000)
support.check("a version mismatch is refused with -32002", mismatch_err and mismatch_err.code, -32002)
support.wait(function()
	return exit_code ~= nil
end, 10000)
support.check("the refusing process exits", exit_code ~= nil, true)

-- Closing stdin ends the process (the EOF shutdown path) and pending requests
-- are drained with a synthetic error rather than leaking.
local c5_exit = nil
local c5 = client.start(mock_cmd, {
	on_exit = function(code)
		c5_exit = code
	end,
})
support.sync(function(done)
	c5:request("initialize", { protocolVersion = 1 }, done)
end, 20000)
c5:close()
support.wait(function()
	return c5_exit ~= nil
end, 10000)
support.check("EOF on stdin ends the process with code 0", c5_exit, 0)
local _, closed_err = support.sync(function(done)
	c5:request("ping", {}, done)
end)
support.check("requests after close fail synthetically", closed_err and closed_err.code, -32098)
c:close()
