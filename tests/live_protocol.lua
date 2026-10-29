-- The real sidecar, no database: compile, launch, shake hands, and walk the
-- contract's edges. Needs a JDK (NEOGRIP_TEST_JDK in CI, the plugin's own
-- download locally); skips - never fails - without one.
local support = require("tests.support")
local jdk = require("neogrip.bootstrap.jdk")
local sidecar = require("neogrip.sidecar")
local client = require("neogrip.rpc.client")
local protocol = require("neogrip.rpc.protocol")

support.describe("sidecar protocol (live)")

if not jdk.javac() then
	support.note("skipped: no JDK available (set NEOGRIP_TEST_JDK or let the plugin download one)")
	return
end

local built, build_err = support.sync(function(done)
	sidecar.ensure(done)
end, 120000)
support.check("the sidecar compiles", { built, build_err }, { true })
if not built then
	return
end

local launched, launch_err, init_result = support.sync(function(done)
	sidecar.launch({}, done)
end, 60000)
support.check("launch reports no error", launch_err, nil)
support.check(
	"the handshake carries the protocol version",
	init_result and init_result.protocolVersion,
	protocol.VERSION
)
support.check(
	"the handshake names the java runtime",
	type(init_result and init_result.sidecarInfo.java),
	"string"
)

local ping = support.sync(function(done)
	launched:request("ping", {}, done)
end)
support.check("ping answers", ping ~= nil, true)

local _, unknown = support.sync(function(done)
	launched:request("bogus", {}, done)
end)
support.check("an unknown method is -32601", unknown and unknown.code, protocol.ERRORS.method_not_found)

local idle_cancel = support.sync(function(done)
	launched:request("cancel", {}, done)
end)
support.check("cancel with nothing running reports false", idle_cancel, { cancelled = false })

local exit_code = nil
launched.handlers.on_exit = function(code)
	exit_code = code
end
sidecar.stop(launched)
support.wait(function()
	return exit_code ~= nil
end, 10000)
support.check("shutdown plus EOF ends the process cleanly", exit_code, 0)

-- A fresh process refuses work before the handshake.
local raw = client.start({
	jdk.java(),
	"-cp",
	sidecar.classes_dir,
	"neogrip.Main",
})
local _, early = support.sync(function(done)
	raw:request("ping", {}, done)
end, 30000)
support.check(
	"a request before initialize is refused",
	early and early.code,
	protocol.ERRORS.protocol_mismatch
)
raw:close()
