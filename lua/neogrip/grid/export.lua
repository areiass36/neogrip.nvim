-- Writing a result out as CSV or JSON.
--
-- The rows the grid has loaded are written from memory - every one of them, as
-- far down as the reader scrolled (ADR-0040). "Everything" re-runs the
-- statement without a LIMIT and streams the client's output straight to a file
-- descriptor, so a result far larger than memory can still be exported.
local csv = require("neogrip.codec.csv")
local neogrip = require("neogrip")
local value_module = require("neogrip.value")

local M = {}

-- Named, because the picker offers them and the handler compares against them:
-- changing one spelling and not the other would send every choice to the
-- everything branch, which re-runs the statement with no limit.
local CSV_LOADED = "CSV (loaded rows)"
local JSON_LOADED = "JSON (loaded rows)"

local NULL_MARKER = "\\N"

function M.results_dir()
	local dir = ("%s/results/%d"):format(neogrip.state_dir, vim.uv.os_getpid())
	vim.fn.mkdir(dir, "p")
	return dir
end

--- Column names a SQL identifier can hold: lowercased, non-alphanumerics to
--- underscores, a prefix when it starts with a digit, and deduplicated.
function M.safe_columns(columns)
	local out, seen = {}, {}
	for index, column in ipairs(columns) do
		local name = tostring(column):lower():gsub("[^%w_]", "_")
		if name == "" then
			name = "c" .. index
		end
		if name:match("^%d") then
			name = "c_" .. name
		end
		local candidate, suffix = name, 1
		while seen[candidate] do
			suffix = suffix + 1
			candidate = ("%s_%d"):format(name, suffix)
		end
		seen[candidate] = true
		out[index] = candidate
	end
	return out
end

--- Every row the grid has loaded, which is as far as the reader scrolled. The
--- name is kept for the callers it already has; "page" has not been a unit here
--- since ADR-0040.
--- @return string path
function M.page_to_csv(state, path)
	local columns = M.safe_columns(state.columns)
	local lines = { csv.encode_row(columns, { count = #columns }) }
	for _, row in ipairs(state.rows) do
		lines[#lines + 1] = csv.encode_row(row, { count = #columns, null_marker = NULL_MARKER })
	end
	-- A quoted field can contain a newline, so the file is written as one blob
	-- rather than a list of lines.
	local text = table.concat(lines, "\n") .. "\n"
	local fd = assert(vim.uv.fs_open(path, "w", tonumber("600", 8)))
	vim.uv.fs_write(fd, text)
	vim.uv.fs_close(fd)
	return path
end

function M.page_to_json(state, path)
	local documents = {}
	for _, row in ipairs(state.rows) do
		local object = {}
		for index, column in ipairs(state.columns) do
			local value = row[index]
			object[column] = value == neogrip.NULL and vim.NIL or value
		end
		documents[#documents + 1] = object
	end
	local fd = assert(vim.uv.fs_open(path, "w", tonumber("600", 8)))
	vim.uv.fs_write(fd, vim.json.encode(documents))
	vim.uv.fs_close(fd)
	return path
end

--- @param bufnr integer the grid buffer
function M.pick(bufnr)
	local grid = require("neogrip.grid")
	local state = grid.state(bufnr)
	if not state then
		return
	end

	vim.ui.select(
		-- The two labels are compared below, so they are written once here and
		-- matched against these same constants rather than retyped.
		{ CSV_LOADED, JSON_LOADED, "CSV (everything)" },
		{ prompt = "Export" },
		function(choice)
			if not choice then
				return
			end
			local default = ("%s/export-%s"):format(vim.fn.getcwd(), os.date("%Y%m%d-%H%M%S"))
			local extension = choice:match("^JSON") and ".json" or ".csv"
			vim.ui.input(
				{ prompt = "Write to: ", default = default .. extension, completion = "file" },
				function(path)
					if not path or path == "" then
						return
					end
					path = vim.fn.expand(path)
					if choice == CSV_LOADED then
						M.page_to_csv(state, path)
						neogrip.notify(("%d rows written to %s"):format(#state.rows, path))
					elseif choice == JSON_LOADED then
						M.page_to_json(state, path)
						neogrip.notify(("%d rows written to %s"):format(#state.rows, path))
					else
						M.everything(state, path)
					end
				end
			)
		end
	)
end

--- Re-run without a limit, streaming straight to disk.
---
--- The Java side writes the file row by row as the driver hands them over, so
--- a result far larger than memory still exports; nothing is collected here.
function M.everything(state, path)
	local runner = require("neogrip.runner")
	local result = state.result
	neogrip.notify("exporting the full result...")
	runner.run({
		connection = result.connection,
		-- The statement as it ran, not the one the user typed: a grid that was
		-- sorted carries its ORDER BY in the wrapper around it, and a file
		-- exported in another order than the one on screen is a surprise.
		sql = result.sql or result.base_sql,
		mode = "export",
		limit = 0,
		out_file = path,
		null_marker = NULL_MARKER,
		timeout_ms = 10 * 60 * 1000,
	}, function(written, err)
		if err then
			return neogrip.notify(("export failed: %s"):format(err.message), vim.log.levels.ERROR)
		end
		-- The count comes back from the client, which is the only thing that
		-- saw the rows: nothing was collected here to count.
		neogrip.notify(
			("%s rows written to %s"):format(tostring((written or {}).rows_written or "all"), path)
		)
	end)
end

M.null_marker = NULL_MARKER
M.display = value_module.display

return M
