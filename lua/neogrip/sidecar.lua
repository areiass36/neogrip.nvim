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
	return vim.fn.glob(M.sources_dir .. "/**/*.java", false, true)
end

function M.compiled()
	local stamp = vim.fn.filereadable(stamp_file) == 1 and vim.fn.readfile(stamp_file)[1] or nil
	if stamp ~= tostring(protocol.VERSION) then
		return false
	end
	local main_class = vim.uv.fs_stat(M.classes_dir .. "/neogrip/app/App.class")
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
	-- -parameters keeps parameter names for the sidecar's named binding.
	local command = { javac, "-encoding", "UTF-8", "-parameters", "-d", M.classes_dir }
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
		"neogrip.app.App",
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

-- One process per configured connection (ADR-0003), keyed by id. Each entry
-- remembers the url it connected to, because the explorer can re-point a
-- connection at another database and the process must be replaced, not reused.
local processes = {}

--- JDK present, sidecar compiled, and this driver's jar installed.
--- @param on_done fun(jar: string|nil, err: string|nil)
function M.ensure_driver(driver, on_done)
	M.ensure(function(ok, err)
		if not ok then
			return on_done(nil, err)
		end
		require("neogrip.bootstrap.jdbc").ensure(driver, on_done)
	end)
end

--- @return boolean connected to this exact connection, url included
function M.is_connected_to(connection)
	local entry = processes[connection.id]
	if not entry or entry.sidecar.exited then
		return false
	end
	local url = require("neogrip.dsn").build(connection)
	return entry.url == url
end

--- Connected under this id at all; is_connected_to is the url-aware check and
--- the one a caller about to send statements must use.
function M.is_connected(id)
	local entry = processes[id]
	return entry ~= nil and not entry.sidecar.exited
end

--- Open a connection's process and connect it, replacing a process bound to a
--- different url. The auth table is the resolved one from secrets.resolve and
--- is never logged (ADR-0009).
--- @param on_done fun(ok: boolean, err: table|string|nil)
function M.connect(connection, auth, on_done)
	local dsn = require("neogrip.dsn")
	local url, url_err = dsn.build(connection)
	if not url then
		return on_done(false, url_err)
	end

	local existing = processes[connection.id]
	if existing and not existing.sidecar.exited then
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
					if method == "status" and params and params.message then
						neogrip.notify(("%s: %s"):format(connection.name, params.message))
					end
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
			}, function(result, connect_err)
				if connect_err then
					M.stop(launched)
					return on_done(false, connect_err)
				end
				processes[connection.id] = {
					sidecar = launched,
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

--- Send a request on a connection's live process.
function M.request(connection, method, params, callback)
	local entry = processes[connection.id]
	if not entry or entry.sidecar.exited then
		return callback(nil, { code = protocol.ERRORS.client_closed, message = "not connected" })
	end
	return entry.sidecar:request(method, params, callback)
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
		stderr = entry.sidecar:stderr(),
		pid = entry.sidecar.process and entry.sidecar.process.pid,
	}
end

--- @return string[] ids of the connections with a live process
function M.active()
	local ids = {}
	for id, entry in pairs(processes) do
		if not entry.sidecar.exited then
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
		M.stop(entry.sidecar)
	end
end

function M.disconnect_all()
	local ids = vim.tbl_keys(processes)
	for _, id in ipairs(ids) do
		M.disconnect(id)
	end
end

return M
