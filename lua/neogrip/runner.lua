-- Running one statement, through the sidecar that owns the connection.
--
-- The process is started on first use and kept (lua/neogrip/sidecar.lua), so
-- this layer only has to queue requests, apply timeouts and translate the
-- answer. The heavy lifting - paging without rewriting SQL, converting types,
-- telling NULL from an empty string - is done on the Java side, where JDBC
-- reports the type of every column.
--
-- A query names its result with a hash of its own (ADR-0031), which is what
-- lets the next page be a continuation of the same cursor rather than the
-- statement run again, and what lets a cancel address one result.
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

--- The name a result is known by, minted here and never interpreted by the
--- sidecar. Random rather than sequential because it is one call either way and
--- nothing should be tempted to do arithmetic on it; a suite that needs a
--- predictable one replaces this function.
function M.hash()
	return (vim.uv.random(6):gsub(".", function(byte)
		return ("%02x"):format(byte:byte())
	end))
end

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

	-- The sidecar echoes the name of the result in every batch. A mismatch
	-- means rows of one result would land in another result's grid, which
	-- nothing downstream could notice, so it fails loudly here instead.
	if handle.hash and type(response.hash) == "string" and response.hash ~= handle.hash then
		return finish(handle, nil, {
			message = ("the sidecar answered for result %s, not %s"):format(response.hash, handle.hash),
		})
	end

	-- A continuation carries no columns: the shape was described when the
	-- result was opened. The exception is a document result, whose columns are
	-- discovered as rows are read, so a later batch may bring a longer list.
	local columns, types, tables, schemas = nil, nil, nil, nil
	if type(response.columns) == "table" then
		columns, types, tables, schemas = {}, {}, {}, {}
		for index, column in ipairs(response.columns) do
			columns[index] = column.name
			types[index] = column.type
			-- Where the column came from, when the driver will say. A column
			-- computed by an expression, or one coming out of a join of
			-- subqueries, has no table behind it: the field is then absent and
			-- stays absent here, so a caller only has to test for nil.
			tables[index] = column.table
			schemas[index] = column.schema
		end
	end

	local rows = {}
	for _, source in ipairs(type(response.rows) == "table" and response.rows or {}) do
		local row = {}
		-- JSON null decodes to vim.NIL rather than nil, so the row the sidecar
		-- sent has its own length even when its last cells are empty.
		for index = 1, (columns and #columns or #source) do
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
		-- Absent means there is nothing to continue, which is the honest answer
		-- for an exec, an export and a result that fitted in one batch.
		done = response.done ~= false,
		hash = handle.hash,
		elapsed_ms = response.elapsedMs,
		update_count = response.updateCount,
		transaction = response.transaction,
		-- An export answers with how many rows it wrote, under the same name a
		-- query uses for the rows themselves; the type tells them apart.
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
		-- No sql is what makes this a continuation of the named result rather
		-- than a new statement (ADR-0031).
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
	-- that stopped answering. A timeout of 0 means "run as long as it takes"
	-- (cancel by hand with :NGripCancel), so the watchdog does not arm either -
	-- otherwise 0 would disable the server timeout but still kill at 10s.
	local timeout_ms = request.timeout_ms or config.get().timeout_ms
	if timeout_ms > 0 then
		handle.timer = vim.defer_fn(function()
			if not handle.done then
				neogrip.notify("the sidecar stopped answering; restarting it", vim.log.levels.WARN)
				sidecar.disconnect(connection.id)
				finish(handle, nil, { message = "timed out waiting for the sidecar" })
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
	-- A query names the result it is about to open; a continuation is given the
	-- name of the result it continues. Everything else has no result to name -
	-- including a background query, which is a sample or a probe that nobody
	-- will ever page, and naming it would leave the sidecar holding a cursor
	-- for a result no one can ask about.
	if request.mode == "next" then
		handle.hash = request.hash
	elseif (request.mode == nil or request.mode == "query") and not request.background then
		-- A caller may bring its own name; nothing in the plugin does, but the
		-- suites need to be able to reuse one on purpose.
		handle.hash = request.hash or M.hash()
	end
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
--- database: JDBC's Statement.cancel sends a real cancellation request. With a
--- hash it also closes that result, which is the same intent (ADR-0031).
function M.cancel(handle)
	if not handle or handle.done then
		return false
	end
	handle.cancelled = true
	local connection = handle.request.connection
	if sidecar.is_connected(connection.id) then
		sidecar.request(connection, "cancel", { hash = handle.hash }, function() end)
	end
	finish(handle, nil, { message = "cancelled", cancelled = true })
	return true
end

--- Let go of an open result nobody is looking at any more. Fire and forget: the
--- sidecar closes it on its own once idle anyway, so a lost answer costs
--- nothing and nothing waits for this.
function M.release(connection, hash)
	if not hash or not sidecar.is_connected(connection.id) then
		return
	end
	sidecar.request(connection, "cancel", { hash = hash }, function() end)
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
