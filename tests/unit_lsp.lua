-- The SQL language server, asked directly.
--
-- It runs in this process -- vim.lsp.start takes a function for `cmd`, and
-- db/lsp.lua returns an in-process client from one -- so the server object can
-- be built and questioned with no RPC, no client and no catalog but the
-- fixture below. That is the whole point of these: every answer the server has
-- is a handful of table lookups, and a test of them should be the same.
local support = require("tests.support")
local check = support.check
local connections = require("neogrip.connections")
local detail = require("neogrip.explorer.detail")
local document = require("neogrip.document")
local lsp = require("neogrip.lsp")
local schema = require("neogrip.schema")
local store = require("neogrip.schema.store")

local KIND = vim.lsp.protocol.SymbolKind

-- An id no real connection can have: the snapshot below is written next to a
-- developer's own and deleted again at the end.
local connection = connections.register({
	id = "__test_lsp__",
	name = "lsp test",
	driver = "postgres",
	database = "appdb",
	password_source = { kind = "none" },
	options = {},
	scope = "global",
})
local CATALOG = "appdb"

-- Two keys of sales.orders point at the one table, which is what the
-- references answer has to notice: a neighbour named twice is still one place
-- to go to.
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
					indexes = {},
					foreign_keys = {},
					referenced_by = {
						{
							name = "orders_customer_fk",
							schema = "sales",
							table = "orders",
							columns = { "customer_id" },
							ref_columns = { "id" },
						},
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
					indexes = {},
					foreign_keys = {
						{
							name = "orders_customer_fk",
							schema = "sales",
							table = "customers",
							columns = { "customer_id" },
							ref_columns = { "id" },
						},
						{
							name = "orders_agent_fk",
							schema = "sales",
							table = "customers",
							columns = { "agent_id" },
							ref_columns = { "id" },
						},
					},
					referenced_by = {
						{
							name = "order_items_order_fk",
							schema = "sales",
							table = "order_items",
							columns = { "order_id" },
							ref_columns = { "id" },
						},
					},
				},
				{
					name = "order_items",
					kind = "table",
					columns = { { name = "id", type = "bigint" }, { name = "order_id", type = "bigint" } },
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

-- Three statements, the first of them opening with a comment about itself,
-- which is what the outline has to see past.
local LINES = {
	"-- customers, as a word in a comment",
	"select c.id, c.email, c.nosuch",
	"  from sales.customers c",
	" where c.email <> 'orders';",
	"select note from audit.events;",
	"select customer_id from sales.orders;",
}

local bufnr = vim.api.nvim_create_buf(true, false)
vim.api.nvim_buf_set_name(bufnr, vim.fn.stdpath("state") .. "/db/lsp-test.sql")
vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, LINES)
-- Bound through the buffer variable rather than db.resolve.bind, which would
-- write the binding into a developer's own state directory.
vim.b[bufnr].neogrip_connection = connection.id
local URI = vim.uri_from_bufnr(bufnr)

-- The definition of a column is a line of its table's rendered document, and
-- rendering one appends the server's own DDL when the driver has it. That is a
-- round trip, which here would start a Java process, and no answer below reads
-- it.
local real_ddl = schema.native_ddl
schema.native_ddl = function() end

-- The server object is what M.start hands to vim.lsp.start as `cmd`, and
-- nothing exports it. Stubbing that one call is how to reach it without a real
-- client attaching to the buffer and asking these questions of its own.
local captured = nil
local real_start = vim.lsp.start
vim.lsp.start = function(config)
	captured = config
	return 1
end
local client_id = lsp.start(bufnr)
vim.lsp.start = real_start

-- Dispatchers are how a client is told about what it did not ask for. Nothing
-- here notifies, exits or fails, so they only have to exist.
local server = captured.cmd({
	notification = function() end,
	server_request = function() end,
	on_exit = function() end,
	on_error = function() end,
})

--- One request, answered.
---
--- Every reply is scheduled, even one the process already has, so an answer
--- still has to come back through the event loop. The wait is bounded, so a
--- server that never answers fails the check rather than hanging the suite.
--- @param settle integer|nil keep listening this long instead of stopping at
--- the first reply, for a request whose second answer would arrive late
--- @return integer calls, any reply, any failure
local function ask(method, params, settle)
	local calls, reply, failure = 0, nil, nil
	server.request(method, params, function(err, result)
		calls, reply, failure = calls + 1, result, err
	end)
	vim.wait(settle or 2000, function()
		return calls > 0 and not settle
	end, 5)
	return calls, reply, failure
end

