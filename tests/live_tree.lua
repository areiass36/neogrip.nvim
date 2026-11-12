-- The tree against real servers: the declared walk, the three kinds, rows through
-- the cursor, and the decorations a client asks for.
local support = require("tests.support")
local check, note = support.check, support.note

if not support.has_jdk() then
	support.describe("live/tree")
	note("skipped: no JDK available (set NEOGRIP_TEST_JDK)")
	return
end
support.seed_secrets()
local tree = require("neogrip.catalog.tree")
local connections_module = require("neogrip.connections")
local schema = require("neogrip.catalog")
local connections = support.connections()

local function children(node, opts)
	return support.sync(function(done)
		tree.children(node, opts or {}, function(nodes, err)
			done(nodes, err)
		end)
	end, 90000)
end

--- The caller declares which child to walk into: SQL Server answers a dozen
--- permission-only schemas, and Trino's `system` sorts before the catalog with data.
local function walk(connection, wants)
	local shape = tree.shape(connection)
	local node = { level = "server", ref = { server = connection.id } }
	local seen, found = {}, nil
	for _, entry in ipairs(shape.levels) do
		if entry.level ~= "server" and not entry.on_demand then
			local nodes, err = children(node)
			if err then
				return nil, ("%s: %s"):format(entry.level, type(err) == "table" and err.message or err)
			end
			if #nodes == 0 then
				return nil,
					("%s answered nothing (asked under %s)"):format(
						entry.level,
						vim.inspect(node.ref):gsub("%s+", " ")
					)
			end
			seen[entry.level] = nodes
			local wanted = wants[entry.level]
			node = nodes[1]
			for _, candidate in ipairs(nodes) do
				if candidate.name == wanted then
					node = candidate
				end
			end
			if entry.level == "set" then
				found = node
			end
		end
	end
	return { levels = seen, set = found }, nil
end

local ENGINES = {
	{ driver = "postgres", set = "torture", namespace = "public" },
	{ driver = "mysql", set = "torture" },
	{ driver = "mariadb", set = "torture" },
	{ driver = "mssql", set = "torture", namespace = "dbo" },
	{ driver = "sqlite", set = "torture" },
	{ driver = "duckdb", set = "torture", namespace = "main", fixture = true },
	{ driver = "mongodb", set = "orders" },
	-- The read-only tpch catalog: the point is the instance level, not the fixture.
	{ driver = "trino", instance = "tpch", namespace = "tiny", set = "nation" },
}

