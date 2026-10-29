-- The explorer's preview pane, with the data layer stubbed out: no server, no
-- Java process and no picker. What is worth pinning down here is that the pane
-- and the buffer <CR> opens say the same thing, and that a slow answer cannot
-- paint a pane the cursor has already left.
local support = require("tests.support")
local check = support.check
local config = require("neogrip.config")
local detail = require("neogrip.explorer.detail")
local preview = require("neogrip.explorer.preview")
local schema = require("neogrip.schema")

local connection = { id = "__test_preview__", name = "test", driver = "postgres" }
local context = { connection = connection, catalog = "testdb", schema = "public" }

local DETAILS = {
	rows = {
		{ name = "id", type = "bigint", nullable = false, is_pk = true },
		{ name = "email", type = "text", nullable = false, default_expr = "''::text" },
	},
	primary_key = { "id" },
	indexes = { { name = "users_email_key", unique = true, columns = { "email" } } },
	foreign_keys = {},
	referenced_by = {
		{
			name = "orders_user_fk",
			schema = "public",
			table = "orders",
			columns = { "user_id" },
			ref_columns = { "id" },
		},
	},
}

-- Short enough that the suite does not sit waiting for a debounce, long enough
-- that a second render still lands inside it.
vim.g.db_config = vim.tbl_extend("force", vim.g.db_config or {}, { schema_warm_debounce_ms = 20 })
config.reload()

local saved = {
	details_ready = schema.details_ready,
	columns = schema.columns,
	details = schema.details,
	sample = schema.sample,
}

--- What the stubs were asked for, so a test can assert on what was *not* asked.
local asked = { ready = 0, columns = 0, details = 0 }
local ready_answer, details_answer = nil, nil
local on_details_called = nil

schema.details_ready = function()
	asked.ready = asked.ready + 1
	return ready_answer
end
schema.columns = function(_, _, _, callback)
	asked.columns = asked.columns + 1
	callback({ { name = "id", type = "bigint", nullable = false, is_pk = true } }, nil)
end
schema.details = function(_, _, _, callback)
	asked.details = asked.details + 1
	if on_details_called then
		on_details_called()
	end
	callback(details_answer, nil)
end

local bufnr = vim.api.nvim_create_buf(false, true)
local function pane()
	return vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
end

support.describe("preview: a table is drawn as its definition")
ready_answer = DETAILS
local lines = support.sync(function(done)
	preview.render("tables", context, { value = "users" }, bufnr, done)
end)
check("the pane is exactly what <CR> would open", lines, detail.render(connection, context, "users", DETAILS))
check("and the buffer holds it", pane(), lines)
check("drawn from what was already known", asked.ready, 1)
check("without a round trip for the columns", asked.columns, 0)
check("or for the definition", asked.details, 0)
check(
	"the indexes are there, which the old column list never showed",
	table.concat(lines, "\n"):find("users_email_key") ~= nil,
	true
)
check("and so is what points at the table", table.concat(lines, "\n"):find("Referenced by") ~= nil, true)
-- Highlighted through treesitter alone: setting 'filetype' would fire the
-- FileType autocommand and hang query keymaps off a throwaway buffer.
check("no filetype was set on the preview buffer", vim.bo[bufnr].filetype, "")

support.describe("preview: a table nobody has swept yet")
ready_answer, details_answer = nil, DETAILS
asked = { ready = 0, columns = 0, details = 0 }
local skeleton = nil
on_details_called = function()
	-- The pane as it stands when the fetch goes out: the column list, so the
	-- pane is never blank while the one round trip it costs is in flight.
	skeleton = pane()
