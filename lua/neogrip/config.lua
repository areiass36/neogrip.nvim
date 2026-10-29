-- The options table: defaults merged once under whatever setup(opts) brought.
-- Callers do config.get() at the point of use and never cache the result, so
-- a reload is visible everywhere immediately.
local M = {}

M.defaults = {
	-- Rows fetched per page. One extra row is always requested to learn whether
	-- another page exists without paying for a count(*) (ADR-0014).
	limit = 200,
	timeout_ms = 30000,
	-- Columns wider than this are truncated with an ellipsis in the grid; the
	-- yanked and exported value is always the untruncated one.
	max_column_width = 60,
	min_column_width = 3,
	-- Rows scanned when measuring column widths.
	width_sample = 1000,
	null_text = "NULL",
	-- Tint every other row of the result, in whatever colour the colourscheme
	-- uses for the cursor line. It is what keeps the eye on one row across a
	-- wide table; off, the grid is drawn on the plain background.
	stripe_rows = true,
	-- Results materialised as CSV are kept this many days, for the case where
	-- nvim was killed before it could clean up after itself.
	result_retention_days = 2,
	-- Catalog queries are cached per connection for this long.
	schema_ttl_seconds = 3600,
	-- :NGripIntrospect sweeps the whole connected database and keeps it under
	-- the state directory, where it answers for every level of the explorer
	-- and every table preview until it is asked for again. The sweep runs on
	-- connections of its own so the editor is never queued behind it; this is
	-- how many of them at most. One keeps it on the single connection the
	-- process already has, which is what a file-backed driver gets anyway.
	introspect_parallelism = 4,
	introspect_timeout_ms = 600000,
	-- Collect each table's indexes and foreign keys as well, which is what
	-- lets a table's definition be previewed without asking the server. Off,
	-- the sweep is a good deal cheaper and a definition costs one round trip.
	introspect_details = true,
	-- Sweep once, in the background, the first time the explorer is opened on
	-- a database that has never been swept. Nothing waits for it.
	introspect_on_first_use = true,
	-- Resting on a schema in the explorer fills its cache in the background,
	-- so walking into it is instant. One round trip per schema, debounced.
	schema_warm = true,
	schema_warm_debounce_ms = 250,
	-- Show a few rows beside a table in the explorer's preview. Off: the
	-- preview is metadata only, which costs nothing once the schema is cached.
	preview_sample = false,
	-- Validate the statement under the cursor on save. The server parses it
	-- and never runs it, so this is safe for every kind of statement.
	validate_on_save = true,
	-- Stop a connection's sidecar after this long with nothing to do. Zero
	-- keeps it alive for the whole session.
	idle_timeout_seconds = 1800,
	-- Roll back - never commit - a transaction that has seen no statement for
	-- this long, because an idle open transaction holds locks (ADR-0013).
	-- Zero disables the watchdog.
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