--- A position in the test buffer, as the protocol spells one.
--- @param offset integer|nil how far into `needle` the cursor sits
local function at(line, needle, offset)
	local column = LINES[line]:find(needle, 1, true)
	if not column then
		error(("no %q on line %d"):format(needle, line))
	end
	return {
		textDocument = { uri = URI },
		position = { line = line - 1, character = column - 1 + (offset or 0) },
	}
end

local function markdown(reply)
	return reply and reply.contents and reply.contents.value or ""
end

local function mentions(text, want)
	return text:find(want, 1, true) ~= nil
end

local function at_line(line)
	return { start = { line = line, character = 0 }, ["end"] = { line = line, character = 0 } }
end

support.describe("lsp: what the server says it can do")

check("one client per connection, named after it", captured.name, "neogrip:__test_lsp__")
check("running in this process, which is what a function for cmd means", type(captured.cmd), "function")
check("with no root directory, because a catalog is not a tree of files", captured.root_dir, nil)
check("and the client it started is handed back", client_id, 1)

local calls, initialized = ask("initialize", {})
check("initialize is answered exactly once", calls, 1)

local advertised = initialized.capabilities
-- Read as the set of providers rather than compared whole: the server answers
-- with its own capabilities table, and a client that attaches normalizes the
-- table it is handed in place, so any client started earlier in the suite
-- leaves a textDocumentSync in it.
local providers = {}
for name in pairs(advertised) do
	if name:match("Provider$") then
		providers[#providers + 1] = name
	end
end
table.sort(providers)
check("exactly five answers are advertised", providers, {
	"definitionProvider",
	"documentSymbolProvider",
	"hoverProvider",
	"referencesProvider",
	"workspaceSymbolProvider",
})
-- Both absences are load-bearing, so they are said again on their own:
-- semantic tokens paint at priority 125, over the dialect layer
-- db/dialect.lua draws at 110, and completion would offer every table twice
-- next to the cmp source.
check("no semantic tokens, which would paint over the dialect layer", advertised.semanticTokensProvider, nil)
check("and no completion, which the cmp source already offers", advertised.completionProvider, nil)
check("positions are measured in bytes, as these modules do", advertised.positionEncoding, "utf-8")
check("the server names itself", initialized.serverInfo, { name = "neogrip" })

support.describe("lsp: where a name is defined")

local table_calls, table_at = ask("textDocument/definition", at(3, "customers"))
check("a table is answered exactly once", table_calls, 1)
check("with its own document", table_at, {
	uri = document.table_uri(connection, CATALOG, "sales", "customers"),
	range = at_line(0),
})

local schema_calls, schema_at = ask("textDocument/definition", at(5, "audit"))
check("a schema is answered exactly once", schema_calls, 1)
check("with the schema document", schema_at, {
	uri = document.schema_uri(connection, CATALOG, "audit"),
	range = at_line(0),
})

-- Read off the rendered text rather than counted, which is what the server
-- does: the renderer is free to leave a column out, and a jump that lands a
-- line off is worse than one that does not land at all.
local rendered = detail.render(connection, {
	connection = connection,
	catalog = CATALOG,
	schema = "sales",
}, "customers", store.details(connection, CATALOG, "sales", "customers"))
local email_line = document.column_line(rendered, "email")
check("the column has a line in its table's definition", email_line ~= nil, true)

-- Waited out past the 250ms deadline the handler arms before it renders: a
-- server that answered from both would break the client, and a check that only
-- read the reply would never see it.
local column_calls, column_at = ask("textDocument/definition", at(2, "c.email", 2), 400)
check("a column is answered exactly once, deadline and render both", column_calls, 1)
check("on the line of its table's definition it is defined on", column_at, {
	uri = document.table_uri(connection, CATALOG, "sales", "customers"),
	range = at_line(email_line - 1),
})

local comment_calls, comment_at, comment_err = ask("textDocument/definition", at(1, "customers"))
check("a word in a comment is answered exactly once", comment_calls, 1)
check("with nothing, because prose names no object", comment_at, nil)
check("and no error, which a client would read as a broken server", comment_err, nil)

support.describe("lsp: what a name is")

local key_calls, key_hover = ask("textDocument/hover", at(2, "c.id", 2))
check("a column is answered exactly once", key_calls, 1)
check("with the type you are checking", mentions(markdown(key_hover), "`bigint`"), true)
check("whether it can be null", mentions(markdown(key_hover), "not null"), true)
check("and whether it is the key", mentions(markdown(key_hover), "primary key"), true)
check("over the name under the cursor and not the alias before it", key_hover.range, {
	start = { line = 1, character = 9 },
	["end"] = { line = 1, character = 11 },
})

local fk_calls, fk_hover = ask("textDocument/hover", at(6, "customer_id"))
check("a column with a key on it is answered exactly once", fk_calls, 1)
check("saying what it points at", mentions(markdown(fk_hover), "references `sales.customers.id`"), true)

local table_hover_calls, table_hover = ask("textDocument/hover", at(3, "customers"))
check("a table is answered exactly once", table_hover_calls, 1)
check("saying how wide it is", mentions(markdown(table_hover), "3 columns"), true)
check("and what points back at it", mentions(markdown(table_hover), "Referenced by (1)"), true)

local missing_calls, missing_hover = ask("textDocument/hover", at(2, "c.nosuch", 2))
check("a column the sweep never saw is answered exactly once", missing_calls, 1)
check(
	"and said to be missing rather than raising",
	markdown(missing_hover),
	table.concat({
		"**sales.customers.nosuch**",
		"",
		"No such column of sales.customers.",
	}, "\n")
)

local keyword_calls, keyword_hover = ask("textDocument/hover", at(5, "select"))
check("a keyword is answered exactly once", keyword_calls, 1)
check("with nothing to say about it", keyword_hover, nil)

support.describe("lsp: the tables a table is tied to")

local ref_calls, references = ask("textDocument/references", at(6, "orders"))
check("references are answered exactly once", ref_calls, 1)
check("naming what the table points at and what points back at it", references, {
	{ uri = document.table_uri(connection, CATALOG, "sales", "customers"), range = at_line(0) },
	{ uri = document.table_uri(connection, CATALOG, "sales", "order_items"), range = at_line(0) },
})
check("a neighbour named by two keys is one place to go to", #references, 2)

support.describe("lsp: the outline of a script")

local outline_calls, symbols = ask("textDocument/documentSymbol", { textDocument = { uri = URI } })
check("the outline is answered exactly once", outline_calls, 1)
check("one symbol per statement", #symbols, 3)
check(
	"each named after its first line that is not a comment",
	vim.tbl_map(function(symbol)
		return symbol.name
	end, symbols),
	{
		"select c.id, c.email, c.nosuch",
		"select note from audit.events",
		"select customer_id from sales.orders",
	}
)
check("a statement is an object", symbols[1].kind, KIND.Object)
check("its range covers the whole statement, comment and all", symbols[1].range, {
	start = { line = 0, character = 0 },
	["end"] = { line = 3, character = #LINES[4] },
})
check("and a one-line statement covers its one line", symbols[3].range, {
	start = { line = 5, character = 0 },
	["end"] = { line = 5, character = #LINES[6] },
})

support.describe("lsp: finding an object by name")

local search_calls, found = ask("workspace/symbol", { query = "customer" })
check("a search is answered exactly once", search_calls, 1)
check(
	"matching the query anywhere in a name, tables before columns",
	vim.tbl_map(function(symbol)
		return symbol.name
	end, found),
	{ "customers", "active_customers", "customer_id" }
)
check("a table is a class", found[1].kind, KIND.Class)
check("a view is an interface, so the picker shows which is which", found[2].kind, KIND.Interface)
check("a column is a field", found[3].kind, KIND.Field)
check("each saying where it lives", { found[1].containerName, found[3].containerName }, {
	"sales",
	"sales.orders",
})
check("and pointing at the document of the table it is in", found[3].location, {
	uri = document.table_uri(connection, CATALOG, "sales", "orders"),
	range = at_line(0),
})

local empty_calls, nothing = ask("workspace/symbol", { query = "nosuchthing" })
check("a query that matches nothing is answered exactly once", empty_calls, 1)
check("with nothing", nothing, nil)

support.describe("lsp: a method it never advertised")

-- Some clients ask anyway, and an empty answer is what the protocol has for
-- "nothing here" -- an error would be read as a broken server.
local unknown_calls, unknown, unknown_err = ask("textDocument/formatting", { textDocument = { uri = URI } })
check("it is answered exactly once", unknown_calls, 1)
check("with nothing", unknown, nil)
check("and without erroring", unknown_err, nil)

schema.native_ddl = real_ddl
check("the schema module is left as it was found", schema.native_ddl == real_ddl, true)
check("and so is vim.lsp", vim.lsp.start == real_start, true)

store.clear(connection)
pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
-- vim.uri_to_bufnr made a buffer for the document the column answer points at,
-- the way it would for a client about to jump there.
for _, buffer in ipairs(vim.api.nvim_list_bufs()) do
	if vim.startswith(vim.api.nvim_buf_get_name(buffer), "neogrip://") then
		pcall(vim.api.nvim_buf_delete, buffer, { force = true })
	end
end
check("the suite leaves no snapshot behind", vim.fn.filereadable(store.path(connection, CATALOG)), 0)
