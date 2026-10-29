-- What the completion source offers, answered entirely from a swept catalog on
-- disk: no cmp, no server, no Java process. The point of these is that the
-- source reads the sweep at all -- it used to ask every question with no
-- catalog and no schema, so it missed the file it was supposed to be instant
-- because of and waited on the server instead.
local support = require("tests.support")
local check = support.check
local completion = require("neogrip.completion")
local connections = require("neogrip.connections")
local resolve = require("neogrip.resolve")
local schema = require("neogrip.schema")
local store = require("neogrip.schema.store")

local connection = connections.register({
	id = "__test_completion__",
	name = "completion test",
	driver = "postgres",
	database = "appdb",
	password_source = { kind = "none" },
	options = {},
	scope = "global",
})

store.save(connection, "appdb", {
	product = "fixture",
	schemas = {
		{
			name = "sales",
			tables = {
				{
					name = "customers",
					kind = "table",
					columns = {
						{ name = "id", type = "bigint", nullable = false, is_pk = true },
						{ name = "email", type = "text", nullable = false },
					},
				},
				{ name = "orders", kind = "table", columns = { { name = "id", type = "bigint" } } },
			},
		},
		{
			name = "audit",
			tables = {
				{ name = "events", kind = "view", columns = { { name = "at", type = "timestamp" } } },
			},
		},
	},
})

local bufnr = vim.api.nvim_create_buf(true, false)
vim.api.nvim_buf_set_name(bufnr, vim.fn.stdpath("state") .. "/db/completion-test.sql")
vim.bo[bufnr].filetype = "sql"
vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "select c.id from sales.customers c join audit.events e" })
vim.api.nvim_set_current_buf(bufnr)
resolve.bind(bufnr, connection.id)

--- The source answers synchronously when the sweep covers the question, which
--- is the whole claim: a callback that never fired would hang this.
local function offered(before_line)
	local items, called = nil, false
	completion.source:complete({ context = { cursor_before_line = before_line } }, function(answer)
		items, called = (answer or {}).items, true
	end)
	return called, items or {}
end

local function labels(items)
	local out = vim.tbl_map(function(item)
		return item.label
	end, items)
	table.sort(out)
	return out
end

support.describe("completion: which schema holds a table")
check(
	"a table is found wherever the sweep put it",
	schema.locate_table(connection, "appdb", "customers"),
	"sales"
)
check("including in a schema nobody configured", schema.locate_table(connection, "appdb", "events"), "audit")
check("and a name that is not a table is not located", schema.locate_table(connection, "appdb", "nope"), nil)

support.describe("completion: tables")
local called, items = offered("select * from ")
check("it answers without waiting on anyone", called, true)
check("offering every table the sweep found, in every schema", labels(items), {
	"customers",
	"events",
	"orders",
})
check(
	"as classes, so cmp sorts them with other types",
	items[1].kind,
	vim.lsp.protocol.CompletionItemKind.Class
)
local detail = vim.tbl_filter(function(item)
	return item.label == "events"
end, items)[1].detail
check("saying what kind it is and where it lives", detail, "view  audit")

support.describe("completion: columns behind an alias")
local columns_called, columns = offered("select c.")
check("it answers synchronously too", columns_called, true)
check("with that table's columns", labels(columns), { "email", "id" })
check("as fields", columns[1].kind, vim.lsp.protocol.CompletionItemKind.Field)
check("carrying the type, which is what you are checking", columns[1].detail ~= "", true)

-- The alias is resolved against the statement, so a table named directly works
-- the same way as one behind an alias.
local direct_called, direct = offered("select customers.")
check("a table named in full needs no alias", direct_called, true)
check("and offers the same columns", labels(direct), { "email", "id" })

store.clear(connection)
schema.invalidate(connection)
resolve.unbind(bufnr)
pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
