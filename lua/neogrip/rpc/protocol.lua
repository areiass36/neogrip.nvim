-- The protocol constants, mirroring doc/protocol.md. Both sides of the wire
-- read their numbers from a single place: this file in Lua, Protocol.java in
-- Java.
local M = {}

-- Bumped only by an ADR; a mismatch is refused at initialize. Version 2 made a
-- result a cursor the client names (ADR-0031); version 3 renamed the
-- handshake's sidecarInfo to gripdInfo with the program (ADR-0034); version 4
-- answers a tree the client draws (ADR-0036, ADR-0038); version 5 says when a
-- statement begins executing, so a clock can run while it does (ADR-0042).
M.VERSION = 5

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
