-- Running one statement, through the sidecar that owns the connection.
--
-- The process is started on first use and kept (lua/neogrip/sidecar.lua), so
-- this layer only has to queue requests, apply timeouts and translate the
-- answer. The heavy lifting - paging without rewriting SQL, converting types,
-- telling NULL from an empty string - is done on the Java side, where JDBC
-- reports the type of every column.
local neogrip = require("neogrip")
local errors = require("neogrip.errors")
local sidecar = require("neogrip.sidecar")
local config = require("neogrip.config")
local secrets = require("neogrip.secrets")

local M = {}

local queues = {}
local running = {}
local sequence = 0
-- Whether a connection's session has an explicit transaction open, from the
-- sidecar's own answer to an intercepted BEGIN/COMMIT/ROLLBACK (ADR-0013).
local transactions = {}

local function finish(handle, result, err)
	if handle.done then
		return
	end
	handle.done = true
	running[handle.id] = nil
	local queue = queues[handle.connection_id]
	if queue then
		queue.active = false
		M._pump(handle.connection_id)
	end
	handle.callback(result, err)
end

--- Turn the sidecar's answer into what the rest of the plugin expects.
local function translate(handle, response)
	local request = handle.request

	if response.transaction ~= nil then
		transactions[request.connection.id] = response.transaction == true
	end

	local columns, types, tables, schemas = {}, {}, {}, {}
	for index, column in ipairs(response.columns or {}) do
		columns[index] = column.name
		types[index] = column.type
		-- Where the column came from, when the driver will say. A column
		-- computed by an expression, or one coming out of a join of
		-- subqueries, has no table behind it: the field is then absent and
		-- stays absent here, so a caller only has to test for nil.
		tables[index] = column.table
		schemas[index] = column.schema
	end

	local rows = {}
	for _, source in ipairs(type(response.rows) == "table" and response.rows or {}) do
		local row = {}
		for index = 1, #columns do
			local value = source[index]
			-- vim.json.decode turns JSON null into vim.NIL; the grid wants the
			-- sentinel, which is distinct from the empty string.
			row[index] = (value == nil or value == vim.NIL) and neogrip.NULL or value
		end
		rows[#rows + 1] = row
	end

	finish(handle, {
		columns = columns,
		column_types = types,
		column_tables = tables,
		column_schemas = schemas,
		rows = rows,
		has_more = response.hasMore == true,
		elapsed_ms = response.elapsedMs,
		update_count = response.updateCount,
		transaction = response.transaction,
		-- An export answers with how many rows it wrote, under the same name a
		-- query uses for the rows themselves; the type tells them apart.
		rows_written = type(response.rows) == "number" and response.rows or nil,
		connection = request.connection,
		sql = request.sql,
		limit = request.limit,
		offset = request.offset or 0,
	}, nil)
end

local function dispatch(handle)
	local request = handle.request
	local connection = request.connection
	local timeout_seconds = math.ceil((request.timeout_ms or config.get().timeout_ms) / 1000)

	local method, params
	if request.mode == "validate" then
		method, params = "validate", { sql = request.sql }
	elseif request.mode == "exec" then
		method, params = "exec", { sql = request.sql, timeoutSeconds = timeout_seconds }
	elseif request.mode == "export" then
		method = "export"
		params = {
			sql = request.sql,
			path = request.out_file,
			format = request.format or "csv",
			nullMarker = request.null_marker or "",
			timeoutSeconds = timeout_seconds,
		}
	else
		method = "query"
		params = {
			sql = request.sql,
			limit = request.limit or 0,
			offset = request.offset or 0,
			timeoutSeconds = timeout_seconds,
		}
	end

	handle.request_id = sidecar.request(connection, method, params, function(result, err)
		if handle.cancelled then
			return finish(handle, nil, { message = "cancelled", cancelled = true })
		end
		if err then
			return finish(handle, nil, errors.from_rpc(err, { password = handle.password }))
		end
		translate(handle, result)
	end)

	-- The server-side timeout is the real one; this only catches a process
	-- that stopped answering.
	handle.timer = vim.defer_fn(function()
		if not handle.done then
			neogrip.notify("the sidecar stopped answering; restarting it", vim.log.levels.WARN)
			sidecar.disconnect(connection.id)
			finish(handle, nil, { message = "timed out waiting for the sidecar" })
		end
	end, (request.timeout_ms or config.get().timeout_ms) + 10000)
end

function M._pump(connection_id)
	local queue = queues[connection_id]
	if not queue or queue.active then
		return
	end
	local handle = table.remove(queue.waiting, 1)
	if not handle then
		return
	end
	queue.active = true
	dispatch(handle)
end

local function enqueue(handle)
	local id = handle.connection_id
	queues[id] = queues[id] or { waiting = {}, active = false }
	-- A catalog lookup waits behind the user's own query.
	if handle.request.background then
		table.insert(queues[id].waiting, handle)
	else
		local index = 1
		for position, waiting in ipairs(queues[id].waiting) do
			if waiting.request.background then
				break
			end
			index = position + 1
		end
		table.insert(queues[id].waiting, index, handle)
	end
	M._pump(id)
end

--- @param request table { connection, sql, mode, limit, offset, timeout_ms, background, out_file, format }
--- @param callback fun(result: table|nil, err: table|nil)
--- @return table handle
function M.run(request, callback)
	sequence = sequence + 1
	local handle = {
		id = sequence,
		connection_id = request.connection.id,
		request = request,
		callback = callback,
	}
	running[handle.id] = handle

	local connection = request.connection
	request.timeout_ms = request.timeout_ms or connection.timeout_ms or config.get().timeout_ms

	if sidecar.is_connected_to(connection) then
		enqueue(handle)
		return handle
	end

	secrets.resolve(connection, function(auth, secret_err)
		if secret_err then
			return finish(handle, nil, { message = secret_err })
		end
		-- Kept only so error messages can be scrubbed of it; never logged.
		handle.password = auth and auth.password or nil
		sidecar.connect(connection, auth, function(connected, connect_err)
			if not connected then
				local err = type(connect_err) == "table"
						and errors.from_rpc(connect_err, { password = handle.password })
					or errors.from_message(connect_err, { password = handle.password })
				return finish(handle, nil, err)
			end
			enqueue(handle)
		end)
	end)

	return handle
end

--- Ask the server to stop. Unlike killing a client process, this reaches the
--- database: JDBC's Statement.cancel sends a real cancellation request.
function M.cancel(handle)
	if not handle or handle.done then
		return false
	end
	handle.cancelled = true
	local connection = handle.request.connection
	if sidecar.is_connected(connection.id) then
		sidecar.request(connection, "cancel", {}, function() end)
	end
	finish(handle, nil, { message = "cancelled", cancelled = true })
	return true
end

function M.cancel_all()
	-- Copy the keys rather than the table: a handle holds a timer.
	local ids = vim.tbl_keys(running)
	for _, id in ipairs(ids) do
		local handle = running[id]
		if handle then
			M.cancel(handle)
		end
	end
end

--- The statusline's [TX] flag: an explicit transaction is open on this
--- connection's session. Dropped with the process, because the sidecar rolls
--- back on the way out (ADR-0013).
function M.in_transaction(connection_id)
	return transactions[connection_id] == true and sidecar.is_connected(connection_id)
end

--- @return table[] handles running or queued
function M.active()
	local list = {}
	for _, handle in pairs(running) do
		list[#list + 1] = handle
	end
	return list
end

function M.setup()
	vim.api.nvim_create_autocmd("VimLeavePre", {
		group = vim.api.nvim_create_augroup("NeogripRunner", { clear = true }),
		callback = function()
			M.cancel_all()
			sidecar.disconnect_all()
		end,
	})
end

return M
