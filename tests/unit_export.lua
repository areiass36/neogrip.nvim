-- The DDL export: identity, enumeration, composition per engine, ordering,
-- degenerate input and the caches left untouched. gripd.request is stubbed
-- with canned catalog answers, the way unit_tabs.lua stubs runner.run;
-- nothing here reaches a network or a server.
local support = require("tests.support")
local check = support.check
local connections = require("neogrip.connections")
local export = require("neogrip.catalog.export")
local gripd = require("neogrip.gripd")
local paths = require("neogrip.paths")
local schema = require("neogrip.catalog")
local store = require("neogrip.catalog.store")
local tree = require("neogrip.catalog.tree")

local saved = { request = gripd.request, is_connected_to = gripd.is_connected_to }

local pending = {}
local log = {}

gripd.is_connected_to = function()
	return true
end
gripd.request = function(_, method, params, callback)
	pending[#pending + 1] = { method = method, params = params, callback = callback }
	log[#log + 1] = { method = method, params = params }
end

--- Drain the queue against `handlers[method](params) -> result, err`: the
--- export issues its next request from inside the callback, so the loop runs
--- until it stops asking.
local function serve(handlers)
	local guard = 0
	while #pending > 0 do
		guard = guard + 1
		if guard > 500 then
			error("the export never stopped asking")
		end
		local item = table.remove(pending, 1)
		local handler = handlers[item.method]
		if not handler then
			error("unexpected request " .. item.method)
		end
		local result, err = handler(item.params)
		item.callback(result, err)
	end
end

--- One export, served to the end; returns the callback calls and the lines.
local function run(target, handlers)
	pending, log = {}, {}
	local path = vim.fn.tempname()
	local calls = {}
	export.script(target, { path = path }, function(summary, err)
		calls[#calls + 1] = { summary = summary, err = err }
	end)
	serve(handlers)
	local lines = vim.fn.filereadable(path) == 1 and vim.fn.readfile(path) or nil
	pcall(vim.fn.delete, path)
	return { calls = calls, lines = lines }
end

local function text_of(result)
	return table.concat(result.lines or {}, "\n")
end

local function count_of(text, needle)
	local total, position = 0, 1
	while true do
		local found = text:find(needle, position, true)
		if not found then
			return total
		end
		total = total + 1
		position = found + #needle
	end
end

local function methods_asked()
	local seen = {}
	for _, entry in ipairs(log) do
		seen[entry.method] = (seen[entry.method] or 0) + 1
	end
	return seen
end

--- Every non-comment character belongs to a `;`-terminated statement.
local function statements_only(lines)
	local kept = {}
	for _, line in ipairs(lines or {}) do
		local stripped = line:gsub("%s%-%-.*$", "")
		if not stripped:match("^%s*%-%-") and not stripped:match("^%s*$") then
			kept[#kept + 1] = stripped
		end
	end
	local rest = table.concat(kept, " "):gsub("[^;]*;", ""):gsub("%s+", "")
	return rest == ""
end

local pg = connections.register({ id = "xp_pg", driver = "postgres", database = "app" })
connections.register({ id = "xp_pgx", driver = "postgres" })
connections.register({ id = "xp_myd", driver = "mysql", database = "app" })
connections.register({ id = "xp_mariad", driver = "mariadb", database = "app" })
connections.register({ id = "xp_lite", driver = "sqlite", file = "x.db" })
connections.register({ id = "xp_duck", driver = "duckdb", file = "x.duckdb" })
connections.register({ id = "xp_ms", driver = "mssql", database = "app" })
connections.register({ id = "xp_tri", driver = "trino", catalog = "hive" })
connections.register({ id = "xp_mongo", driver = "mongodb", database = "shop" })

local function details_of(rows, extra)
	local built = { rows = rows }
	for key, value in pairs(extra or {}) do
		built[key] = value
	end
	return built
end

local function fk(name, column, target, target_schema)
	return {
		name = name,
		columns = { column },
		ref_columns = { "id" },
		table = target,
		schema = target_schema,
	}
end

local ID_ROW = { { name = "id", type = "integer", nullable = false, position = 1 } }

support.describe("export: a node id round-trips into a ref")

local function roundtrip(name, ref)
	check(name, { tree.ref_of(tree.id(ref)) }, { ref })
end

roundtrip("a server", { server = "xp_pgx" })
roundtrip("an instance", { server = "xp_pgx", instance = "other" })
roundtrip("a namespace", { server = "xp_pgx", instance = "other", namespace = "public" })
roundtrip("a set", { server = "xp_pgx", instance = "other", namespace = "public", set = "users" })
roundtrip("a set under a pinned database", { server = "xp_pg", namespace = "public", set = "users" })

for _, name in ipairs({ "a/b", "100%", 'my "table"', "with space", "日本語", "🎉emoji", "#3" }) do
	roundtrip("the name " .. name, { server = "xp_pg", namespace = "public", set = name })
end

check("a search ref carrying the pinned catalog", {
	tree.ref_of(tree.id({ server = "xp_pg", instance = "app", namespace = "public", set = "users" })),
}, { { server = "xp_pg", instance = "app", namespace = "public", set = "users" } })

support.describe("export: what is refused, before any request goes out")

local function refused(target)
	pending, log = {}, {}
	local got
	export.script(target, { path = vim.fn.tempname() }, function(summary, err)
		got = { summary = summary, err = err }
	end)
	return got and got.err and got.err.message or "not refused", #log
end

check(
	"a column id has no definition",
	{ refused(tree.id({ server = "xp_pg", namespace = "public", set = "users", attribute = "id" })) },
	{ "a column has no definition to export", 0 }
)
check(
	"a row id has no definition",
	{ refused(tree.id({ server = "xp_pg", namespace = "public", set = "users", object = 3 })) },
	{ "a row has no definition to export", 0 }
)
local server_reason, server_asked = refused(tree.id({ server = "xp_pgx" }))
check(
	"a server id is refused because instances reconnect",
	{ server_reason:find("reopening", 1, true) ~= nil, server_asked },
	{ true, 0 }
)
check("an id naming no connection", { refused("nope/x") }, { "no connection named nope", 0 })

support.describe("export: the namespace listing is paged and followed to done")

local function two_pages(params)
	if params.after == nil then
		return { rows = { { name = "alpha", kind = "table" } }, truncated = true }
	end
	return { rows = { { name = "beta", kind = "table" } }, truncated = false }
end
local plain_details = function()
	return details_of(ID_ROW, { primary_key = { "id" } })
end
local no_native = function()
	return { ddl = "" }
end

local paged = run({ server = "xp_pg", namespace = "public" }, {
	["catalog/tables"] = two_pages,
	["catalog/details"] = plain_details,
	["catalog/nativeDdl"] = no_native,
})
local paged_text = text_of(paged)
check("both pages are exported", {
	count_of(paged_text, 'CREATE TABLE "public"."alpha"'),
	count_of(paged_text, 'CREATE TABLE "public"."beta"'),
}, { 1, 1 })
check(
	"the second request resumed after the first page's last name",
	{ log[2].method, log[2].params.after },
	{ "catalog/tables", "alpha" }
)
check("the callback fired exactly once, with the counts", {
	#paged.calls,
	paged.calls[1].summary.tables,
	paged.calls[1].summary.views,
	paged.calls[1].err,
}, { 1, 2, 0 })

local empty = run({ server = "xp_pg", namespace = "public" }, {
	["catalog/tables"] = function()
		return { rows = {}, truncated = false }
	end,
})
check("an empty namespace is a header and a comment, never an empty script", empty.lines, {
	"-- neogrip export: xp_pg/public",
	"-- nothing to export: no sets reported.",
})

local vanished = run({ server = "xp_pg", namespace = "public" }, {
	["catalog/tables"] = function()
		return { rows = { { name = "ghost", kind = "table" }, { name = "solid", kind = "table" } } }
	end,
	["catalog/details"] = function(params)
		if params.table == "ghost" then
			return nil, { message = "relation does not exist" }
		end
		return plain_details()
	end,
	["catalog/nativeDdl"] = no_native,
})
check("a vanished set is skipped with a comment, not an error", {
	count_of(text_of(vanished), '-- "public"."ghost": skipped (relation does not exist)'),
	vanished.calls[1].err == nil,
	vanished.calls[1].summary.tables,
	vanished.calls[1].summary.skipped,
}, { 1, true, 1, 1 })

support.describe("export: a cancel stops the enumeration")

pending, log = {}, {}
local cancel_calls = {}
local cancel_handle = export.script(
	{ server = "xp_pg", namespace = "public" },
	{ path = vim.fn.tempname() },
	function(summary, err)
		cancel_calls[#cancel_calls + 1] = { summary = summary, err = err }
	end
)
local first_page = table.remove(pending, 1)
first_page.callback({ rows = { { name = "alpha", kind = "table" } }, truncated = true }, nil)
cancel_handle.cancel()
local in_flight = table.remove(pending, 1)
in_flight.callback({ rows = { { name = "beta", kind = "table" } }, truncated = false }, nil)
check("no further request after the cancel", #pending, 0)
check(
	"the callback fired exactly once, with the cancel error",
	{ #cancel_calls, cancel_calls[1].err.message },
	{ 1, "export cancelled" }
)

support.describe("export: each kind renders what it has (ADR-0036)")

local view_with_text = run({ server = "xp_myd" }, {
	["catalog/tables"] = function()
		return { rows = { { name = "v", kind = "view" } } }
	end,
	["catalog/nativeDdl"] = function()
		return { ddl = "CREATE VIEW `v` AS select 1" }
	end,
})
check("a view carries the engine's own text, terminated", {
	count_of(text_of(view_with_text), "CREATE VIEW `v` AS select 1;"),
	view_with_text.calls[1].summary.views,
}, { 1, 1 })

local view_without = run({ server = "xp_duck" }, {
	["catalog/schemas"] = function()
		return { rows = { { name = "main" } } }
	end,
	["catalog/tables"] = function()
		return { rows = { { name = "v", kind = "view" } } }
	end,
})
check("a view the engine cannot describe is a comment", {
	count_of(text_of(view_without), '-- view "main"."v": the engine does not hand back its definition.'),
	methods_asked()["catalog/nativeDdl"] == nil,
}, { 1, true })

local collection = run({ server = "xp_mongo" }, {
	["catalog/tables"] = function()
		return { rows = { { name = "events", kind = "collection" } } }
	end,
})
check("a collection is a comment: its fields are sampled, not declared", {
	count_of(text_of(collection), "-- events: a collection has no DDL"),
	methods_asked()["catalog/details"] == nil,
	methods_asked()["catalog/columns"] == nil,
	collection.calls[1].summary.collections,
}, { 1, true, true, 1 })

support.describe("export: composition follows the engine's native shape")

local pg_native = table.concat({
	'ALTER TABLE "public"."t" ADD CONSTRAINT "t_pkey" PRIMARY KEY (id);',
	'ALTER TABLE "public"."t" ADD CONSTRAINT "t_positive" CHECK ((id > 0));',
	'CREATE INDEX "t_name_idx" ON "public"."t" (name);',
	"",
}, "\n")
local composed_pg = run({ server = "xp_pg", namespace = "public" }, {
	["catalog/tables"] = function()
		return { rows = { { name = "t", kind = "table" } } }
	end,
	["catalog/details"] = plain_details,
	["catalog/nativeDdl"] = function()
		return { ddl = pg_native }
	end,
})
local pg_text = text_of(composed_pg)
check("postgres: the rendered table plus the native fragments", {
	count_of(pg_text, 'CREATE TABLE "public"."t"'),
	count_of(pg_text, "ALTER TABLE"),
	count_of(pg_text, "CREATE INDEX"),
}, { 1, 2, 1 })
check("postgres: the CHECK and the keys exist only in the native half", {
	count_of(pg_text, "CHECK"),
	count_of(pg_text, "PRIMARY KEY"),
}, { 1, 1 })
check("postgres: only statements and comments", statements_only(composed_pg.lines), true)

for _, engine in ipairs({
	{ id = "xp_myd", native = "CREATE TABLE `t` (\n  `id` int NOT NULL\n)" },
	{ id = "xp_mariad", native = "CREATE TABLE `t` (\n  `id` int NOT NULL\n)" },
	{ id = "xp_lite", native = "CREATE TABLE t (id INTEGER NOT NULL, CHECK (id > 0))" },
}) do
	local composed = run({ server = engine.id }, {
		["catalog/tables"] = function()
			return { rows = { { name = "t", kind = "table" } } }
		end,
		["catalog/details"] = plain_details,
		["catalog/nativeDdl"] = function()
			return { ddl = engine.native }
		end,
	})
	local composed_text = text_of(composed)
	check(engine.id .. ": the native text stands alone, terminated", {
		count_of(composed_text, "CREATE TABLE"),
		composed_text:find(";", 1, true) ~= nil,
	}, { 1, true })
end

local lite_indexed = run({ server = "xp_lite" }, {
	["catalog/tables"] = function()
		return { rows = { { name = "t", kind = "table" } } }
	end,
	["catalog/details"] = function()
		return details_of({
			{ name = "id", type = "INTEGER", nullable = false, position = 1 },
			{ name = "label", type = "TEXT", position = 2 },
		}, {
			primary_key = { "id" },
			indexes = { { name = "t_label_uq", columns = { "label" }, unique = true } },
		})
	end,
	["catalog/nativeDdl"] = function()
		return { ddl = "CREATE TABLE t (id INTEGER NOT NULL, label TEXT)" }
	end,
})
check("sqlite: the index statement follows the native text it cannot carry", {
	count_of(text_of(lite_indexed), "CREATE TABLE"),
	count_of(text_of(lite_indexed), 'CREATE UNIQUE INDEX "t_label_uq" ON "t" ("label");'),
}, { 1, 1 })

local composed_trino = run({ server = "xp_tri", namespace = "s" }, {
	["catalog/tables"] = function()
		return { rows = { { name = "t", kind = "table" } } }
	end,
	["catalog/details"] = plain_details,
	["catalog/nativeDdl"] = function()
		return { ddl = 'CREATE TABLE "hive"."s"."t" (\n   id integer\n)' }
	end,
})
check("trino: the native text stands alone", count_of(text_of(composed_trino), "CREATE TABLE"), 1)

local rendered_trino = run({ server = "xp_tri", namespace = "s" }, {
	["catalog/tables"] = function()
		return { rows = { { name = "t", kind = "table" } } }
	end,
	["catalog/details"] = plain_details,
	["catalog/nativeDdl"] = no_native,
})
check(
	"trino: the rendered name has three parts (ADR-0039)",
	count_of(text_of(rendered_trino), 'CREATE TABLE "hive"."s"."t"'),
	1
)

local composed_ms = run({ server = "xp_ms", namespace = "dbo" }, {
	["catalog/tables"] = function()
		return { rows = { { name = "t", kind = "table" } } }
	end,
	["catalog/details"] = function()
		return details_of({
			{ name = "id", type = "int", nullable = false, position = 1 },
			{ name = "label", type = "nvarchar(40)", position = 2 },
		}, {
			primary_key = { "id" },
			indexes = { { name = "ix_t_label", columns = { "label" }, unique = true } },
		})
	end,
})
local ms_text = text_of(composed_ms)
check("mssql: rendered only, and the script says CHECKs are not reported", {
	count_of(ms_text, "CREATE TABLE [dbo].[t]"),
	count_of(ms_text, "-- CHECK constraints are not reported"),
	methods_asked()["catalog/nativeDdl"] == nil,
}, { 1, 1, true })
check(
	"mssql: the unique index comes out as its statement",
	count_of(ms_text, "CREATE UNIQUE INDEX [ix_t_label] ON [dbo].[t] ([label]);"),
	1
)

support.describe("export: tables come out dependencies-first")

local function duck_run(tables_by_name)
	local names = vim.tbl_keys(tables_by_name)
	table.sort(names)
	local rows = {}
	for _, name in ipairs(names) do
		rows[#rows + 1] = { name = name, kind = "table" }
	end
	return run({ server = "xp_duck" }, {
		["catalog/schemas"] = function()
			return { rows = { { name = "main" } } }
		end,
		["catalog/tables"] = function()
			return { rows = rows }
		end,
		["catalog/details"] = function(params)
			return tables_by_name[params.table]
		end,
	})
end

local function create_positions(result, names)
	local positions = {}
	for _, name in ipairs(names) do
		for index, line in ipairs(result.lines) do
			if line:find('CREATE TABLE "main"."' .. name .. '"', 1, true) then
				positions[#positions + 1] = index
				break
			end
		end
	end
	return positions
end

local chain = duck_run({
	a = details_of(ID_ROW, { foreign_keys = { fk("fk_ab", "b_id", "b") } }),
	b = details_of(ID_ROW, { foreign_keys = { fk("fk_bc", "c_id", "c") } }),
	c = details_of(ID_ROW, {}),
})
local chain_at = create_positions(chain, { "c", "b", "a" })
check("a chain a -> b -> c comes out c, b, a", {
	#chain_at == 3,
	chain_at[1] < chain_at[2],
	chain_at[2] < chain_at[3],
}, { true, true, true })
check("the chain is only statements and comments", statements_only(chain.lines), true)

local diamond = duck_run({
	a = details_of(ID_ROW, { foreign_keys = { fk("fk_ab", "b_id", "b"), fk("fk_ac", "c_id", "c") } }),
	b = details_of(ID_ROW, { foreign_keys = { fk("fk_bd", "d_id", "d") } }),
	c = details_of(ID_ROW, { foreign_keys = { fk("fk_cd", "d_id", "d") } }),
	d = details_of(ID_ROW, {}),
})
local diamond_at = create_positions(diamond, { "d", "b", "c", "a" })
check("a diamond orders consistently", {
	#diamond_at == 4,
	diamond_at[1] < diamond_at[2],
	diamond_at[2] < diamond_at[3],
	diamond_at[3] < diamond_at[4],
}, { true, true, true, true })
check("and only once per table", count_of(text_of(diamond), "CREATE TABLE"), 4)

local selfref = duck_run({
	s = details_of(ID_ROW, { foreign_keys = { fk("fk_ss", "parent_id", "s") } }),
})
check(
	"a self-reference does not stall the sort",
	{ count_of(text_of(selfref), 'CREATE TABLE "main"."s"'), selfref.calls[1].summary.tables },
	{ 1, 1 }
)

local cycle = duck_run({
	x = details_of(ID_ROW, { foreign_keys = { fk("fk_xy", "y_id", "y") } }),
	y = details_of(ID_ROW, { foreign_keys = { fk("fk_yx", "x_id", "x") } }),
})
local cycle_text = text_of(cycle)
check("a cycle is broken and the script names both ends", {
	count_of(cycle_text, "CREATE TABLE"),
	count_of(cycle_text, '-- cycle broken: "main"."x" references "main"."y", created later in this file.'),
}, { 2, 1 })

local outward = duck_run({
	t = details_of(ID_ROW, { foreign_keys = { fk("fk_out", "other_id", "elsewhere") } }),
})
local outward_text = text_of(outward)
check("a foreign key leaving the export is kept and noted", {
	count_of(outward_text, '-- "main"."t": foreign key references "main"."elsewhere" outside this export.'),
	count_of(outward_text, "FOREIGN KEY"),
}, { 1, 1 })

support.describe("export: degenerate input stays a script")

local bare = duck_run({
	empty = details_of({}, {}),
	odd = details_of({
		{ name = "untyped", position = 1 },
		{ name = 'we"ird', type = "integer", position = 2 },
		{ name = "wide", type = "text", position = 3, default_expr = ("'%s'"):format(("x"):rep(1048576)) },
	}, {}),
})
local bare_text = text_of(bare)
check("zero columns is a comment, not CREATE TABLE ()", {
	count_of(bare_text, "-- empty: no columns reported"),
	count_of(bare_text, 'CREATE TABLE "main"."empty"'),
}, { 1, 0 })
check("a quote in a column name is doubled", count_of(bare_text, '"we""ird"'), 1)
local widest = 0
for _, line in ipairs(bare.lines) do
	widest = math.max(widest, #line)
end
check("a 1 MB default expression survives", widest > 1048576, true)

support.describe("export: the caches are left untouched, and the output is stable")

local cache_file = ("%s/cache/%s.json"):format(paths.state_dir, vim.fn.sha256(pg.id))
pending, log = {}, {}
schema.invalidate(pg)
schema.databases(pg, function() end)
serve({
	["catalog/catalogs"] = function()
		return { rows = { { name = "app" } } }
	end,
})
local cache_before = table.concat(vim.fn.readfile(cache_file), "\n")
local store_before = vim.fn.filereadable(store.path(pg, "app"))

local first = run({ server = "xp_pg", namespace = "public" }, {
	["catalog/tables"] = two_pages,
	["catalog/details"] = plain_details,
	["catalog/nativeDdl"] = no_native,
})
check("the TTL cache is byte-identical after an export", {
	table.concat(vim.fn.readfile(cache_file), "\n") == cache_before,
	vim.fn.filereadable(store.path(pg, "app")),
}, { true, store_before })
schema.invalidate(pg)

local second = run({ server = "xp_pg", namespace = "public" }, {
	["catalog/tables"] = two_pages,
	["catalog/details"] = plain_details,
	["catalog/nativeDdl"] = no_native,
})
check("two exports of one target are byte-identical", first.lines, second.lines)
check("and only statements and comments", statements_only(first.lines), true)

gripd.request = saved.request
gripd.is_connected_to = saved.is_connected_to
