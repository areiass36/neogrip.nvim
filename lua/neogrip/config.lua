-- The options table: defaults merged once under whatever setup(opts) brought.
-- Callers do config.get() at the point of use and never cache the result, so
-- a reload is visible everywhere immediately.
local M = {}

M.defaults = {
	-- Rows fetched per page. One extra row is always requested to learn whether
	-- another page exists without paying for a count(*) (ADR-0014).
	limit = 200,
	-- Load the next batch once the cursor comes within this many rows of the
	-- last one loaded, so reading to the bottom of a result keeps going instead
	-- of stopping at a batch boundary (ADR-0040). The rows accumulate: the grid
	-- holds row one through row N. Held below `limit` on purpose - a threshold
	-- as large as the batch re-arms the instant a batch lands, so a larger value
	-- is clamped to limit - 1, which bounds it to one batch of lookahead. Zero
	-- turns it off, and page_next is then the only way forward.
	auto_load_rows = 50,
	-- Stop loading automatically once this many rows have accumulated. Every
	-- batch re-measures the widths and writes the lines it added, so the cost is
	-- flat per batch but the memory is not; past some point the rows cost more
	-- than they are worth. page_next still loads beyond it - the cap is on the
	-- automatic path, not on the result. Zero removes it.
	auto_load_max_rows = 20000,
	-- An open result is a cursor on gripd (ADR-0031), so reading forward costs
	-- nothing. One that has seen no batch for this long is closed, because it
	-- holds an open statement on both sides. An hour, not the five minutes it
	-- was, because a result is read by scrolling now and a reader can be away
	-- from the keyboard a long time without having abandoned it (ADR-0041).
	-- Since that record also removed the cap on how many results stay open,
	-- this sweep and the close that happens when the grid shows another result
	-- are the only automatic reclamation left; zero disables the sweep, which
	-- then means a cursor lives until its result is replaced or the process
	-- ends. It travels inside `connect`, so changing it does not reach a
	-- connection that is already open.
	cursor_idle_seconds = 3600,
	-- Statement timeout, enforced on the server. Zero means no timeout: the
	-- query runs as long as it takes and :NGripCancel stops it by hand.
	timeout_ms = 30000,
	-- Columns wider than this are truncated with an ellipsis in the grid; the
	-- yanked and exported value is always the untruncated one.
	max_column_width = 60,
	min_column_width = 3,
	-- Rows scanned when measuring column widths.
	width_sample = 1000,
	null_text = "NULL",
	-- Number the data rows in a left gutter, 1..N down the page. Off by
	-- default; it is drawn through 'statuscolumn', so it never becomes a real
	-- column and yanking or following a key is unaffected.
	row_numbers = false,
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
	-- the state directory, where it answers every level of the tree down to a
	-- column until it is asked for again. The sweep runs on
	-- connections of its own so the editor is never queued behind it; this is
	-- how many of them at most. One keeps it on the single connection the
	-- process already has, which is what a file-backed driver gets anyway.
	introspect_parallelism = 4,
	introspect_timeout_ms = 600000,
	-- Collect each table's indexes and foreign keys as well, which is what
	-- lets a definition be rendered without asking the server. Off, the sweep
	-- is a good deal cheaper and a definition costs one round trip.
	introspect_details = true,
	-- Validate the statement under the cursor on save. The server parses it
	-- and never runs it, so this is safe for every kind of statement.
	validate_on_save = true,
	-- Stop a connection's gripd after this long with nothing to do. Zero
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
