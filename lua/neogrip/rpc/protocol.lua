-- The protocol constants, mirroring doc/protocol.md; the Java side reads the same numbers
-- from Protocol.java.
local M = {}

-- Bumped only by an ADR; a mismatch is refused at initialize (history: ADR-0031, ADR-0034,
-- ADR-0036, ADR-0038, ADR-0042).
M.VERSION = 5

M.ERRORS = {
	parse_error = -32700,
	invalid_request = -32600,
	method_not_found = -32601,

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