end
lines = support.sync(function(done)
	preview.render("tables", context, { value = "users" }, bufnr, done)
end)
on_details_called = nil
check("the columns go up first", skeleton ~= nil and #skeleton, 1)
check("as a plain list, not a definition", (skeleton or { "" })[1]:find("^id%s+bigint") ~= nil, true)
check("then the definition replaces them", lines, detail.render(connection, context, "users", DETAILS))
check("and that took one round trip", asked.details, 1)

support.describe("preview: an answer for a row the cursor has left")
ready_answer, details_answer = nil, DETAILS
asked = { ready = 0, columns = 0, details = 0 }
-- Start the slow path for one table and immediately draw another, the way
-- holding j down does. The first table's debounced fetch must never go out.
preview.render("tables", context, { value = "orders" }, bufnr, nil)
ready_answer = DETAILS
local second = support.sync(function(done)
	preview.render("tables", context, { value = "users" }, bufnr, done)
end)
check("the second table is drawn", second, detail.render(connection, context, "users", DETAILS))
vim.wait(120, function()
	return false
end)
check("and the first one's fetch was dropped rather than queued", asked.details, 0)
check("so the pane still holds the row the cursor is on", pane(), second)

support.describe("preview: a level that is not a table")
check("a column shows its type", support
	.sync(function(done)
		preview.render(
			"columns",
			context,
			{ value = "email", column = { name = "email", type = "text", nullable = false } },
			bufnr,
			done
		)
	end)[2]
	:find("text") ~= nil, true)

support.describe("preview: a schema is drawn as what is in it")

local icons = require("neogrip.icons")
local store = require("neogrip.schema.store")

-- The listing comes out of the snapshot on disk, which is the only thing that
-- knows what is in a schema before you walk into it, and it is drawn by the
-- renderer the neogrip://schema document uses, so resting on a row and opening it
-- cannot describe the schema two different ways.
store.save(connection, context.catalog, {
	product = "fixture",
	schemas = {
		{
			name = "public",
			tables = {
				{ name = "users", kind = "table", columns = { { name = "id" }, { name = "email" } } },
				{ name = "orders", kind = "table", columns = { { name = "id" } } },
				{
					name = "active_users",
					kind = "view",
					columns = { { name = "id" }, { name = "email" }, { name = "seen" } },
				},
			},
		},
	},
})

--- One listed table, as the three things the line says about it. Read back
--- rather than spelled out, because the name column is as wide as the widest
--- name in the schema and that is the fixture's business, not the test's.
local function listed_table(line)
	local icon, name, count = tostring(line):match("^%-%-   (%S+) (%S+)%s+(.+)$")
	return { icon = icon, name = name, count = count }
end

asked = { ready = 0, columns = 0, details = 0 }
local listed = nil
preview.render("schemas", context, { value = "public" }, bufnr, function(drawn)
	listed = drawn
end)
check("a swept schema is drawn without waiting on anyone", listed ~= nil, true)
check("the header counts what is in it, by kind", listed[1], '-- "public": 2 tables, 1 view')
check("a table is listed with the table icon and how wide it is", listed_table(listed[3]), {
	icon = icons.table,
	name = "users",
	count = "2 columns",
})
check("one column reads as one column", listed_table(listed[4]), {
	icon = icons.table,
	name = "orders",
	count = "1 column",
})
check("a view gets the branch icon, so the pane says which is which", listed_table(listed[5]), {
	icon = icons.branch,
	name = "active_users",
	count = "3 columns",
})
check("the buffer holds the listing", pane(), listed)
check("and the server was asked for none of it", { asked.ready, asked.columns, asked.details }, { 0, 0, 0 })

-- Nothing swept for this one. Resting here warms the level below anyway, and
-- that warm-up asks exactly the question the listing needs, so the listing is
-- drawn from its answer rather than asking for the same thing twice.
local real_tables = schema.tables
local warmed = 0
schema.tables = function(_, _, _, callback)
	warmed = warmed + 1
	callback({ { name = "arrivals", kind = "table", columns = { { name = "id" } } } }, nil)
end

local warm_lines = nil
preview.render("schemas", context, { value = "unswept" }, bufnr, function(drawn)
	warm_lines = drawn
end)
check("with nothing swept the pane says it is reading rather than sitting blank", pane(), {
	"-- (reading the schema...)",
})
check("and nothing has gone out yet, because the cursor may still be moving", warmed, 0)

-- Bounded, so a warm-up that never answers fails the check rather than
-- hanging: the debounce this file configured is 20ms.
vim.wait(500, function()
	return warm_lines ~= nil
end, 5)
check("once the cursor settles the warm-up goes out, once", warmed, 1)
check("and its own answer is what the listing is drawn from", warm_lines, {
	'-- "unswept": 1 table',
	"--",
	("--   %s arrivals  1 column"):format(icons.table),
})
schema.tables = real_tables

support.describe("preview: the row that walks back out")

ready_answer = DETAILS
local redrawn = nil
preview.render("tables", context, { value = "users" }, bufnr, function(drawn)
	redrawn = drawn
end)
check("a table is drawn from what the snapshot already holds", redrawn ~= nil, true)
-- language.add returns false rather than raising when the parser is absent,
-- so the guard has to read the result, not just survive the call.
local parser_ok, parser_added = pcall(vim.treesitter.language.add, "sql")
if parser_ok and parser_added then
	check("and highlighted as the SQL it is", vim.treesitter.highlighter.active[bufnr] ~= nil, true)
else
	support.note("sql treesitter parser not installed; the highlight check is skipped")
end

asked = { ready = 0, columns = 0, details = 0 }
local back = nil
preview.render("tables", context, { parent = true, text = ".. Schemas" }, bufnr, function(drawn)
	back = drawn
end)
check("the row above the list finishes with the one line naming where it goes", back, { ".. Schemas" })
check("which is what the pane is left holding", pane(), { ".. Schemas" })
-- Asking about it would send ".." to the catalog as a table name and spend a
-- round trip on an error comment.
check("the catalog was asked nothing about it", { asked.ready, asked.columns, asked.details }, { 0, 0, 0 })
check("and the table's highlighting came off with it", vim.treesitter.highlighter.active[bufnr], nil)

local snapshot_path = store.path(connection, context.catalog)
store.clear(connection)
check("the fixture snapshot is deleted again", vim.fn.filereadable(snapshot_path), 0)

schema.details_ready, schema.columns = saved.details_ready, saved.columns
schema.details, schema.sample = saved.details, saved.sample
vim.g.db_config.schema_warm_debounce_ms = nil
config.reload()
pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
