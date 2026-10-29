-- The explorer's preview pane.
--
-- What it draws lives in M.render, which takes a buffer and fills it; the
-- Telescope previewer is a thin adapter over that. Keeping them apart means the
-- content can be exercised without a running picker.
--
-- A table is drawn with the same rendered definition <CR> opens
-- (db/explorer/detail.lua) and a schema with the same listing its db://schema
-- document holds (db/document.lua), so resting on a row and confirming it never
-- describe the thing two different ways.
local detail = require("neogrip.explorer.detail")
local document = require("neogrip.document")
local layout = require("neogrip.grid.layout")
local schema = require("neogrip.schema")

local M = {}

local function set(bufnr, lines)
	if not vim.api.nvim_buf_is_valid(bufnr) then
		return
	end
	vim.bo[bufnr].modifiable = true
	vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
	vim.bo[bufnr].modifiable = false
end

local function column_lines(column, name)
	return {
		("name       %s"):format(column.name or name),
		("type       %s"):format(column.type or "-"),
		("nullable   %s"):format(tostring(column.nullable)),
		("primary    %s"):format(tostring(column.is_pk)),
		("default    %s"):format(tostring(column.default_expr or "-")),
		column.count and ("documents  %s"):format(tostring(column.count)) or nil,
	}
end

