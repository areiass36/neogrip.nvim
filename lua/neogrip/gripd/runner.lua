-- Queue requests per connection, apply timeouts, translate gripd's answers.
local notify = require("neogrip.notify")
local value_module = require("neogrip.codec.value")
local errors = require("neogrip.gripd.errors")
local gripd = require("neogrip.gripd")
local config = require("neogrip.config")
local secrets = require("neogrip.connections.secrets")

local M = {}

local queues = {}
local running = {}
-- Live handles by result name, so a frame gripd sends on its own can find the
-- request waiting on it (ADR-0042).
local by_hash = {}
local sequence = 0
-- Explicit-transaction state per connection, from gripd's answer to an
-- intercepted BEGIN/COMMIT/ROLLBACK (ADR-0013).
local transactions = {}

--- Mint the name a result is known by; a suite needing a predictable one replaces this function.
function M.hash()
	return (vim.uv.random(6):gsub(".", function(byte)
		return ("%02x"):format(byte:byte())
	end))
end

--- Report where a request has got to; swallowed when no caller asked.
local function phase(handle, name)
	handle.phase = name
	local sink = handle.request.on_progress
	if sink then
		sink({ phase = name, hash = handle.hash })
	end
end

local function finish(handle, result, err)
	if handle.done then
		return
	end
	handle.done = true
	running[handle.id] = nil
	-- A continuation reuses the hash, so an unguarded clear would evict a live handle.
	if handle.hash and by_hash[handle.hash] == handle then
		by_hash[handle.hash] = nil
	end
	local queue = queues[handle.connection_id]
	if queue then
		queue.active = false
		M._pump(handle.connection_id)
	end
	handle.callback(result, err)
end

