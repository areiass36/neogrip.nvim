-- Callers do config.get() at the point of use and never cache it, so a reload is visible everywhere.
local M = {}

M.defaults = {
	-- Rows per page; one extra row is requested to detect another page without a count(*) (ADR-0014).
	limit = 200,
	-- Cursor proximity that loads the next batch (ADR-0040); clamped to limit - 1 because a
	-- threshold as large as the batch re-arms the instant a batch lands. Zero turns it off.
	auto_load_rows = 50,
	-- Cap on the automatic path only; page_next still loads beyond it. Zero removes it.
	auto_load_max_rows = 20000,
	-- Close an open cursor idle this long (ADR-0031, ADR-0041); zero disables the sweep. It
	-- travels inside `connect`, so changing it does not reach a connection that is already open.
	cursor_idle_seconds = 3600,
	-- Statement timeout, enforced on the server; zero means none.
	timeout_ms = 30000,
	-- Display truncation only; the yanked and exported value is always the full one.
	max_column_width = 60,
	min_column_width = 3,
	-- Rows scanned when measuring column widths.
	width_sample = 1000,
	null_text = "NULL",
	-- Drawn through 'statuscolumn', so it never becomes a real column and yanking is unaffected.
	row_numbers = false,
	stripe_rows = true,
	-- How long exported CSV results survive an nvim that was killed before cleaning up.
	result_retention_days = 2,
	schema_ttl_seconds = 3600,
	-- Connections the :NGripIntrospect sweep opens for itself; one reuses the existing connection.
	introspect_parallelism = 4,
	introspect_timeout_ms = 600000,
	-- Also collect indexes and foreign keys so a definition renders without a server round trip.
	introspect_details = true,
	-- The server parses and never runs the statement, so this is safe for every statement kind.
	validate_on_save = true,
	-- Stop an idle gripd after this long; zero keeps it alive for the whole session.
	idle_timeout_seconds = 1800,
	-- Roll back - never commit - a transaction idle this long (ADR-0013); zero disables it.
	transaction_idle_seconds = 600,
}

local stored = {}
local resolved = nil

function M.setup(opts)
	stored = opts or {}
	resolved = nil
end

function M.get()
	if not resolved then
		resolved = vim.tbl_deep_extend("force", vim.deepcopy(M.defaults), stored)
	end
	return resolved
end

function M.reload()
	resolved = nil
	return M.get()
end

return M
