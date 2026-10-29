-- The protocol constants, mirroring doc/protocol.md. Both sides of the wire
-- read their numbers from a single place: this file in Lua, Rpc.java in Java.
local M = {}

-- Bumped only by an ADR; a major mismatch is refused at initialize.
M.VERSION = 1

M.ERRORS = {
	-- JSON-RPC standard codes.
	parse_error = -32700,
	invalid_request = -32600,
	method_not_found = -32601,

	-- Protocol codes.
	protocol_mismatch = -32002,
	sql_error = -32010,
	auth_error = -32011,
	readonly_refused = -32012,
	cancelled = -32013,

	-- Client-side synthetic codes, never sent on the wire.
	client_closed = -32098,
	process_exited = -32099,
}

return M
