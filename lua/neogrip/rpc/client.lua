-- The JSON-RPC client: spawns a process, frames one JSON object per line over
-- its stdio, correlates responses to callbacks, and dispatches the messages
-- the process starts on its own (ADR-0002).
--
-- This module is deliberately ignorant of databases. It never logs a frame:
-- the connect request carries secrets (ADR-0009), and the cheapest way to
-- never log those is to never log any payload at all.
local protocol = require("neogrip.rpc.protocol")

local M = {}

local Client = {}
Client.__index = Client

local function decoded(line)
	local ok, message = pcall(vim.json.decode, line)
	if ok and type(message) == "table" then
		return message
	end
	return nil
end

function Client:_dispatch(message)
	if message.method ~= nil and message.id ~= nil then
		-- A request from the process. respond() may be called later and from
		-- any callback; it carries the id so late answers still correlate.
		local respond = function(result, err)
			if err then
				self:_write({ jsonrpc = "2.0", id = message.id, error = err })
			else
				self:_write({ jsonrpc = "2.0", id = message.id, result = result or vim.empty_dict() })
			end
		end
		if self.handlers.on_request then
			self.handlers.on_request(message.method, message.params, respond)
		else
			respond(nil, { code = protocol.ERRORS.method_not_found, message = "unhandled request" })
		end
		return
	end

	if message.method ~= nil then
		if self.handlers.on_notification then
			self.handlers.on_notification(message.method, message.params)
		end
		return
	end

	if message.id ~= nil then
		local callback = self.pending[message.id]
		if callback then
			self.pending[message.id] = nil
			if message.error ~= nil and message.error ~= vim.NIL then
				callback(nil, message.error)
			else
				callback(message.result, nil)
			end
		end
	end
end

function Client:_consume(data)
	self.buffer = self.buffer .. data
	while true do
		local newline = self.buffer:find("\n", 1, true)
		if not newline then
			return
		end
		local line = self.buffer:sub(1, newline - 1):gsub("\r$", "")
		self.buffer = self.buffer:sub(newline + 1)
		-- Anything that is not a JSON object is a driver banner on the wrong
		-- stream; the protocol says skip it rather than die on it.
		local message = decoded(line)
		if message then
			self:_dispatch(message)
		end
	end
end

function Client:_fail_all(err)
	-- Copy the keys rather than iterating pending directly: a callback may
	-- issue a new request while we drain.
	local ids = vim.tbl_keys(self.pending)
	for _, id in ipairs(ids) do
		local callback = self.pending[id]
		self.pending[id] = nil
		callback(nil, err)
	end
end

function Client:_on_exit(code)
	self.exited = true
	self:_fail_all({
		code = protocol.ERRORS.process_exited,
		message = ("process exited with code %d"):format(code),
	})
	if self.handlers.on_exit then
		self.handlers.on_exit(code)
	end
end

function Client:_write(frame)
	local ok = pcall(function()
		self.process:write(vim.json.encode(frame) .. "\n")
	end)
	return ok
end

--- Send a request. callback(result, err) runs exactly once, on the main loop;
--- err is a JSON-RPC error object, synthetic when the process is gone.
function Client:request(method, params, callback)
	if self.closed or self.exited then
		vim.schedule(function()
			callback(nil, { code = protocol.ERRORS.client_closed, message = "client is closed" })
		end)
		return nil
	end
	self.sequence = self.sequence + 1
	local id = self.sequence
	self.pending[id] = callback
	self:_write({ jsonrpc = "2.0", id = id, method = method, params = params })
	return id
end

function Client:notify(method, params)
	if self.closed or self.exited then
		return
	end
	self:_write({ jsonrpc = "2.0", method = method, params = params })
end

--- Close the process's stdin. EOF is the shutdown signal (ADR-0003); callers
--- that need a backstop kill arrange it themselves.
function Client:close()
	if self.closed then
		return
	end
	self.closed = true
	pcall(function()
		self.process:write(nil)
	end)
end

function Client:kill(signal)
	pcall(function()
		self.process:kill(signal or "sigterm")
	end)
end

function Client:stderr()
	return self.stderr_tail or ""
end

--- Spawn cmd and speak the protocol to it. handlers: on_notification(method,
--- params), on_request(method, params, respond), on_exit(code) - all optional,
--- all called on the main loop.
function M.start(cmd, handlers)
	local client = setmetatable({
		sequence = 0,
		pending = {},
		handlers = handlers or {},
		buffer = "",
		closed = false,
		exited = false,
	}, Client)

	client.process = vim.system(cmd, {
		stdin = true,
		text = false,
		stdout = function(_, data)
			if data then
				vim.schedule(function()
					client:_consume(data)
				end)
			end
		end,
		stderr = function(_, data)
			if data then
				-- Kept only as a rolling tail for the doctor; never parsed.
				client.stderr_tail = ((client.stderr_tail or "") .. data):sub(-4000)
			end
		end,
	}, function(result)
		vim.schedule(function()
			client:_on_exit(result.code)
		end)
	end)

	return client
end

return M
