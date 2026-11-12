-- Every yank and export reads the stored value, never the screen text, which may be truncated.
local notify = require("neogrip.notify")
local grid = require("neogrip.grid")
local value_module = require("neogrip.codec.value")

local M = {}

local function state_of(bufnr)
	return grid.state(bufnr or vim.api.nvim_get_current_buf())
end

function M.move(bufnr, row_delta, column_delta)
	bufnr = bufnr or vim.api.nvim_get_current_buf()
	local state = state_of(bufnr)
	if not state then
		return
	end
	if row_delta ~= 0 then
		state.row = math.max(1, math.min(#state.rows, state.row + row_delta))
	end
	if column_delta ~= 0 then
		state.column = math.max(1, math.min(#state.columns, state.column + column_delta))
	end
	grid.focus_cell(bufnr, 0)
end

local function jump(bufnr, field, where)
	bufnr = bufnr or vim.api.nvim_get_current_buf()
	local state = state_of(bufnr)
	if not state then
		return
	end
	state[field] = where(state)
	grid.focus_cell(bufnr, 0)
end

function M.next_column(bufnr)
	M.move(bufnr, 0, 1)
end

function M.prev_column(bufnr)
	M.move(bufnr, 0, -1)
end

function M.down(bufnr)
	M.move(bufnr, 1, 0)
end

function M.up(bufnr)
	M.move(bufnr, -1, 0)
end

function M.first_column(bufnr)
	jump(bufnr, "column", function()
		return 1
	end)
end

function M.last_column(bufnr)
	jump(bufnr, "column", function(state)
		return #state.columns
	end)
end

function M.first_row(bufnr)
	jump(bufnr, "row", function()
		return 1
	end)
end

function M.last_row(bufnr)
	jump(bufnr, "row", function(state)
		return #state.rows
	end)
end

local function copy(text, what)
	vim.fn.setreg('"', text)
	vim.fn.setreg("+", text)
	notify.send(("%s copied (%d chars)"):format(what, #text))
end

function M.yank_cell(bufnr)
	bufnr = bufnr or vim.api.nvim_get_current_buf()
	local value = grid.cell_value(bufnr)
	if value == nil then
		return
	end
	copy(value_module.display(value, "NULL"), "cell")
end

function M.yank_row(bufnr)
	local state = state_of(bufnr)
	if not state then
		return
	end
	local csv = require("neogrip.codec.csv")
	local row = state.rows[state.row]
	if not row then
		return
	end
	copy(csv.encode_row(row, { count = #state.columns }), "row")
end

function M.yank_column(bufnr)
	local state = state_of(bufnr)
	if not state then
		return
	end
	local values = {}
	for _, row in ipairs(state.rows) do
		values[#values + 1] = value_module.display(row[state.column], "NULL")
	end
	copy(table.concat(values, "\n"), ("column %s"):format(state.columns[state.column] or "?"))
end

--- The form a stored value takes in a generated statement. MySQL and MariaDB
--- read a backslash inside a string literal as an escape, so it is doubled there too.
local function literal(driver, value)
	if type(value) == "number" then
		return value_module.display(value)
	end
	if type(value) == "boolean" then
		-- SQL Server has no boolean; a bit column is what arrives as one.
		if driver == "mssql" then
			return value and "1" or "0"
		end
		return value and "TRUE" or "FALSE"
	end
	local text = value_module.display(value)
	if driver == "mysql" or driver == "mariadb" then
		text = (text:gsub("\\", "\\\\"))
	end
	return ("'%s'"):format((text:gsub("'", "''")))
end

--- The foreign key this column takes part in, if any.
local function key_of(details, column)
	for _, key in ipairs(details.foreign_keys or {}) do
		for _, name in ipairs(key.columns or {}) do
			if tostring(name) == tostring(column) then
				return key
			end
		end
	end
	return nil
end

--- Every part of the key, paired with the value the row under the cursor holds:
--- a composite key needs all of its parts, or the statement lands on more rows than the cursor's.
--- @return table[]|nil pairs of { referenced column, stored value }
--- @return string|nil why there is nothing to select
local function key_values(state, key, table_name)
	local tables = state.result.column_tables or {}
	local row = state.rows[state.row] or {}
	local found = {}
	for position, name in ipairs(key.columns or {}) do
		local referenced = (key.ref_columns or {})[position]
		for index, column in ipairs(state.columns) do
			if referenced and tostring(column) == tostring(name) and tables[index] == table_name then
				local value = row[index]
				if value == nil or value == value_module.NULL then
					-- "= NULL" matches nothing, so say why instead of selecting.
					return nil, ("%s is NULL in this row, so it points at nothing"):format(tostring(name))
				end
				found[#found + 1] = { referenced, value }
				break
			end
		end
	end
	if #found == 0 then
		return nil, ("the result does not carry %s"):format(tostring(key.columns and key.columns[1]))
	end
	return found, nil
end

--- Follow the foreign key under the cursor: a query buffer selecting the row this cell points at.
function M.follow_fk(bufnr)
	bufnr = bufnr or vim.api.nvim_get_current_buf()
	local state = state_of(bufnr)
	if not state then
		return
	end
	local schema_ok, schema = pcall(require, "neogrip.catalog")
	if not schema_ok then
		return notify.send("the catalog layer has not landed yet", vim.log.levels.WARN)
	end
	local result = state.result
	local connection = result.connection
	local column = state.columns[state.column]
	if not connection or not column then
		return
	end

	local table_name = (result.column_tables or {})[state.column]
	if table_name == nil or table_name == "" then
		return notify.send(
			("the driver did not say which table %s came from"):format(tostring(column)),
			vim.log.levels.WARN
		)
	end
	-- Several drivers report the schema as "" rather than leaving it out, and it
	-- has to reach the catalog the same way as an absent one.
	local table_schema = (result.column_schemas or {})[state.column]
	if table_schema == "" then
		table_schema = nil
	end

	local catalog = schema.catalog_of(connection)
	local details = schema.details_ready(connection, catalog, table_schema, table_name)
	if not details then
		return notify.send(
			("%s has not been swept, so its keys are not known; :NGripIntrospect would make this work"):format(
				schema.qualify(connection, table_schema, table_name)
			),
			vim.log.levels.WARN
		)
	end

	local key = key_of(details, column)
	if not key then
		return notify.send(("%s is not part of a foreign key"):format(tostring(column)))
	end

	local found, why = key_values(state, key, table_name)
	if not found then
		return notify.send(why, vim.log.levels.WARN)
	end

	local driver = connection.driver
	local predicates = {}
	for _, pair in ipairs(found) do
		predicates[#predicates + 1] = ("%s = %s"):format(
			schema.quote(driver, pair[1]),
			literal(driver, pair[2])
		)
	end
	local statement = ("SELECT * FROM %s WHERE %s"):format(
		-- A key that names no schema of its own points inside this one.
		schema.qualify(connection, key.schema or table_schema, key.table),
		table.concat(predicates, " AND ")
	)

	-- The same cap a generated SELECT gets: nothing says the other side of the key is unique.
	local limit = connection.limit or require("neogrip.config").get().limit
	local text
	if driver == "mssql" then
		text = statement:gsub("^SELECT ", ("SELECT TOP %d "):format(limit)) .. ";"
	else
		text = ("%s LIMIT %d;"):format(statement, limit)
	end
	return require("neogrip.ui.buffer").new_query(connection, text)
end

--- Sort by re-running the statement with an ORDER BY, so the order covers every page.
local function sort(bufnr, descending)
	local state = state_of(bufnr)
	if not state then
		return
	end
	local column = state.columns[state.column]
	if not column then
		return
	end
	require("neogrip.execute").sort(state, column, descending)
end

function M.sort_asc(bufnr)
	sort(bufnr, false)
end

function M.sort_desc(bufnr)
	sort(bufnr, true)
end

local function page(bufnr, delta)
	local state = state_of(bufnr)
	if not state then
		return
	end
	require("neogrip.execute").page(state, delta)
end

function M.page_next(bufnr)
	page(bufnr, 1)
end

function M.page_prev(bufnr)
	page(bufnr, -1)
end

--- The whole document behind a Mongo row.
function M.show_document(bufnr)
	grid.show_document(bufnr or vim.api.nvim_get_current_buf())
end

function M.close(bufnr)
	grid.close(bufnr or vim.api.nvim_get_current_buf())
end

--- Move between result tabs (ADR-0044). These take no buffer: which tab the
--- window shows is a property of the grid, not of any one buffer.
function M.next_tab()
	grid.step_tab(1)
end

function M.prev_tab()
	grid.step_tab(-1)
end

--- Show one tab by its position in the strip, 1-based.
function M.goto_tab(index)
	grid.goto_tab(index)
end

--- Ask where and in what format to export.
function M.export(bufnr)
	require("neogrip.grid.export").pick(bufnr or vim.api.nvim_get_current_buf())
end

--- Write the rows loaded so far to CSV and open a DuckDB query buffer on it.
function M.materialise(bufnr)
	require("neogrip.grid.requery").materialise(bufnr or vim.api.nvim_get_current_buf())
end

return M
