-- Which database object the cursor is on, answered out of a swept catalog on
-- disk: no server, no Java process and no window. What is worth pinning down
-- here is the scope. A name is read against the statement it sits in, so an
-- alias bound in the statement above means nothing here -- which is exactly
-- what the whole-buffer regex in db/completion.lua got wrong.
local support = require("tests.support")
local check = support.check
local connections = require("neogrip.connections")
local identifier = require("neogrip.sql.identifier")
local store = require("neogrip.schema.store")

-- An id no real connection can have: the snapshot below is written next to a
-- developer's own and deleted again at the end.
local connection = connections.register({
	id = "__test_identifier__",
	name = "identifier test",
	driver = "postgres",
	database = "appdb",
	password_source = { kind = "none" },
	options = {},
	scope = "global",
})
local CATALOG = "appdb"

store.save(connection, CATALOG, {
	product = "fixture",
	schemas = {
		{
			name = "sales",
			tables = {
				{
					name = "customers",
					kind = "table",
					details = true,
					primary_key = { "id" },
					columns = {
						{ name = "id", type = "bigint", nullable = false, is_pk = true },
						{ name = "email", type = "text", nullable = false },
						{ name = "created_at", type = "timestamptz", nullable = true },
					},
				},
				{
					name = "orders",
					kind = "table",
					details = true,
					primary_key = { "id" },
					columns = {
						{ name = "id", type = "bigint", nullable = false, is_pk = true },
						{ name = "customer_id", type = "bigint", nullable = false },
						{ name = "total", type = "numeric", nullable = true },
					},
				},
				{
					name = "active_customers",
					kind = "view",
					columns = { { name = "id", type = "bigint" }, { name = "email", type = "text" } },
				},
			},
		},
		{
			name = "audit",
			tables = {
				{
					name = "events",
					kind = "table",
					details = true,
					columns = {
						{ name = "id", type = "bigint", nullable = false },
						{ name = "note", type = "text", nullable = true },
					},
				},
			},
		},
	},
})

-- Ten statements in the one buffer, which is the point of the file: every
-- alias below is bound in one of them and has to mean nothing in the others.
local LINES = {
	"-- customers, as a word in a comment",
	"select email, c.email from sales.customers c where c.id > 0;",
	"select o.total from sales.customers as c join sales.orders o on o.customer_id = c.id;",
	"select e.note from sales.customers c join audit.events as e on e.id = c.id;",
	"select c.id from audit.events;",
	"select * from customers;",
	"select * from sales;",
	"select sales.customers.email from sales.customers;",
	"select * from sales.active_customers;",
	"select note from audit.events where note = 'customers';",
}

local bufnr = vim.api.nvim_create_buf(false, true)
vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, LINES)
-- Bound through the buffer variable rather than db.resolve.bind, which would
-- write the binding into a developer's own state directory and start a
-- language server for it.
vim.b[bufnr].neogrip_connection = connection.id
vim.b[bufnr].neogrip_dialect = "postgres"

--- The 0-based column where `needle` starts, so a test names the text it means
--- rather than counting characters.
local function column_of(line, needle)
	local at = LINES[line]:find(needle, 1, true)
	if not at then
		error(("no %q on line %d"):format(needle, line))
	end
	return at - 1
end

--- An answer reduced to the four fields that say which object it is.
local function flat(found)
	if not found then
		return nil
	end
	return { kind = found.kind, schema = found.schema, table = found.table, column = found.column }
end

--- What the identifier at a position resolves to. The position is passed in
--- rather than set in a window, so none of this depends on a window existing.
--- @param offset integer|nil how far into `needle` the cursor sits
local function at(line, needle, offset)
	local col = column_of(line, needle) + (offset or 0)
	return flat(identifier.at_cursor(bufnr, { line = line, col = col }))
end

support.describe("identifier: a name standing on its own")

check("a bare table name is found wherever the sweep put it", at(6, "customers"), {
	kind = "table",
	schema = "sales",
	table = "customers",
})
check("a bare schema name is a schema", at(7, "sales"), { kind = "schema", schema = "sales" })
check("a view is a name like any other", at(9, "active_customers"), {
	kind = "table",
	schema = "sales",
	table = "active_customers",
})
check("a bare column is resolved against the tables the statement names", at(2, "email"), {
	kind = "column",
	schema = "sales",
	table = "customers",
	column = "email",
})
check("a keyword names no object", at(6, "select"), nil)
check("not even the one the scanner itself reads for", at(6, "from"), nil)

local answer = identifier.at_cursor(bufnr, { line = 6, col = column_of(6, "customers") })
check("an answer carries the connection it was resolved against", answer.connection.id, connection.id)
check("and the catalog the snapshot was taken for", answer.catalog, CATALOG)

support.describe("identifier: a qualified name")

check("the first half of schema.table is the schema", at(2, "sales.customers"), {
	kind = "schema",
	schema = "sales",
})
check("and the second is the table in it", at(2, "sales.customers", 6), {
	kind = "table",
	schema = "sales",
	table = "customers",
})
check("schema.table.column starts with the schema", at(8, "sales.customers.email"), {
	kind = "schema",
	schema = "sales",
})
check("names the table in the middle", at(8, "customers.email"), {
	kind = "table",
	schema = "sales",
	table = "customers",
})
check("and ends on the column", at(8, "email"), {
	kind = "column",
	schema = "sales",
	table = "customers",
	column = "email",
})

support.describe("identifier: an alias")

