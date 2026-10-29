-- The schema explorer: a Telescope picker you walk into, like the file browser.
--
--   [databases ->] schemas -> tables -> columns
--
-- It opens on the database the current buffer runs against and explores only
-- that one. The buffer already knows which database it is -- db/resolve.lua
-- answers that for every query it runs -- so starting from a list of every
-- configured connection asked a question that was already answered, and gave
-- the wrong answer a way in. A buffer with nothing bound to it yet is asked
-- once, and the choice is bound to it.
--
-- Which levels there are is the engine's shape, not the picker's: SQLite has
-- neither catalogs nor schemas, MySQL calls its one level a database, and
-- Trino has catalogs full of them. tree_of is the single place that knows.
--
-- The first row of every level below the first is "..", which walks back out:
-- the same row the file browser puts there, because a way back you have to
-- remember is a way back you do not use.
--
-- <CR> goes one level in, and on a table it stops and shows the definition
-- instead (db/explorer/detail.lua). <C-o> steps into the level below even
-- there, so a table's columns stay walkable. <BS> goes back out, <C-s> opens a
-- SELECT on the thing under the cursor, <C-g> writes a SELECT, INSERT, UPDATE
-- or DELETE for it, <C-y> writes its qualified name into the buffer the picker
-- was opened from, <C-d> shows the definition, <C-r> drops the cached schema
-- and reloads.
--
-- The window is reused between levels by refreshing the finder, so walking the
-- tree does not flash a new picker each time. Telescope's refresh is not public
-- API, so every call is wrapped and falls back to reopening.
--
-- What makes the walk quick is db/schema's snapshot: one round trip per schema
-- brings back every table with every column, so each level below it, and the
-- preview beside it, are answered from the cache.
local neogrip = require("neogrip")
local icons = require("neogrip.icons")
local schema = require("neogrip.schema")
local store = require("neogrip.schema.store")

local M = {}

local KIND_ICON = {
	table = icons.table,
	temp = icons.table,
	view = icons.branch,
	matview = icons.branch,
	foreign = icons.branch,
	collection = icons.table,
}

-- A schema is the folder of the tree: database -> schema -> table reads as
-- icons.database -> icons.folder -> icons.table.
local SCHEMA_ICON = icons.folder

--- "1 table", not "1 tables". A count in a hint is read, not parsed.
local function counted(amount, noun)
	return ("%d %s%s"):format(amount, noun, amount == 1 and "" or "s")
end

--- Each level knows how to load its entries, how to show them, and what the
--- level below it is. Exposed as M.levels so the tests can walk the tree
--- without pretending to be a keyboard.
local levels = {}
M.levels = levels

local function entry_display(text, hint)
	if not hint or hint == "" then
		return text
	end
	return ("%-40s %s"):format(text, hint)
end

--- Where a walk into this connection begins -- and where it resumes once a
--- database has been chosen, which is the same question asked twice.
---
--- A connection that names its database starts below that level: there is
--- nothing to choose. Trino is why the name is carried as the catalog too --
--- asked for every catalog at once it answers with every catalog's schemas and
--- nothing saying which is which -- and the drivers with a single catalog per
--- connection ignore the argument.
--- @return table { level: string, context: table }
local function tree_of(connection)
	local driver = connection.driver
	if driver == "sqlite" or driver == "duckdb" then
		return { level = "tables", context = { connection = connection } }
	end

	local named = connection.database ~= nil and connection.database ~= ""
	if driver == "mysql" or driver == "mariadb" or driver == "mongodb" then
		if named then
			return {
				level = "tables",
				context = { connection = connection, schema = connection.database },
			}
		end
		return { level = "databases", context = { connection = connection } }
	end

	local catalog = schema.catalog_of(connection)
	if catalog then
		return { level = "schemas", context = { connection = connection, catalog = catalog } }
	end
	return { level = "databases", context = { connection = connection } }
end

