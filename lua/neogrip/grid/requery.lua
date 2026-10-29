-- Querying a result with SQL (ADR-0021).
--
-- The grid's rows are written as CSV and registered as a view in a scratch
-- DuckDB file; a query buffer then opens against that file. The result of that
-- query can be materialised in turn, so results compose.
--
-- The scratch is a file rather than :memory: so it survives whatever happens
-- to the Java process, and per-PID because a DuckDB file takes a single
-- writer and its format is tied to the driver's version. A file written by
-- another DuckDB version will not open: the driver says so plainly, and a new
-- scratch costs nothing.
local neogrip = require("neogrip")
local config = require("neogrip.config")
local export = require("neogrip.grid.export")

local M = {}

local counter = 0

local function scratch_dir()
	local dir = neogrip.state_dir .. "/scratch"
	vim.fn.mkdir(dir, "p")
	return dir
end

function M.scratch_path()
	return ("%s/%d.duckdb"):format(scratch_dir(), vim.uv.os_getpid())
end

--- The synthetic connection the scratch is queried through. Registered so a
--- query buffer opened on it resolves to it by id like any other.
function M.connection()
	return require("neogrip.connections").register({
		id = "__scratch__",
		name = "results (duckdb)",
		driver = "duckdb",
		file = M.scratch_path(),
		auth = { type = "none" },
		options = {},
		readonly = false,
		production = false,
		scope = "global",
	})
end

--- Register a CSV as a view. all_varchar keeps every column as text: type
--- inference on a CSV is a guess, and a guess that turns an id into a float is
--- worse than a string. A query that needs a number can cast the column, which
--- is at least written down where it happens.
--- @param callback fun(view: string|nil, err: string|nil)
function M.register(csv_path, opts, callback)
	opts = opts or {}
	counter = counter + 1
	local view = opts.name or ("r" .. counter)
	local sql = ([[
CREATE OR REPLACE VIEW %s AS
  SELECT * FROM read_csv('%s', header = true, all_varchar = true, nullstr = '%s');
CREATE OR REPLACE VIEW last AS SELECT * FROM %s;
]]):format(view, csv_path, export.null_marker, view)

	require("neogrip.runner").run({
		connection = M.connection(),
		sql = sql,
		mode = "exec",
		limit = 0,
		background = true,
	}, function(_, err)
		if err then
			return callback(nil, err.message)
		end
		callback(view, nil)
	end)
end

--- Open a query buffer against any CSV file on disk, through the same views.
function M.query_csv(csv_path, callback)
	M.register(csv_path, {}, function(view, err)
		if not view then
			neogrip.notify(("could not open the csv: %s"):format(err), vim.log.levels.ERROR)
			if callback then
				callback(nil, err)
			end
			return
		end
		local bufnr =
			require("neogrip.buffer").new_query(M.connection(), ("SELECT * FROM %s LIMIT 100;"):format(view))
		if callback then
			callback(bufnr, nil)
		end
	end)
end

--- Write the grid's page to CSV, register it, and open a query buffer on it.
function M.materialise(bufnr)
	local grid = require("neogrip.grid")
	local state = grid.state(bufnr)
	if not state or #state.rows == 0 then
		return neogrip.notify("no rows to materialise", vim.log.levels.WARN)
	end

	counter = counter + 1
	local name = "r" .. counter
	local path = ("%s/%s.csv"):format(export.results_dir(), name)
	export.page_to_csv(state, path)

	M.register(path, { name = name }, function(view, err)
		if not view then
			return neogrip.notify(("could not register the result: %s"):format(err), vim.log.levels.ERROR)
		end
		neogrip.notify(("%d rows available as %s (and as 'last')"):format(#state.rows, view))
		require("neogrip.buffer").new_query(M.connection(), ("SELECT * FROM %s LIMIT 100;"):format(view))
	end)
end

--- Is a process still running? uv.kill with signal 0 asks without sending
--- anything. It does not raise for a dead process, it returns nil plus ESRCH,
--- so a plain pcall around it would report every pid as alive.
local function process_alive(pid)
	local ok, result = pcall(vim.uv.kill, pid, 0)
	return ok and result == 0
end

--- Scratches and CSVs from sessions that are gone, plus anything older than
--- the retention window.
local function collect_garbage()
	local retention = config.get().result_retention_days * 24 * 60 * 60
	local now = os.time()
	local mine = vim.uv.os_getpid()

	local function sweep(directory, pattern)
		for _, path in ipairs(vim.fn.glob(directory .. "/" .. pattern, true, true)) do
			local pid = tonumber(vim.fn.fnamemodify(path, ":t:r"))
			if pid and pid ~= mine then
				local stat = vim.uv.fs_stat(path)
				local old = stat and (now - stat.mtime.sec) > retention
				if not process_alive(pid) or old then
					pcall(vim.fn.delete, path, "rf")
				end
			end
		end
	end

	sweep(scratch_dir(), "*.duckdb")
	sweep(neogrip.state_dir .. "/results", "*")
end

function M.setup()
	vim.api.nvim_create_autocmd("VimLeavePre", {
		group = vim.api.nvim_create_augroup("NeogripScratch", { clear = true }),
		callback = function()
			pcall(vim.fn.delete, M.scratch_path())
			pcall(vim.fn.delete, export.results_dir(), "rf")
		end,
	})
	pcall(collect_garbage)
end

return M