local function flags_of(column)
	local flags = {}
	if column.is_pk == true or column.is_pk == 1 then
		flags[#flags + 1] = "PK"
	end
	if column.nullable == false or column.nullable == 0 then
		flags[#flags + 1] = "NOT NULL"
	end
	if column.count then
		flags[#flags + 1] = ("%s docs"):format(column.count)
	end
	return table.concat(flags, " ")
end

--- Something the pane can say in passing, as a SQL comment.
---
--- Flattened, because a driver's message often runs over several lines and a
--- buffer line cannot hold one: unflattened it would raise out of the previewer
--- instead of being read.
local function comment(text)
	return "-- " .. (tostring(text):gsub("%s+", " "))
end

-- One timer per purpose rather than one timer shared: a schema warm-up and a
-- details fetch can be waiting at the same time, and sharing would let whichever
-- was asked for last cancel the other.
local timers = {}

local function debounce(purpose, delay, callback)
	local timer = timers[purpose]
	if timer then
		timer:stop()
	end
	timers[purpose] = vim.defer_fn(function()
		timers[purpose] = nil
		callback()
	end, delay)
end

-- What the pane is meant to be showing, as of the most recent M.render. The
-- cursor keeps moving while a fetch is out, and the answer to a question asked
-- about the row above describes the wrong table by the time it lands, so every
-- write that is not immediate is checked against this first.
local showing = nil

local function token_of(level_name, context, entry)
	return table.concat({
		tostring(level_name),
		tostring(context.catalog),
		tostring(context.schema),
		tostring(entry.value),
	}, "\t")
end

--- What the swept catalog already knows about this table, or nil.
---
--- Guarded like everything else here: this runs on every cursor movement in the
--- picker, and a previewer that raises takes the whole picker down with it.
local function details_ready(context, table_name)
	local ok, details =
		pcall(schema.details_ready, context.connection, context.catalog, context.schema, table_name)
	if ok and type(details) == "table" then
		return details
	end
	return nil
end

--- Every table of a schema, from the swept catalog, or nil when there is no
--- sweep to read it out of. Guarded for the same reason.
local function tables_ready(context, schema_name)
	local ok, tables = pcall(schema.tables_known, context.connection, context.catalog, schema_name)
	if ok and type(tables) == "table" then
		return tables
	end
	return nil
end

--- The schema's listing, or a comment in its place. The same renderer its
--- db://schema document uses, so the pane and the buffer cannot drift apart.
local function listing(context, schema_name, tables)
	local ok, lines = pcall(document.schema_lines, context.connection, context.catalog, schema_name, tables)
	if ok and type(lines) == "table" then
		return lines
	end
	return { comment(lines) }
end

--- Fill `bufnr` with what is worth knowing about `entry`.
---
--- `on_done` fires once, with the lines the pane is left holding. A table can
--- be written more than once before that: when its definition is not here yet
--- the column list goes up first, so the pane is never blank while the one
--- round trip it costs is out.
--- @param on_done fun(lines: string[])|nil
function M.render(level_name, context, entry, bufnr, on_done)
	local token = token_of(level_name, context, entry)
	showing = token

	local function write(lines)
		if showing ~= token then
			return
		end
		set(bufnr, lines)
	end

	local function finish(lines)
		write(lines)
		if on_done then
			on_done(lines)
		end
	end

	-- Only a table is SQL, and one buffer is reused for every row the cursor
	-- touches, so the highlighting the row before it asked for has to come off
	-- again. Through treesitter alone and never 'filetype', which would fire the
	-- FileType autocommand in db/buffer.lua and hang the query keymaps and the
	-- dialect layer off a buffer Telescope throws away.
	if level_name == "tables" and not entry.parent then
		pcall(vim.treesitter.start, bufnr, "sql")
	else
		pcall(vim.treesitter.stop, bufnr)
	end

	-- The row that walks back out is not an object, so there is nothing to
	-- describe and nothing to ask the server: its own text names where it goes,
	-- which is all a file browser says for its own "..". Asking about it would
	-- send ".." to schema.columns as a table name and spend a round trip on an
	-- error comment.
	if entry.parent then
		return finish({ tostring(entry.text) })
	end

	if level_name == "columns" then
		return finish(column_lines(entry.column or {}, entry.value))
	end

	if level_name == "schemas" then
		-- What is in the schema, not its own name: the name is the row the
		-- cursor is already on, which made this pane the one place in the
		-- picker that told you nothing you could not already see.
		local swept = tables_ready(context, entry.value)
		if swept then
			return finish(listing(context, entry.value, swept))
		end

		-- Nothing swept. Resting here fills the cache for the level below
		-- anyway, so walking in is instant, and that warm-up asks exactly the
		-- question the listing needs -- so the listing is drawn from its answer
		-- rather than asking the server the same thing twice. Debounced,
		-- because the cursor passing over twenty schemas must not queue twenty
		-- round trips on the one worker the connection has, which is also the
		-- worker the user's own query needs.
		local scheduled = M.warm(context.connection, context.catalog, entry.value, function(records, err)
			if showing ~= token then
				return
			end
			if err or type(records) ~= "table" then
				return finish({ comment(err or "the schema could not be read") })
			end
			finish(listing(context, entry.value, records))
		end)
		if not scheduled then
			return finish(listing(context, entry.value, nil))
		end
		return write({ comment("(reading the schema...)") })
	end

	if level_name ~= "tables" then
		return finish({ tostring(entry.text or entry.value) })
	end

	local table_name = entry.value

	--- The definition, or a comment in its place. Pure, and the same renderer
	--- <CR> uses, so the pane and the buffer it opens cannot drift apart.
	local function definition(details)
		local ok, rendered = pcall(detail.render, context.connection, context, table_name, details)
		if ok and type(rendered) == "table" then
			return rendered
		end
		return {
			("-- %s: the definition could not be rendered"):format(tostring(table_name)),
			comment(rendered),
		}
	end

	local function show(details)
		local lines = definition(details)

		-- Metadata only by default. The definition is written from what is
		-- already here, where a sample is a real query against every table the
		-- cursor lands on: the explorer's slowness was mostly this line.
		if not require("neogrip.config").get().preview_sample then
			return finish(lines)
		end

		-- Under the definition rather than over it, and behind a comment, so the
		-- pane still reads as the one SQL buffer it is highlighted as.
		lines[#lines + 1] = ""
		lines[#lines + 1] = "-- Sample"
		write(lines)

		schema.sample(context.connection, context.schema, table_name, 5, function(result, sample_err)
			if sample_err then
				lines[#lines + 1] = comment(("(%s)"):format(sample_err))
			elseif not result or #(result.columns or {}) == 0 then
				lines[#lines + 1] = comment("(no rows)")
			else
				-- Narrow columns: the preview pane is half a window wide.
				local computed = layout.compute(result.columns, result.rows, { max_width = 24 })
				vim.list_extend(lines, (layout.render(computed, result.columns, result.rows, {})))
			end
			finish(lines)
		end)
	end

	-- The normal case, once a database has been introspected: everything the
	-- definition is written from is on disk already, so there is nothing to wait
	-- for and nothing to debounce. Scrolling a long list of tables has to feel
	-- like scrolling the list, not like asking the server fifty questions.
	local ready = details_ready(context, table_name)
	if ready then
		return show(ready)
	end

	-- Nothing swept for this table yet. Its columns are what the per-schema
	-- snapshot can usually answer without leaving the cache, so they go up as a
	-- skeleton and the definition replaces them when it lands.
	schema.columns(context.connection, context.schema, table_name, function(columns, err)
		if err then
			return finish({ comment("columns: " .. err) })
		end
		local lines = {}
		for _, column in ipairs(columns or {}) do
			lines[#lines + 1] = ("%-28s %-22s %s"):format(
				column.name or "",
				column.type or "",
				flags_of(column)
			)
		end
		write(lines)

		-- Debounced for the same reason the schema warm-up is: the fetch is a
		-- round trip on the one worker the connection has, so the cursor passing
		-- over fifty tables must not queue fifty of them. The token is checked
		-- again here because a table whose definition was already on disk draws
		-- without debouncing, and so would leave this timer to fire for a row
		-- the pane has left behind.
		local settings = require("neogrip.config").get()
		debounce("details", settings.schema_warm_debounce_ms or 250, function()
			if showing ~= token then
				return
			end
			schema.details(context.connection, context.schema, table_name, function(details, fetch_err)
				if fetch_err or type(details) ~= "table" then
					-- The columns are still true, and are more use than the
					-- reason the rest of it is missing.
					return finish(lines)
				end
				show(details)
			end, context.catalog)
		end)
	end, context.catalog)
end

--- Warm a schema's snapshot once the cursor has settled on it.
---
--- `on_done` takes the answer rather than letting it be thrown away, because
--- the listing the pane draws for a schema is that same answer: asking for it
--- separately would put two sweeps of the one schema on the one worker the
--- connection has.
--- @param on_done fun(tables: table[]|nil, err: string|nil)|nil
--- @return boolean whether anything was scheduled, which it is not when the
--- user has switched warming off
function M.warm(connection, catalog, schema_name, on_done)
	local settings = require("neogrip.config").get()
	if not settings.schema_warm or not connection then
		return false
	end
	debounce("warm", settings.schema_warm_debounce_ms or 250, function()
		if not on_done then
			return schema.warm(connection, catalog, schema_name)
		end
		schema.tables(connection, schema_name, nil, on_done, catalog)
	end)
	return true
end

--- @param state table the explorer's live { level, context }, not a snapshot of
--- it: the picker is refreshed in place when you walk a level, so a previewer
--- that captured the level it was built with would describe the wrong one.
function M.previewer(state)
	local ok, previewers = pcall(require, "telescope.previewers")
	if not ok then
		return nil
	end

	return previewers.new_buffer_previewer({
		title = "Details",
		define_preview = function(self, entry)
			M.render(state.level, state.context, entry.value, self.state.bufnr)
		end,
	})
end

return M