--- Exposed so :NGripIntrospect and :NGripDoctor sweep and report the catalog the
--- explorer will actually read, and so the tests can check the shape per
--- driver without a picker.
M.entry_point = tree_of

levels.databases = {
	title = "Databases",
	load = function(context, callback)
		schema.databases(context.connection, function(records, err)
			if err then
				return callback(nil, err)
			end
			local list = {}
			for _, record in ipairs(records) do
				list[#list + 1] = {
					value = record.name,
					text = ("%s %s"):format(icons.database, record.name),
				}
			end
			callback(list)
		end)
	end,
	child = function(context, entry)
		-- Choosing a database means a connection pointed at that database, and
		-- re-entering the tree with it: the level below depends on the engine,
		-- which tree_of already knows.
		return tree_of(vim.tbl_extend("force", context.connection, { database = entry.value }))
	end,
}

levels.schemas = {
	title = "Schemas",
	load = function(context, callback)
		schema.schemas(context.connection, context.catalog, function(records, err)
			if err then
				return callback(nil, err)
			end
			local list = {}
			for _, record in ipairs(records) do
				-- How much is in there, when the sweep has been taken: free,
				-- and it is the first thing you want to know about a schema.
				local held = store.tables(context.connection, context.catalog, record.name)
				list[#list + 1] = {
					value = record.name,
					text = ("%s %s"):format(SCHEMA_ICON, record.name),
					hint = held and counted(#held, "table") or nil,
				}
			end
			if #list == 0 then
				local only = context.connection.schema or "public"
				list[1] = { value = only, text = ("%s %s"):format(SCHEMA_ICON, only) }
			end
			callback(list)
		end)
	end,
	child = function(context, entry)
		return {
			level = "tables",
			context = { connection = context.connection, catalog = context.catalog, schema = entry.value },
		}
	end,
}

levels.tables = {
	title = "Tables",
	load = function(context, callback)
		schema.tables(context.connection, context.schema, nil, function(records, err)
			if err then
				return callback(nil, err)
			end
			local list = {}
			for _, record in ipairs(records) do
				local kind = tostring(record.kind or "table")
				local marks = {}
				if kind ~= "table" then
					marks[#marks + 1] = kind
				end
				local columns = #(record.columns or {})
				if columns > 0 then
					marks[#marks + 1] = counted(columns, "column")
				end
				list[#list + 1] = {
					value = record.name,
					kind = kind,
					text = ("%s %s"):format(KIND_ICON[kind] or icons.file, record.name),
					hint = #marks > 0 and table.concat(marks, "  ") or nil,
				}
			end
			callback(list)
		end, context.catalog)
	end,
	child = function(context, entry)
		return {
			level = "columns",
			context = {
				connection = context.connection,
				catalog = context.catalog,
				schema = context.schema,
				table = entry.value,
			},
		}
	end,
	-- A table is where walking in stops being a list: <CR> shows the
	-- definition, and <C-o> still steps into the column list.
	open = function(context, entry)
		require("neogrip.explorer.detail").show(context, entry.value)
	end,
}

levels.columns = {
	title = "Columns",
	load = function(context, callback)
		schema.columns(context.connection, context.schema, context.table, function(records, err)
			if err then
				return callback(nil, err)
			end
			local list = {}
			for _, record in ipairs(records) do
				local flags = {}
				if record.is_pk == true or record.is_pk == 1 or record.is_pk == "1" then
					flags[#flags + 1] = "PK"
				end
				if record.nullable == false or record.nullable == 0 or record.nullable == "0" then
					flags[#flags + 1] = "NOT NULL"
				end
				if record.count then
					flags[#flags + 1] = ("%s docs"):format(record.count)
				end
				-- vim.trim, because a column with no flags would otherwise be
				-- hinted with its type and a trailing space.
				list[#list + 1] = {
					value = record.name,
					column = record,
					text = tostring(record.name),
					hint = vim.trim(("%s %s"):format(record.type or "", table.concat(flags, " "))),
				}
			end
			callback(list)
		end, context.catalog)
	end,
	child = function()
		return nil
	end,
}

--- The entries of a level, plus the row that walks back out of it.
---
--- Called from the finder rather than from a level's load: the finder is the
--- one funnel for both the first picker and every refresh, the stack is already
--- current when it runs, and the "nothing to show" guard still sees what the
--- server really answered. The zf sorter drops the row as soon as you type a
--- letter, which is what happens to the file browser's own ".." and is right --
--- while you are filtering you want tables, not the way out.
--- @param stack table[] the levels walked through to get here
function M.with_parent(entries, stack)
	if #stack == 0 then
		return entries
	end
	local previous = stack[#stack]
	local list = { { parent = true, text = (".. %s"):format(levels[previous.level].title) } }
	for _, entry in ipairs(entries) do
		list[#list + 1] = entry
	end
	return list
end

--- What <C-y> inserts and <C-s> selects from, for the entry under the cursor.
function M.qualified_name(level, context, entry)
	if entry.parent then
		return ""
	end
	if level == "columns" then
		return schema.quote(context.connection.driver, entry.value)
	end
	if level == "tables" then
		return schema.qualify(context.connection, context.schema, entry.value)
	end
	return tostring(entry.value)
end

function M.open_select(context, entry, on_done)
	local connection = context.connection
	schema.columns(connection, context.schema, entry.value, function(columns)
		local statement = schema.select_statement(connection, context.schema, entry.value, columns)
		local limit = connection.limit or require("neogrip.config").get().limit
		local text
		if connection.driver == "mongodb" then
			text = ("%s.limit(%d)"):format(statement, limit)
		elseif connection.driver == "mssql" then
			text = statement:gsub("^SELECT ", ("SELECT TOP %d "):format(limit)) .. ";"
		else
			text = ("%s LIMIT %d;"):format(statement, limit)
		end
		local bufnr = require("neogrip.buffer").new_query(connection, text)
		if on_done then
			on_done(bufnr, text)
		end
	end, context.catalog)
end

local PLACEHOLDER = ":%s"

--- A statement to start from, for the table under the cursor.
---
--- The columns and the primary key come out of the catalog, so an UPDATE lands
--- with its WHERE already written and an INSERT does not list the columns the
--- server fills in itself. The values are named placeholders and not valid SQL
--- on purpose: this is a statement you finish, and nothing here should look
--- runnable until you have.
--- @param kind string "select" | "insert" | "update" | "delete"
function M.open_statement(context, entry, kind, on_done)
	local connection = context.connection
	if kind == "select" then
		return M.open_select(context, entry, on_done)
	end

	schema.columns(connection, context.schema, entry.value, function(columns)
		local qualified = schema.qualify(connection, context.schema, entry.value)
		local driver = connection.driver
		local keys = {}
		local writable = {}
		for _, column in ipairs(columns or {}) do
			local name = tostring(column.name)
			if column.is_pk == true or column.is_pk == 1 or column.is_pk == "1" then
				keys[#keys + 1] = name
			end
			-- A column the server writes itself is not one you supply.
			if not column.auto_increment and not column.generated then
				writable[#writable + 1] = name
			end
		end

		local lines = {}
		if #keys == 0 and (kind == "update" or kind == "delete") then
			lines[#lines + 1] = "-- No primary key reported for this table: the WHERE below has to be"
			lines[#lines + 1] = "-- written by hand, and without one this rewrites every row."
		end

		local function conditions()
			local parts = {}
			for _, key in ipairs(keys) do
				parts[#parts + 1] = ("%s = %s"):format(schema.quote(driver, key), PLACEHOLDER:format(key))
			end
			return #parts > 0 and table.concat(parts, " AND ") or ""
		end

		if kind == "insert" then
			local names, values = {}, {}
			for _, name in ipairs(writable) do
				names[#names + 1] = schema.quote(driver, name)
				values[#values + 1] = PLACEHOLDER:format(name)
			end
			lines[#lines + 1] = ("INSERT INTO %s (%s)"):format(qualified, table.concat(names, ", "))
			lines[#lines + 1] = ("VALUES (%s);"):format(table.concat(values, ", "))
		elseif kind == "update" then
			lines[#lines + 1] = ("UPDATE %s SET"):format(qualified)
			local assignments = {}
			for _, name in ipairs(writable) do
				assignments[#assignments + 1] = ("    %s = %s"):format(
					schema.quote(driver, name),
					PLACEHOLDER:format(name)
				)
			end
			lines[#lines + 1] = table.concat(assignments, ",\n")
			lines[#lines + 1] = ("WHERE %s;"):format(conditions())
		else
			lines[#lines + 1] = ("DELETE FROM %s"):format(qualified)
			lines[#lines + 1] = ("WHERE %s;"):format(conditions())
		end

		local text = table.concat(lines, "\n")
		local bufnr = require("neogrip.buffer").new_query(connection, text)
		if on_done then
			on_done(bufnr, text)
		end
	end, context.catalog)
end

--- The table's definition, in a read-only buffer. See db/explorer/detail.lua.
function M.show_ddl(context, entry, on_done)
	require("neogrip.explorer.detail").show(context, entry.value, on_done)
end

--- Write a name into the buffer the picker was opened from.
---
--- Both the window and the buffer are remembered, because the window is not
--- enough: by the time this runs it may be showing something else, and putting
--- the text into whatever is current would edit the wrong file.
function M.insert_name(origin_win, origin_buf, name)
	local target_win = nil
	if
		origin_win
		and vim.api.nvim_win_is_valid(origin_win)
		and vim.api.nvim_win_get_buf(origin_win) == origin_buf
	then
		target_win = origin_win
	else
		for _, winid in ipairs(vim.api.nvim_list_wins()) do
			if vim.api.nvim_win_get_buf(winid) == origin_buf then
				target_win = winid
				break
			end
		end
	end

	if target_win then
		vim.api.nvim_set_current_win(target_win)
		vim.api.nvim_put({ name }, "c", true, true)
		return
	end

	-- The buffer is not on screen any more: write at its cursor position
	-- without making it current.
	if origin_buf and vim.api.nvim_buf_is_valid(origin_buf) then
		local mark = vim.api.nvim_buf_get_mark(origin_buf, '"')
		local row = math.max(mark[1] - 1, 0)
		local line = vim.api.nvim_buf_get_lines(origin_buf, row, row + 1, false)[1] or ""
		vim.api.nvim_buf_set_text(origin_buf, row, #line, row, #line, { name })
	end
end

local function title_for(level_name, context)
	local title = levels[level_name].title
	if not context.connection then
		return title
	end
	title = ("%s  %s"):format(title, context.connection.name)
	if schema.introspecting(context.connection, context.catalog) then
		-- Worth saying: until it lands, every level is still a round trip.
		title = title .. "  (introspecting)"
	end
	if context.catalog then
		title = ("%s/%s"):format(title, context.catalog)
	end
	if context.schema then
		title = ("%s/%s"):format(title, context.schema)
	end
	if context.table then
		title = ("%s.%s"):format(title, context.table)
	end
	return title
end

--- Take the one sweep of this database, if it has never been taken.
---
--- Started and not waited for. The levels keep being served a round trip at a
--- time while it runs, and once it lands every one of them -- and every
--- table's definition in the preview -- is answered from disk instead.
local sweep_refused = {}

function M.prepare(connection, catalog)
	if not require("neogrip.config").get().introspect_on_first_use then
		return
	end
	if connection.driver == "mongodb" then
		-- There is no catalog of a collection's fields to sweep: a document
		-- store is described by sampling documents, which the preview does.
		return
	end
	local key = ("%s|%s"):format(connection.id, tostring(catalog or ""))
	if sweep_refused[key] then
		-- Asked once and refused -- an engine that cannot be swept, or a
		-- server that was down. Warning again on every open would be noise,
		-- and :NGripIntrospect is still there to force one.
		return
	end
	if schema.snapshot_stat(connection, catalog) or schema.introspecting(connection, catalog) then
		return
	end
	neogrip.notify(
		("introspecting %s in the background; the explorer works meanwhile"):format(connection.name)
	)
	schema.introspect(connection, catalog, {}, function(summary, err)
		if err then
			sweep_refused[key] = true
			return neogrip.notify(("introspect failed: %s"):format(err), vim.log.levels.WARN)
		end
		neogrip.notify(("%s: %d tables ready to explore"):format(connection.name, summary.tables))
	end)
end

--- @param opts table|nil { level, context, origin_buf, origin_win, stack }
--- The tree through vim.ui.select, for an editor without telescope: the same
--- levels, the same default action - parent walks out, a table opens its
--- definition, the deepest level inserts the qualified name.
function M.walk(state, origin_win, origin_buf)
	local level = levels[state.level]
	level.load(state.context, function(entries, err)
		if err then
			return neogrip.notify(err, vim.log.levels.ERROR)
		end
		entries = M.with_parent(entries or {}, state.stack)
		if #entries == 0 then
			return neogrip.notify(("nothing to show in %s"):format(level.title), vim.log.levels.WARN)
		end
		vim.ui.select(entries, {
			prompt = title_for(state.level, state.context),
			format_item = function(entry)
				if entry.parent then
					return ".."
				end
				return tostring(entry.text) .. (entry.hint and ("  " .. entry.hint) or "")
			end,
		}, function(entry)
			if not entry then
				return
			end
			if entry.parent then
				local previous = table.remove(state.stack)
				if previous then
					state.level, state.context = previous.level, previous.context
					return M.walk(state, origin_win, origin_buf)
				end
				return
			end
			if level.open then
				return level.open(state.context, entry)
			end
			local child = level.child(state.context, entry)
			if child then
				table.insert(state.stack, { level = state.level, context = state.context })
				state.level, state.context = child.level, child.context
				return M.walk(state, origin_win, origin_buf)
			end
			M.insert_name(origin_win, origin_buf, M.qualified_name(state.level, state.context, entry))
		end)
	end)
end

function M.open(opts)
	opts = opts or {}
	local origin_buf = opts.origin_buf or vim.api.nvim_get_current_buf()
	local origin_win = opts.origin_win or vim.api.nvim_get_current_win()

	-- No level asked for means this is the entry, not a step: work out which
	-- database this buffer belongs to and open on it.
	if not opts.level then
		local resolve = require("neogrip.resolve")
		local connection = resolve.for_buf(origin_buf)
		if not connection then
			-- Nothing bound yet: ask once, keep the answer on the buffer, and
			-- walk straight in. The same fallback <leader>qn uses.
			return resolve.pick(origin_buf, function()
				M.open({ origin_buf = origin_buf, origin_win = origin_win })
			end)
		end
		local entry = tree_of(connection)
		opts.level, opts.context = entry.level, entry.context
		M.prepare(connection, entry.context.catalog)
	end

	-- Telescope is optional. Without it the same tree walks through
	-- vim.ui.select: no preview and no extra actions, but every level, the
	-- table definitions and name insertion all work. The picker's own controls
	-- (<BS>, <C-s>, ...) are picker-internal prompt mappings - the transient
	-- UI's own buttons, not editor keymaps in the sense of ADR-0017.
	local ok_telescope, pickers = pcall(require, "telescope.pickers")
	if not ok_telescope then
		return M.walk({
			level = opts.level,
			context = opts.context or {},
			stack = opts.stack or {},
		}, origin_win, origin_buf)
	end
	local finders = require("telescope.finders")
	local conf = require("telescope.config").values
	local actions = require("telescope.actions")
	local action_state = require("telescope.actions.state")

	-- Where this picker currently is. Mutable on purpose: walking a level
	-- refreshes the one picker instead of closing it and building another, so
	-- the previewer and the mappings are created once and read the level from
	-- here rather than from what they captured.
	local state = {
		level = opts.level,
		context = opts.context or {},
		stack = opts.stack or {},
	}

	local function finder_for(entries)
		return finders.new_table({
			results = M.with_parent(entries, state.stack),
			entry_maker = function(entry)
				return {
					value = entry,
					display = entry_display(entry.text, entry.hint),
					ordinal = tostring(entry.text) .. " " .. tostring(entry.hint or ""),
				}
			end,
		})
	end

	levels[state.level].load(state.context, function(entries, err)
		if err then
			return neogrip.notify(err, vim.log.levels.ERROR)
		end
		if not entries or #entries == 0 then
			return neogrip.notify(
				("nothing to show in %s"):format(levels[state.level].title),
				vim.log.levels.WARN
			)
		end

		local picker, prompt_buf

		--- Put the cursor on the first real row rather than on "..".
		---
		--- The first result is drawn next to the prompt (Telescope sorts
		--- descending by default) and the selection resets to it after every
		--- sort, so walking into a level would leave <CR> pointing straight
		--- back out. Telescope runs these callbacks when a sort settles, which
		--- is the hook the file browser uses for the same problem;
		--- default_selection_index would also fire while typing, where the ".."
		--- row has been filtered away and row two is a real result.
		local function keep_cursor_off_parent()
			if not picker then
				return
			end
			picker._completion_callbacks = picker._completion_callbacks or {}
			table.insert(picker._completion_callbacks, function(self)
				local manager = self.manager
				local first = manager and manager:get_entry(1)
				if first and first.value and first.value.parent and manager:num_results() > 1 then
					pcall(self.set_selection, self, self:get_row(2))
				end
				table.remove(self._completion_callbacks)
			end)
		end

		--- Move this picker to another level in place.
		---
		--- Telescope's refresh and its title setter are both internal, so a
		--- failure here falls back to closing and reopening -- which is what
		--- this did on every single step before, and what made walking the
		--- tree flash a new window each time.
		local function go(level_name, context, stack)
			local target = levels[level_name]
			target.load(context, function(list, load_err)
				if load_err then
					return neogrip.notify(load_err, vim.log.levels.ERROR)
				end
				if not list or #list == 0 then
					return neogrip.notify(("nothing to show in %s"):format(target.title), vim.log.levels.WARN)
				end
				state.level, state.context, state.stack = level_name, context, stack
				local title = title_for(level_name, context)
				local refreshed = picker
					and pcall(function()
						keep_cursor_off_parent()
						picker:refresh(finder_for(list), { reset_prompt = true })
						picker.prompt_title = title
						if picker.prompt_border and picker.prompt_border.change_title then
							picker.prompt_border:change_title(" " .. title .. " ")
						end
					end)
				if not refreshed then
					if prompt_buf then
						pcall(actions.close, prompt_buf)
					end
					M.open({
						level = level_name,
						context = context,
						stack = stack,
						origin_buf = origin_buf,
						origin_win = origin_win,
					})
				end
			end)
		end

		pickers
			-- No layout of its own: the defaults in plugins/editor/telescope.lua
			-- are full-window horizontal with the preview taking half, and this
			-- picker is one of the editor's pickers, not a dialog. Anything it
			-- spelled out here would drift from the rest of them.
			.new({}, {
				prompt_title = title_for(state.level, state.context),
				finder = finder_for(entries),
				sorter = conf.generic_sorter({}),
				previewer = require("neogrip.explorer.preview").previewer(state),
				attach_mappings = function(prompt_bufnr, map)
					prompt_buf = prompt_bufnr
					picker = action_state.get_current_picker(prompt_bufnr)
					-- Reopening after a failed refresh lands on a level that
					-- has a way back, and this is the first moment the picker
					-- exists to register against.
					keep_cursor_off_parent()

					local function selected()
						local entry = action_state.get_selected_entry()
						return entry and entry.value or nil
					end

					local function descend(entry)
						if entry.parent then
							return false
						end
						local level = levels[state.level]
						local child = level.child(state.context, entry)
						if not child then
							return false
						end
						local next_stack = vim.deepcopy(state.stack)
						table.insert(next_stack, { level = state.level, context = state.context })
						go(child.level, child.context, next_stack)
						return true
					end

					local function go_back()
						local previous = state.stack[#state.stack]
						if not previous then
							-- The top of the tree is this buffer's own
							-- database, so there is nothing above it to walk
							-- out to; <Esc> and q are how you leave.
							return
						end
						local next_stack = vim.deepcopy(state.stack)
						table.remove(next_stack)
						go(previous.level, previous.context, next_stack)
					end

					actions.select_default:replace(function()
						local entry = selected()
						if not entry then
							return
						end
						-- Before anything else: on the ".." row every action
						-- below would be asking about a table called "..".
						if entry.parent then
							return go_back()
						end
						local level = levels[state.level]
						-- A table stops the walk and shows its definition.
						if level.open then
							actions.close(prompt_bufnr)
							return level.open(state.context, entry)
						end
						if descend(entry) then
							return
						end
						-- The deepest level: insert the name, which is the only
						-- useful thing left to do with a column. Through
						-- insert_name, which revalidates the window and the
						-- buffer -- putting the text into whatever happens to be
						-- current would edit the wrong file.
						local name = M.qualified_name(state.level, state.context, entry)
						actions.close(prompt_bufnr)
						M.insert_name(origin_win, origin_buf, name)
					end)

					map("i", "<BS>", function()
						-- Only leave the level when the prompt is empty, so
						-- backspace still edits the filter.
						local prompt = action_state.get_current_line()
						if prompt == "" then
							go_back()
						else
							vim.api.nvim_feedkeys(vim.keycode("<BS>"), "n", false)
						end
					end)
					map("n", "<BS>", go_back)

					-- Step into the level below even where <CR> does something
					-- else: a table's columns are still worth walking.
					map({ "i", "n" }, "<C-o>", function()
						local entry = selected()
						if entry then
							descend(entry)
						end
					end)

					map({ "i", "n" }, "<C-s>", function()
						local entry = selected()
						if not entry or entry.parent or state.level ~= "tables" then
							return
						end
						local context = state.context
						actions.close(prompt_bufnr)
						M.open_select(context, entry)
					end)

					map({ "i", "n" }, "<C-y>", function()
						local entry = selected()
						if not entry or entry.parent then
							return
						end
						local name = M.qualified_name(state.level, state.context, entry)
						actions.close(prompt_bufnr)
						M.insert_name(origin_win, origin_buf, name)
					end)

					map({ "i", "n" }, "<C-d>", function()
						local entry = selected()
						if not entry or entry.parent then
							return
						end
						if state.level ~= "tables" and state.level ~= "columns" then
							return
						end
						-- On a column the definition to show is still its
						-- table's: the context knows which table, where the
						-- entry is only one of its columns.
						local target = entry
						if state.level == "columns" then
							target = { value = state.context.table }
						end
						local context = state.context
						actions.close(prompt_bufnr)
						M.show_ddl(context, target)
					end)

					map({ "i", "n" }, "<C-g>", function()
						local entry = selected()
						if not entry or entry.parent or state.level ~= "tables" then
							return
						end
						local context = state.context
						actions.close(prompt_bufnr)
						vim.ui.select({ "select", "insert", "update", "delete" }, {
							prompt = ("Statement for %s"):format(tostring(entry.value)),
						}, function(kind)
							if kind then
								M.open_statement(context, entry, kind)
							end
						end)
					end)

					map({ "i", "n" }, "<C-r>", function()
						local level_name, context, stack = state.level, state.context, state.stack
						schema.invalidate(context.connection)
						neogrip.notify("schema cache cleared")
						go(level_name, context, stack)
					end)

					return true
				end,
			})
			:find()
	end)
end

return M
