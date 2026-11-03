-- The tree against real servers: that the walk a connection declares is the
-- walk it answers, that a set's kind is one of three, that rows come through
-- the cursor and stop when told, and that the decorations a client asks for
-- afterwards arrive (ADR-0036, ADR-0038).
local support = require("tests.support")
local check, note = support.check, support.note

if not support.has_jdk() then
	support.describe("live/tree")
	note("skipped: no JDK available (set NEOGRIP_TEST_JDK)")
	return
end
support.seed_secrets()
local tree = require("neogrip.tree")
local connections_module = require("neogrip.connections")
local schema = require("neogrip.schema")
local connections = support.connections()

--- One level of children, waited for.
local function children(node, opts)
	return support.sync(function(done)
		tree.children(node, opts or {}, function(nodes, err)
			done(nodes, err)
		end)
	end, 90000)
end

--- Walk to the deepest level the shape declares, collecting what was seen.
---
--- Which namespace to walk into is declared by the caller rather than guessed:
--- SQL Server answers with a dozen schemas that exist for permissions and hold
--- no tables at all, and the first of them sorted is not the one with the
--- fixture in it.
local function walk(connection, want_set, want_namespace)
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
			-- Walk toward the fixture rather than into whatever sorted first:
			-- SQL Server answers with a dozen schemas that exist for
			-- permissions and hold no tables, and db_accessadmin is the first
			-- of them by name.
			local wanted = want_set
			if entry.level == "namespace" and want_namespace then
				wanted = want_namespace
			end
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
	{ driver = "mssql", set = "torture", namespace = "dbo" },
	{ driver = "sqlite", set = "torture" },
	{ driver = "duckdb", set = "torture", fixture = true },
	{ driver = "mongodb", set = "orders" },
}

for _, engine in ipairs(ENGINES) do
	local connection = connections[engine.driver]
	support.describe("live/tree: " .. engine.driver)
	connections_module.register(connection)
	if not support.reachable(connection) then
		note("skipped: nothing listening (tests/containers.sh up)")
	else
		if engine.fixture then
			-- DuckDB's file is a fresh temp path per process, so the fixture
			-- is made here rather than by the containers.
			support.run(connection, "create or replace table torture as select 1 as id, 'a' as label", {
				mode = "exec",
			})
		end
		schema.invalidate(connection)

		local walked, walk_err = walk(connection, engine.set, engine.namespace)
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

				-- The attributes, which is where the walk ends.
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

		-- Rows are data: the walk does not reach them unless asked.
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

		-- Collapsing a node has to close the cursor: gripd keeps four per
		-- connection and evicts the oldest, so a client that never closes
		-- loses the branch it opened first.
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