for _, engine in ipairs(ENGINES) do
	local connection = connections[engine.driver]
	support.describe("live/tree: " .. engine.driver)
	connections_module.register(connection)
	if not support.reachable(connection) then
		note("skipped: nothing listening (tests/containers.sh up)")
	else
		support.ensure_fixture(connection)
		if engine.fixture then
			-- DuckDB's file is a fresh temp path per process.
			support.run(connection, "create or replace table torture as select 1 as id, 'a' as label", {
				mode = "exec",
			})
		end
		schema.invalidate(connection)

		local walked, walk_err = walk(connection, engine)
		check("the walk answers every level it declares", walk_err, nil)
		if walked then
			local chain = {}
			for _, entry in ipairs(tree.shape(connection).levels) do
				chain[#chain + 1] = entry.level
			end
			note("shape: " .. table.concat(chain, " -> "))

			local set = walked.set
			check("a set was reached", set ~= nil, true)
			if set then
				check(
					"and it is one of the three kinds",
					set.kind == "table" or set.kind == "view" or set.kind == "collection",
					true
				)
				check("its id is its path", set.id:find(tostring(connection.id), 1, true), 1)
				check("and its ref carries the whole path", set.ref.server, connection.id)

				local attributes, attributes_err = children(set)
				check("the set has attributes", attributes_err == nil and #attributes > 0, true)
				if attributes and attributes[1] then
					local kind = engine.driver == "mongodb" and "field" or "column"
					check("each one is a " .. kind, attributes[1].kind, kind)
					check("with a type", attributes[1].facts.type ~= nil, true)
					check("and nothing expandable below it", attributes[1].expandable, false)
				end
			end
		end
	end
end

support.describe("live/tree: rows come through the cursor, a page at a time")
do
	local pg = connections.postgres
	if not support.reachable(pg) then
		note("skipped")
	else
		connections_module.register(pg)
		local set = {
			level = "set",
			ref = { server = pg.id, instance = pg.database, namespace = "public", set = "torture" },
		}

		local metadata = children(set)
		check(
			"expanding a set gives its columns, not its rows",
			metadata[1] and metadata[1].level,
			"attribute"
		)

		local page = nil
		local first = support.sync(function(done)
			tree.children(set, {
				objects = true,
				limit = 1,
				on_page = function(continuation)
					page = continuation
				end,
			}, function(nodes, err)
				done(nodes, err)
			end)
		end, 90000)
		check("asked for rows, one page arrives", #first, 1)
		check("and they are rows", first[1].level .. "/" .. first[1].kind, "object/row")
		check("carrying their values", first[1].facts.values.id ~= nil, true)
		check("the page says there is more", page and page.done, false)

		local second = support.sync(function(done)
			tree.children(
				set,
				{ objects = true, limit = 1, hash = page.hash, from = page.from },
				function(nodes, err)
					done(nodes, err)
				end
			)
		end, 90000)
		check("the next page continues the same result", #second, 1)
		check("and numbers the row after the first", second[1].ref.object, 2)

		-- Collapsing a node has to close the cursor it opened.
		local third_handle
		local closed = support.sync(function(done)
			third_handle = tree.children(set, { objects = true, limit = 1 }, function()
				done(true)
			end)
		end, 90000)
		check("a third page answered", closed, true)
		check("and the handle closes it", third_handle.cancel(), true)
	end
end

--- Walks one level a page at a time through the keyset of ADR-0038, asserting
--- every set is seen once, none twice, none missed.
local function page_through(from, limit)
	local seen, pages, after = {}, 0, nil
	local done
	repeat
		local page = nil
		local nodes, err = support.sync(function(finish)
			tree.children(from, {
				limit = limit,
				after = after,
				on_page = function(continuation)
					page = continuation
				end,
			}, function(result, request_err)
				finish(result, request_err)
			end)
		end, 90000)
		if err then
			return nil, type(err) == "table" and err.message or tostring(err)
		end
		pages = pages + 1
		if #nodes > limit then
			return nil, ("a page of %d came back for a limit of %d"):format(#nodes, limit)
		end
		for _, child in ipairs(nodes) do
			seen[child.name] = (seen[child.name] or 0) + 1
		end
		after = page and page.after
		done = page == nil or page.done == true
	until done or pages >= 50
	return { pages = pages, seen = seen, done = done }, nil
end

-- Every engine, paged on the level it has more than one of.
local PAGED = {
	{
		driver = "postgres",
		level = "namespace",
		ref = function(connection)
			return { server = connection.id, instance = connection.database, namespace = "public" }
		end,
		want = "torture",
	},
	-- No namespace level at all, so the walk starts at the server.
	{
		driver = "mysql",
		level = "server",
		ref = function(connection)
			return { server = connection.id }
		end,
		want = "torture",
	},
	{
		driver = "mariadb",
		level = "server",
		ref = function(connection)
			return { server = connection.id }
		end,
		want = "torture",
	},
	{
		driver = "mssql",
		level = "namespace",
		ref = function(connection)
			return { server = connection.id, namespace = "dbo" }
		end,
		want = "torture",
	},
	{
		driver = "sqlite",
		level = "server",
		ref = function(connection)
			return { server = connection.id }
		end,
		want = "torture",
	},
	{
		driver = "duckdb",
		level = "namespace",
		ref = function(connection)
			return { server = connection.id, namespace = "main" }
		end,
		-- Seven tables so a small page size still cuts.
		fixture = true,
		want = "tree_a",
	},
	{
		driver = "mongodb",
		level = "server",
		ref = function(connection)
			return { server = connection.id }
		end,
		want = "orders",
	},
	-- The one fixture with more than one instance: the only live proof that
	-- catalog/catalogs pages at all.
	{
		driver = "trino",
		level = "server",
		ref = function(connection)
			return { server = connection.id }
		end,
		want = "tpch",
	},
}

for _, engine in ipairs(PAGED) do
	local connection = connections[engine.driver]
	support.describe("live/tree: " .. engine.driver .. " pages a level when asked to")
	connections_module.register(connection)
	if not support.reachable(connection) then
		note("skipped: nothing listening (tests/containers.sh up)")
	else
		support.ensure_fixture(connection)
		if engine.fixture then
			for letter in ("abcdefg"):gmatch(".") do
				support.run(
					connection,
					("create table if not exists tree_%s(id int)"):format(letter),
					{ mode = "exec" }
				)
			end
		end
		schema.invalidate(connection)

		-- A page size of one guarantees more than one page on any fixture.
		local limit = engine.fixture and 3 or 1
		local walked, walk_err = page_through({ level = engine.level, ref = engine.ref(connection) }, limit)
		check("paging the level answers", walk_err, nil)
		if walked then
			check("more than one page was needed", walked.pages > 1, true)
			check("and the last one says it is done", walked.done, true)
			check(("%s was seen"):format(engine.want), walked.seen[engine.want] ~= nil, true)
			local twice = {}
			for name, times in pairs(walked.seen) do
				if times > 1 then
					twice[#twice + 1] = name
				end
			end
			-- A name on two pages means the keyset lost its place.
			check("and nothing came back twice", twice, {})
			local total = 0
			for _ in pairs(walked.seen) do
				total = total + 1
			end
			note(("%d over %d pages of %d"):format(total, walked.pages, limit))
		end
	end
end

support.describe("live/tree: the decorations a client asks for")
do
	local pg = connections.postgres
	if not support.reachable(pg) then
		note("skipped")
	else
		connections_module.register(pg)
		local namespace = { server = pg.id, instance = pg.database, namespace = "public" }
		local set_ref = vim.tbl_extend("force", namespace, { set = "torture" })

		support.run(pg, "analyze torture", { mode = "exec" })
		local counts = support.sync(function(done)
			tree.counts(namespace, function(result, err)
				done(result, err)
			end)
		end, 90000)
		check("counts arrive for the namespace", type(counts and counts.torture), "number")

		check("a name is qualified and quoted", tree.qualified_name(set_ref), '"public"."torture"')

		local text = support.sync(function(done)
			tree.statement(set_ref, "select", function(result, err)
				done(result, err)
			end)
		end, 90000)
		check("a select is written for it", text, 'SELECT * FROM "public"."torture"')

		local details = support.sync(function(done)
			tree.details(set_ref, function(result, err)
				done(result, err)
			end)
		end, 90000)
		check(
			"details name the primary key",
			details and details.primary_key and details.primary_key[1],
			"id"
		)

		local found = support.sync(function(done)
			tree.find(namespace, "tortur", function(nodes, err)
				done(nodes, err)
			end)
		end, 90000)
		local names = {}
		for _, node in ipairs(found or {}) do
			names[node.name] = true
		end
		check("find answers flat, with the set in it", names.torture, true)

		local swept = support.sync(function(done)
			tree.sweep(namespace, {}, function(summary, err)
				done(summary, err)
			end)
		end, 120000)
		check("a scoped sweep through the tree runs", swept ~= nil, true)
		check("and the tree reports what was swept", tree.swept(namespace) ~= nil, true)
		check("forgetting it is the client's call", tree.forget(namespace), true)
	end
end

support.describe("live/tree: what counts() answers on each engine")
do
	-- PostgreSQL's reltuples is -1 until analyzed, and -1 is left out, not reported.
	local COUNTED = {
		{ driver = "postgres", namespace = "public", prepare = "analyze torture", estimates = true },
		{ driver = "mysql", estimates = true },
		{ driver = "mariadb", estimates = true },
		{ driver = "mssql", namespace = "dbo", estimates = true },
		{ driver = "sqlite" },
		{ driver = "duckdb", namespace = "main" },
		{ driver = "mongodb" },
		{ driver = "trino" },
	}
	for _, target in ipairs(COUNTED) do
		local connection = connections[target.driver]
		connections_module.register(connection)
		if not support.reachable(connection) then
			note(("%s: skipped"):format(target.driver))
		else
			support.ensure_fixture(connection)
			if target.prepare then
				support.run(connection, target.prepare, { mode = "exec" })
			end
			local counts, err = support.sync(function(done)
				tree.counts(
					{ server = connection.id, namespace = target.namespace },
					function(result, request_err)
						done(result, request_err)
					end
				)
			end, 90000)
			check(("%s answers"):format(target.driver), err, nil)
			if target.estimates then
				check(
					("%s estimates torture"):format(target.driver),
					type(counts and counts.torture),
					"number"
				)
				note(("%s: torture ~ %s rows"):format(target.driver, tostring(counts.torture)))
			else
				-- Nothing counts rows on the tree's behalf (ADR-0038).
				check(("%s keeps no estimate"):format(target.driver), vim.tbl_count(counts or {}), 0)
			end
		end
	end
end

support.describe("live/tree: the statement a trino ref writes is one trino runs")
do
	local trino = connections.trino
	connections_module.register(trino)
	if not support.reachable(trino) then
		note("skipped: nothing listening (tests/containers.sh up)")
	else
		-- The catalog can only come from the ref (ADR-0039): the name used to drop it
		-- and Trino answered "Catalog must be specified when session catalog is not set".
		local ref = { server = trino.id, instance = "tpch", namespace = "tiny", set = "nation" }
		check("the name carries the catalog", tree.qualified_name(ref), '"tpch"."tiny"."nation"')

		local text, text_err = support.sync(function(done)
			tree.statement(ref, "select", function(result, err)
				done(result, err)
			end)
		end, 90000)
		check("the statement is written", text_err, nil)
		check("and carries it too", text, 'SELECT * FROM "tpch"."tiny"."nation"')

		-- The check that cannot be faked: a name the engine rejects is not a name.
		local result, run_err = support.run(trino, text, { limit = 2, timeout = 90000 })
		check("the engine accepts it", run_err and run_err.message or nil, nil)
		check("and answers rows", result and #result.rows > 0, true)

		local instances = support.sync(function(done)
			tree.children({ level = "server", ref = { server = trino.id } }, {}, function(nodes, err)
				done(nodes, err)
			end)
		end, 90000)
		local tpch = nil
		for _, candidate in ipairs(instances or {}) do
			if candidate.name == "tpch" then
				tpch = candidate
			end
		end
		check("a catalog node is not something you reconnect to", tpch and tpch.facts.reconnects, nil)
	end
end
