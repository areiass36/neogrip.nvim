-- The lifecycle of gripd, the Java daemon. The argv built here never carries
-- connection parameters or secrets.
local jdk = require("neogrip.gripd.bootstrap.jdk")
local platform = require("neogrip.gripd.bootstrap.platform")
local client = require("neogrip.gripd.client")
local protocol = require("neogrip.gripd.protocol")
local notify = require("neogrip.notify")
local paths = require("neogrip.paths")

local M = {}

-- This file's own path locates the shipped sources; a plugin cannot know
-- where a manager cloned it.
local plugin_root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h:h")
M.sources_dir = plugin_root .. "/java"
M.classes_dir = paths.data_dir .. "/classes"

-- The classes are stamped with the protocol version, so a contract bump
-- recompiles instead of mismatching at runtime.
local stamp_file = M.classes_dir .. "/.protocol-version"

local function sources()
	return vim.fn.glob(M.sources_dir .. "/**/*.java", false, true)
end

function M.compiled()
	local stamp = vim.fn.filereadable(stamp_file) == 1 and vim.fn.readfile(stamp_file)[1] or nil
	if stamp ~= tostring(protocol.VERSION) then
		return false
	end
	local main_class = vim.uv.fs_stat(M.classes_dir .. "/neogrip/gripd/Daemon.class")
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
		return on_done(false, "no gripd sources found under " .. M.sources_dir)
	end

	-- Sweep stale class trees, best-effort; see doc/internals.md#gripd-process.
	for _, stale in ipairs({ "neogrip/app", "neogrip/db", "neogrip/rpc" }) do
		pcall(vim.fn.delete, M.classes_dir .. "/" .. stale, "rf")
	end

	vim.fn.mkdir(M.classes_dir, "p")
	-- -parameters keeps parameter names for gripd's named binding (ADR-0027).
	-- --release pins the class file version to the pinned JDK (ADR-0005); see
	-- doc/internals.md#gripd-process.
	local command = {
		javac,
		"--release",
		tostring(jdk.LANGUAGE_LEVEL),
		"-encoding",
		"UTF-8",
		"-parameters",
		"-d",
		M.classes_dir,
	}
	vim.list_extend(command, files)
	vim.system(
		command,
		{ text = true },
		vim.schedule_wrap(function(result)
			if result.code ~= 0 then
				return on_done(false, "gripd compilation failed: " .. (result.stderr or ""))
			end
			pcall(vim.fn.writefile, { tostring(protocol.VERSION) }, stamp_file)
			on_done(true, nil)
		end)
	)
end

--- JDK present and gripd compiled, downloading and building as needed.
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

--- Spawn gripd and complete the handshake; opts.jar puts one driver alone on
--- the classpath (ADR-0003).
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
	-- Flags chosen for startup over throughput: this JVM lives beside an editor.
	local command = {
		java,
		"-XX:TieredStopAtLevel=1",
		"-XX:+UseSerialGC",
		"-Xss4m",
		"-Dfile.encoding=UTF-8",
		-- The Mongo wrapper's comparator trips TimSort; see doc/internals.md#gripd-process.
		"-Djava.util.Arrays.useLegacyMergeSort=true",
		"-cp",
		classpath,
		"neogrip.gripd.Daemon",
	}

	local gripd = client.start(command, opts.handlers)
	gripd:request("initialize", {
		protocolVersion = protocol.VERSION,
		clientInfo = { name = "neogrip.nvim" },
	}, function(result, err)
		if err then
			gripd:kill()
			local reason = err.message or "initialize failed"
			return on_ready(nil, reason)
		end
		on_ready(gripd, nil, result)
	end)
end

--- The shutdown contract: notify, close stdin, SIGTERM backstop after 500 ms.
function M.stop(gripd)
	if not gripd then
		return
	end
	gripd:notify("shutdown")
	gripd:close()
	vim.defer_fn(function()
		if not gripd.exited then
			gripd:kill()
		end
	end, 500)
end

-- One process per connection (ADR-0003), keyed by id; the url is remembered
-- because a re-pointed connection must replace the process, not reuse it.
local processes = {}

