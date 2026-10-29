-- The Java sidecar's lifecycle: compile it on first use, launch it, shake
-- hands, and stop it by closing its stdin (ADR-0003, ADR-0004).
--
-- The argv never carries anything database-related; connection parameters and
-- secrets travel in the connect request (ADR-0009).
local jdk = require("neogrip.bootstrap.jdk")
local platform = require("neogrip.bootstrap.platform")
local client = require("neogrip.rpc.client")
local protocol = require("neogrip.rpc.protocol")
local neogrip = require("neogrip")

local M = {}

-- The sources ship with the plugin; this file's own path is what locates them,
-- because a plugin cannot know where a manager cloned it.
local plugin_root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h:h")
M.sources_dir = plugin_root .. "/java/neogrip"
M.classes_dir = neogrip.data_dir .. "/classes"

-- The compiled classes are stamped with the protocol version, so a plugin
-- update that bumps the contract triggers a recompile instead of a runtime
-- version mismatch.
local stamp_file = M.classes_dir .. "/.protocol-version"

local function sources()
	return vim.fn.glob(M.sources_dir .. "/*.java", false, true)
end

function M.compiled()
	local stamp = vim.fn.filereadable(stamp_file) == 1 and vim.fn.readfile(stamp_file)[1] or nil
	if stamp ~= tostring(protocol.VERSION) then
		return false
	end
	local main_class = vim.uv.fs_stat(M.classes_dir .. "/neogrip/Main.class")
	if not main_class then
		return false
	end
	for _, source in ipairs(sources()) do
		local stat = vim.uv.fs_stat(source)
		if stat and stat.mtime.sec > main_class.mtime.sec then
			return false
		end
	end
	return true
end

--- @param on_done fun(ok: boolean, err: string|nil)
function M.build(on_done)
	local javac = jdk.javac()
	if not javac then
		return on_done(false, "no javac; the JDK download must have failed")
	end
	local files = sources()
	if #files == 0 then
		return on_done(false, "no sidecar sources found under " .. M.sources_dir)
	end

	vim.fn.mkdir(M.classes_dir, "p")
	local command = { javac, "-encoding", "UTF-8", "-d", M.classes_dir }
	vim.list_extend(command, files)
	vim.system(
		command,
		{ text = true },
		vim.schedule_wrap(function(result)
			if result.code ~= 0 then
				return on_done(false, "sidecar compilation failed: " .. (result.stderr or ""))
			end
			pcall(vim.fn.writefile, { tostring(protocol.VERSION) }, stamp_file)
			on_done(true, nil)
		end)
	)
end

--- JDK present and sidecar compiled, downloading and building as needed.
--- @param on_done fun(ok: boolean, err: string|nil)
function M.ensure(on_done)
	jdk.ensure(function(jdk_ok)
		if not jdk_ok then
			return on_done(false, "no JDK available")
		end
		if M.compiled() then
			return on_done(true, nil)
		end
		M.build(on_done)
	end)
end

--- Spawn a sidecar and complete the handshake. opts.jar puts one driver on
--- the classpath (ADR-0003: each driver loads alone); opts.handlers goes to
--- the rpc client. on_ready(sidecar, err) gets the live client or a message.
function M.launch(opts, on_ready)
	opts = opts or {}
	local java = jdk.java()
	if not java then
		return on_ready(nil, "no java; the JDK download must have failed")
	end

	local classpath = M.classes_dir
	if opts.jar then
		classpath = classpath .. platform.path_separator .. opts.jar
	end
	-- Flags chosen for startup over throughput: this JVM lives beside an
	-- editor, not in a datacentre.
	local command = {
		java,
		"-XX:TieredStopAtLevel=1",
		"-XX:+UseSerialGC",
		"-Xss4m",
		"-Dfile.encoding=UTF-8",
		"-cp",
		classpath,
		"neogrip.Main",
	}

	local sidecar = client.start(command, opts.handlers)
	sidecar:request("initialize", {
		protocolVersion = protocol.VERSION,
		clientInfo = { name = "neogrip.nvim" },
	}, function(result, err)
		if err then
			sidecar:kill()
			local reason = err.message or "initialize failed"
			return on_ready(nil, reason)
		end
		on_ready(sidecar, nil, result)
	end)
end

--- The shutdown contract: notify, close stdin, and give the process 500 ms
--- before the SIGTERM backstop.
function M.stop(sidecar)
	if not sidecar then
		return
	end
	sidecar:notify("shutdown")
	sidecar:close()
	vim.defer_fn(function()
		if not sidecar.exited then
			sidecar:kill()
		end
	end, 500)
end

return M
