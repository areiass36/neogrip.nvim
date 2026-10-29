-- What :NGripDoctor shows.
--
-- The self test matters more than a version string: it runs "select 1 as a,
-- 2 as b" through the whole path - JDK, driver jar, sidecar, connection - and
-- checks the column names, so a broken link shows up on a new machine instead
-- of inside a real query.
local connections = require("neogrip.connections")
local jdbc = require("neogrip.bootstrap.jdbc")
local jdk = require("neogrip.bootstrap.jdk")
local sidecar = require("neogrip.sidecar")
local runner = require("neogrip.runner")

local M = {}

local OK = "ok "
local BAD = "!! "

--- @return string[]
function M.report()
	local lines = {}
	local function row(ok, label, detail)
		lines[#lines + 1] = ("%s %-28s %s"):format(ok and OK or BAD, label, detail or "")
	end

	local java = jdk.java()
	row(java ~= nil, "JDK (Temurin)", java or (jdk.dir .. " (downloads on first use)"))

	row(sidecar.compiled(), "sidecar", sidecar.compiled() and sidecar.classes_dir or "builds on first use")

	local drivers = jdbc.drivers()
	table.sort(drivers)
	local installed = {}
	for _, driver in ipairs(drivers) do
		if jdbc.jar(driver) then
			installed[#installed + 1] = driver
		end
	end
	row(
		#installed > 0,
		"JDBC drivers",
		#installed > 0 and table.concat(installed, ", ") or "downloaded per database on first use"
	)

	local kvstore_ok = pcall(require, "kvstore")
	row(kvstore_ok, "kvstore.nvim", kvstore_ok and "available" or "missing: it holds every secret")

	local live = sidecar.active()
	row(true, "connected now", #live > 0 and table.concat(live, ", ") or "none")

	local list = connections.all()
	row(#list > 0, "connections", ("%d configured"):format(#list))
	for _, connection in ipairs(list) do
		local jar = jdbc.jar(connection.driver)
		lines[#lines + 1] = ("     %-16s %-9s %-10s %s"):format(
			connection.id,
			connection.driver,
			jar and "driver ok" or "no driver",
			connection.file or ("%s/%s"):format(connection.host or "?", connection.database or "-")
		)
	end

	return lines
end

--- The report plus a live check against every connection. The float has no
--- keymaps (ADR-0017): close it like any window.
function M.show()
	local lines = M.report()
	table.insert(lines, 1, "neogrip")
	table.insert(lines, "")
	table.insert(lines, "Self test")

	local buf = vim.api.nvim_create_buf(false, true)
	local function paint()
		if not vim.api.nvim_buf_is_valid(buf) then
			return
		end
		vim.bo[buf].modifiable = true
		vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
		vim.bo[buf].modifiable = false
	end
	paint()
	vim.bo[buf].bufhidden = "wipe"

	local width = math.min(100, vim.o.columns - 4)
	vim.api.nvim_open_win(buf, true, {
		relative = "editor",
		row = 1,
		col = math.floor((vim.o.columns - width) / 2),
		width = width,
		height = math.min(#lines + #connections.all() + 4, vim.o.lines - 4),
		border = "rounded",
		title = " :NGripDoctor ",
		title_pos = "center",
		style = "minimal",
	})

	for _, connection in ipairs(connections.all()) do
		local index = #lines + 1
		lines[index] = ("     %-16s running..."):format(connection.id)
		paint()
		M.self_test(connection, function(ok, detail)
			lines[index] = ("%s   %-16s %s"):format(ok and OK or BAD, connection.id, detail)
			paint()
		end)
	end
end

--- @param callback fun(ok: boolean, detail: string)
function M.self_test(connection, callback)
	local sql = connection.driver == "mongodb" and "db.getCollectionNames()" or "select 1 as a, 2 as b"
	runner.run({ connection = connection, sql = sql, mode = "query", limit = 5 }, function(result, err)
		if err then
			return callback(false, tostring(err.message))
		end
		if connection.driver == "mongodb" then
			local info = sidecar.info(connection.id) or {}
			return callback(true, tostring(info.product or "connected"))
		end
		local columns = result and result.columns or {}
		if #columns ~= 2 or columns[1] ~= "a" or columns[2] ~= "b" then
			return callback(false, "unexpected shape: " .. vim.inspect(columns))
		end
		local info = sidecar.info(connection.id) or {}
		callback(true, ("%s · %d ms"):format(info.product or "ok", result.elapsed_ms or 0))
	end)
end

return M