--- Turn gripd's answer into what the rest of the plugin expects.
local function translate(handle, response)
	local request = handle.request

	if response.transaction ~= nil then
		transactions[request.connection.id] = response.transaction == true
	end

	-- A hash mismatch would land one result's rows in another's grid with
	-- nothing downstream able to notice, so it fails loudly here.
	if handle.hash and type(response.hash) == "string" and response.hash ~= handle.hash then
		return finish(handle, nil, {
			message = ("gripd answered for result %s, not %s"):format(response.hash, handle.hash),
		})
	end

	-- A continuation carries no columns, except a document result whose
	-- columns grow as rows are read.
	local columns, types, tables, schemas = nil, nil, nil, nil
	if type(response.columns) == "table" then
		columns, types, tables, schemas = {}, {}, {}, {}
		for index, column in ipairs(response.columns) do
			columns[index] = column.name
			types[index] = column.type
			-- Absent when the driver cannot name a source table; stays nil here.
			tables[index] = column.table
			schemas[index] = column.schema
		end
	end

	local rows = {}
	for _, source in ipairs(type(response.rows) == "table" and response.rows or {}) do
		local row = {}
		-- JSON null decodes to vim.NIL, so the source row keeps its length
		-- even with trailing nulls.
		for index = 1, (columns and #columns or #source) do
			local value = source[index]
			-- The grid wants the NULL sentinel, distinct from the empty string.
			row[index] = (value == nil or value == vim.NIL) and value_module.NULL or value
		end
		rows[#rows + 1] = row
	end

	finish(handle, {
		columns = columns,
		column_types = types,
		column_tables = tables,
		column_schemas = schemas,
		rows = rows,
		-- Absent means nothing to continue: an exec, an export, a one-batch result.
		done = response.done ~= false,
		hash = handle.hash,
		elapsed_ms = response.elapsedMs,
		update_count = response.updateCount,
		transaction = response.transaction,
		-- An export reports its row count under the same name a query uses for
		-- the rows themselves; the type tells them apart.
		rows_written = type(response.rows) == "number" and response.rows or nil,
		connection = request.connection,
		sql = request.sql,
		limit = request.limit,
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
	elseif request.mode == "next" then
		-- No sql makes this a continuation of the named result (ADR-0031).
		method = "query"
		params = { hash = handle.hash, limit = request.limit or 0 }
	else
		method = "query"
		params = {
			hash = handle.hash,
			sql = request.sql,
			limit = request.limit or 0,
			timeoutSeconds = timeout_seconds,
		}
	end

	handle.request_id = gripd.request(connection, method, params, function(result, err)
		if handle.cancelled then
			return finish(handle, nil, { message = "cancelled", cancelled = true })
		end
		if err then
			return finish(handle, nil, errors.from_rpc(err, { password = handle.password }))
		end
		translate(handle, result)
	end)
	-- gripd.request answers synchronously when the process is gone; a request
	-- that already failed must not report "sent" afterwards.
	if not handle.done then
		phase(handle, "sent")
	end

	-- The watchdog only catches a process that stopped answering, and a timeout
	-- of 0 must never arm it; see doc/internals.md#runner-and-execute.
	local timeout_ms = request.timeout_ms or config.get().timeout_ms
	if timeout_ms > 0 then
		handle.timer = vim.defer_fn(function()
			if not handle.done then
				notify.send("gripd stopped answering; restarting it", vim.log.levels.WARN)
				gripd.disconnect(connection.id)
				finish(handle, nil, { message = "timed out waiting for gripd" })
			end
		end, timeout_ms + 10000)
	end
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
	-- Said before the pump, which may dispatch this very handle and overwrite
	-- the phase with "sent".
	if queues[id].active then
		phase(handle, "queued")
	end
	M._pump(id)
end

--- @param request table { connection, sql, mode, limit, hash, timeout_ms, background, out_file, format }
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
	-- A background query is never paged; naming it would leave gripd holding a
	-- cursor nobody can ask about.
	if request.mode == "next" then
		handle.hash = request.hash
	elseif (request.mode == nil or request.mode == "query") and not request.background then
		-- Nothing in the plugin brings its own name, but the suites reuse one on purpose.
		handle.hash = request.hash or M.hash()
	end
	running[handle.id] = handle
	if handle.hash then
		by_hash[handle.hash] = handle
	end

	local connection = request.connection
	request.timeout_ms = request.timeout_ms or connection.timeout_ms or config.get().timeout_ms

	if gripd.is_connected_to(connection) then
		enqueue(handle)
		return handle
	end

	phase(handle, "connecting")
	secrets.resolve(connection, function(auth, secret_err)
		if secret_err then
			return finish(handle, nil, { message = secret_err })
		end
		-- Kept only so error messages can be scrubbed of it; never logged.
		handle.password = auth and auth.password or nil
		gripd.connect(connection, auth, function(connected, connect_err)
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

--- Route a frame gripd sent on its own to the handle waiting on it (ADR-0042).
--- An unknown name is normal (probes open named results too); the connection
--- check covers two clients minting the same hash.
function M.progress(connection, params)
	local handle = by_hash[params.hash]
	if not handle or handle.done or handle.connection_id ~= connection.id then
		return
	end
	phase(handle, params.phase)
end

--- Ask the server to stop: JDBC's Statement.cancel reaches the database, and
--- a hash also closes that result (ADR-0031).
function M.cancel(handle)
	if not handle or handle.done then
		return false
	end
	handle.cancelled = true
	local connection = handle.request.connection
	if gripd.is_connected(connection.id) then
		gripd.request(connection, "cancel", { hash = handle.hash }, function() end)
	end
	finish(handle, nil, { message = "cancelled", cancelled = true })
	return true
end

--- Release an open result, fire and forget: gripd closes an idle one anyway.
function M.release(connection, hash)
	if not hash or not gripd.is_connected(connection.id) then
		return
	end
	gripd.request(connection, "cancel", { hash = hash }, function() end)
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

--- The statusline's [TX] flag; dropped with the process, because gripd rolls
--- back on the way out (ADR-0013).
function M.in_transaction(connection_id)
	return transactions[connection_id] == true and gripd.is_connected(connection_id)
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
			gripd.disconnect_all()
		end,
	})
end

return M
