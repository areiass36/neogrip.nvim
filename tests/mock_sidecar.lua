-- A fake sidecar speaking the wire protocol, run as:
--   nvim --clean -l tests/mock_sidecar.lua
-- It implements just enough of doc/protocol.md for the rpc client's unit
-- suite: handshake, correlation, errors, server-initiated traffic, garbage on
-- stdout and a payload big enough to split across pipe chunks.
local function send(object)
	io.stdout:write(vim.json.encode(object) .. "\n")
	io.stdout:flush()
end

local function respond(id, result)
	send({ jsonrpc = "2.0", id = id, result = result })
end

local function respond_error(id, code, message, data)
	send({ jsonrpc = "2.0", id = id, error = { code = code, message = message, data = data } })
end

-- Kept in step with lua/neogrip/rpc/protocol.lua by hand: this script runs
-- under nvim --clean, with the plugin nowhere on its path.
local VERSION = 2
local initialized = false

for line in io.lines() do
	local ok, message = pcall(vim.json.decode, line)
	if ok and type(message) == "table" and message.method then
		local method = message.method
		local params = message.params or {}
		local id = message.id

		if method == "shutdown" then
			break
		elseif method == "initialize" then
			if params.protocolVersion ~= VERSION then
				respond_error(id, -32002, "protocol version mismatch")
				break
			end
			initialized = true
			respond(id, { protocolVersion = VERSION, sidecarInfo = { name = "mock" } })
		elseif not initialized then
			respond_error(id, -32002, "initialize first")
		elseif method == "ping" then
			respond(id, vim.empty_dict())
		elseif method == "echo" then
			respond(id, params)
		elseif method == "fail" then
			respond_error(id, -32010, "boom", { state = "42000", vendorCode = 7, position = 3 })
		elseif method == "emit_notification" then
			send({ jsonrpc = "2.0", method = "status", params = { message = "hello" } })
			respond(id, vim.empty_dict())
		elseif method == "ask" then
			-- A server-initiated request: ask the client for a value, wait for
			-- its answer, then fold it into the original response.
			send({ jsonrpc = "2.0", id = "sv-1", method = "input", params = { prompt = "value?" } })
			local answer = nil
			for reply_line in io.lines() do
				local reply_ok, reply = pcall(vim.json.decode, reply_line)
				if reply_ok and type(reply) == "table" and reply.id == "sv-1" then
					answer = reply.result
					break
				end
			end
			respond(id, { received = answer and answer.value or vim.NIL })
		elseif method == "garbage" then
			io.stdout:write("WARNING: a driver banner that is not JSON\n")
			io.stdout:flush()
			respond(id, vim.empty_dict())
		elseif method == "big" then
			respond(id, { blob = string.rep("x", 200000) })
		elseif id ~= nil then
			respond_error(id, -32601, "method not found: " .. tostring(method))
		end
	end
end

os.exit(0)