check("an alias bound by FROM is the table it stands for", at(2, "c.email"), {
	kind = "table",
	schema = "sales",
	table = "customers",
})
check("and the name after it is that table's column", at(2, "c.email", 2), {
	kind = "column",
	schema = "sales",
	table = "customers",
	column = "email",
})
check("AS is optional, so FROM ... AS c binds the same alias", at(3, "c.id"), {
	kind = "table",
	schema = "sales",
	table = "customers",
})
check("an alias bound by JOIN is a table too", at(3, "o.total"), {
	kind = "table",
	schema = "sales",
	table = "orders",
})
check("spelled with AS or without", at(4, "e.note"), {
	kind = "table",
	schema = "audit",
	table = "events",
})
check("and its columns come from the table it names", at(4, "e.note", 2), {
	kind = "column",
	schema = "audit",
	table = "events",
	column = "note",
})

-- The whole reason this module exists rather than the regex it replaced: "c"
-- is bound to sales.customers three statements up, and a script that joins one
-- table here and another there would otherwise answer with the wrong columns.
check("an alias from another statement does not leak", at(5, "c.id"), nil)
check("nor does the column behind it", at(5, "c.id", 2), nil)

support.describe("identifier: quoting is the buffer's dialect")

--- One line in a buffer of its own dialect. Quoting is a property of the
--- buffer and the catalog is a property of the connection, so the one snapshot
--- answers for every dialect below.
local function in_dialect(dialect, line, needle)
	local scratch = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_buf_set_lines(scratch, 0, -1, false, { line })
	vim.b[scratch].neogrip_connection = connection.id
	vim.b[scratch].neogrip_dialect = dialect
	local found = identifier.at_cursor(scratch, { line = 1, col = line:find(needle, 1, true) - 1 })
	pcall(vim.api.nvim_buf_delete, scratch, { force = true })
	return flat(found)
end

local QUOTED = { kind = "table", schema = "sales", table = "customers" }
local PG = 'select * from "sales"."customers";'
local MY = "select * from `sales`.`customers`;"
local MS = "select * from [sales].[customers];"

check("postgres quotes with double quotes", in_dialect("postgres", PG, '"customers"'), QUOTED)
check("mysql with backticks", in_dialect("mysql", MY, "`customers`"), QUOTED)
check("sql server with brackets", in_dialect("mssql", MS, "[customers]"), QUOTED)
check("and the quoted half of a qualified name is still a schema", in_dialect("mssql", MS, "[sales]"), {
	kind = "schema",
	schema = "sales",
})

-- Another engine's quoting is not quoting here: a backtick opens a string in
-- postgres, and what is inside a string is prose.
check("another engine's quoting reads as a string, not a name", in_dialect("postgres", MY, "customers"), nil)
check("in both directions", in_dialect("mysql", PG, "customers"), nil)

support.describe("identifier: prose is not a name")

check("a word inside a string literal names nothing", at(10, "'customers'", 1), nil)
check("nor does one in a comment", at(1, "customers"), nil)

support.describe("identifier: the extent it reports")

-- The range is what a hover highlights and what a jump measures, so on
-- "c.email" it has to be one half or the other and never both.
local alias_from = column_of(2, "c.email")
local alias = identifier.at_cursor(bufnr, { line = 2, col = alias_from })
check("the range on an alias covers the alias alone", alias.range, {
	line = 2,
	from = alias_from,
	to = alias_from + 1,
})
local column = identifier.at_cursor(bufnr, { line = 2, col = alias_from + 2 })
check("and on the column after the dot, the column alone", column.range, {
	line = 2,
	from = alias_from + 2,
	to = alias_from + 7,
})

support.describe("identifier: with no position given")

-- The one check here that needs a window, because reading the cursor out of
-- one is the fallback being tested.
vim.api.nvim_set_current_buf(bufnr)
vim.api.nvim_win_set_cursor(0, { 6, column_of(6, "customers") })
check("the cursor's own position is read when none is passed", flat(identifier.at_cursor(bufnr)), {
	kind = "table",
	schema = "sales",
	table = "customers",
})

store.clear(connection)
pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
check("the suite leaves no snapshot behind", vim.fn.filereadable(store.path(connection, CATALOG)), 0)

support.describe("identifier: a FROM that binds nothing")

-- Its own buffer, so the line numbers every check above counts on do not move.
-- A statement that builds SQL in a string, or a comment quoting one, has the
-- word FROM in it without binding an alias: read as one, "u" would resolve to
-- the wrong table and the jump would land somewhere plausible and wrong.
local phantom = vim.api.nvim_create_buf(false, true)
vim.b[phantom].neogrip_connection = connection.id
vim.b[phantom].neogrip_dialect = "postgres"

local function binds(statement)
	vim.api.nvim_buf_set_lines(phantom, 0, -1, false, { statement })
	local found = identifier.at_cursor(phantom, { line = 1, col = statement:find("u%.") - 1 })
	return found and found.table or nil
end

check("a real alias still binds", binds("select u.id from orders u"), "orders")
check(
	"a FROM inside a string literal does not",
	binds("select u.id from orders o where o.note = 'from customers u'"),
	nil
)
check("nor one in a line comment", binds("select u.id from orders o -- from customers u"), nil)
check("nor one in a block comment", binds("select u.id from orders o /* from customers u */"), nil)
check(
	"and a doubled quote does not end the literal early",
	binds("select u.id from orders o where o.note = 'it''s from customers u'"),
	nil
)
pcall(vim.api.nvim_buf_delete, phantom, { force = true })