--- JDK present, gripd compiled, and this driver's jar installed.
--- @param on_done fun(jar: string|nil, err: string|nil)
function M.ensure_driver(driver, on_done)
	M.ensure(function(ok, err)
		if not ok then
			return on_done(nil, err)
		end
		require("neogrip.gripd.bootstrap.jdbc").ensure(driver, on_done)
	end)
end

--- @return boolean connected to this exact connection, url included
function M.is_connected_to(connection)
	local entry = processes[connection.id]
	if not entry or entry.gripd.exited then
		return false
	end
	local url = require("neogrip.gripd.dsn").build(connection)
	return entry.url == url
end

--- Connected under this id at all; is_connected_to is the url-aware check.
function M.is_connected(id)
	local entry = processes[id]
	return entry ~= nil and not entry.gripd.exited
end

--- Open a connection's process and connect it, replacing a process bound to a
--- different url; the resolved auth table is never logged (ADR-0009).
--- @param on_done fun(ok: boolean, err: table|string|nil)
function M.connect(connection, auth, on_done)
	local dsn = require("neogrip.gripd.dsn")
	local url, url_err = dsn.build(connection)
	if not url then
		return on_done(false, url_err)
	end

	local existing = processes[connection.id]
	if existing and not existing.gripd.exited then
		if existing.url == url then
			return on_done(true, nil)
		end
		M.disconnect(connection.id)
	end

	M.ensure_driver(connection.driver, function(jar, err)
		if not jar then
			return on_done(false, err)
		end
		M.launch({
			jar = jar,
			handlers = {
				on_notification = function(method, params)
					M.notification(connection, method, params)
				end,
				on_exit = function()
					processes[connection.id] = nil
				end,
			},
		}, function(launched, launch_err)
			if not launched then
				return on_done(false, launch_err)
			end
			launched:request("connect", {
				url = url,
				properties = dsn.properties(connection),
				auth = auth,
				readonly = connection.readonly or false,
				transactionIdleSeconds = require("neogrip.config").get().transaction_idle_seconds,
				cursorIdleSeconds = require("neogrip.config").get().cursor_idle_seconds,
			}, function(result, connect_err)
				if connect_err then
					M.stop(launched)
					return on_done(false, connect_err)
				end
				processes[connection.id] = {
					gripd = launched,
					url = url,
					product = result.product,
					driver = result.driver,
					capabilities = result.capabilities or {},
				}
				on_done(true, nil)
			end)
		end)
	end)
end

--- What gripd says on its own, rather than as an answer to a request; named so
--- a suite can deliver one without a live process (ADR-0023).
function M.notification(connection, method, params)
	if method == "status" and params and params.message then
		return notify.send(("%s: %s"):format(connection.name, params.message))
	end
	if method == "progress" and params and params.hash then
		-- Required here rather than at the top: the runner requires this module.
		return require("neogrip.gripd.runner").progress(connection, params)
	end
end

--- Send a request on a connection's live process.
function M.request(connection, method, params, callback)
	local entry = processes[connection.id]
	if not entry or entry.gripd.exited then
		return callback(nil, { code = protocol.ERRORS.client_closed, message = "not connected" })
	end
	return entry.gripd:request(method, params, callback)
end

--- What :NGripDoctor shows about a live connection.
function M.info(id)
	local entry = processes[id]
	if not entry then
		return nil
	end
	return {
		product = entry.product,
		driver = entry.driver,
		capabilities = entry.capabilities,
		stderr = entry.gripd:stderr(),
		pid = entry.gripd.process and entry.gripd.process.pid,
	}
end

--- @return string[] ids of the connections with a live process
function M.active()
	local ids = {}
	for id, entry in pairs(processes) do
		if not entry.gripd.exited then
			ids[#ids + 1] = id
		end
	end
	table.sort(ids)
	return ids
end

function M.disconnect(id)
	local entry = processes[id]
	processes[id] = nil
	if entry then
		M.stop(entry.gripd)
	end
end

function M.disconnect_all()
	local ids = vim.tbl_keys(processes)
	for _, id in ipairs(ids) do
		M.disconnect(id)
	end
end

return M
