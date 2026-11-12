-- The DDL export against real servers: the script's shape, the fixture
-- password never in it, and the decisive check - replayed into a scratch
-- database, the script rebuilds a schema whose own export reads the same.
local support = require("tests.support")
local check, note = support.check, support.note

if not support.has_jdk() then
	support.describe("live/ddl")
	note("skipped: no JDK available (set NEOGRIP_TEST_JDK)")
	return
end
support.seed_secrets()

local connections_module = require("neogrip.connections")
local export = require("neogrip.catalog.export")
local split = require("neogrip.sql.split")
local tree = require("neogrip.catalog.tree")
local connections = support.connections()

local temp_dir = vim.fn.fnamemodify(vim.fn.tempname(), ":h")

local secrets = {}
for _, env in ipairs({ support.PASSWORD_ENV, support.MSSQL_PASSWORD_ENV }) do
	local value = vim.env[env]
	if value and value ~= "" then
		secrets[#secrets + 1] = value
	end
end

local function script_of(target)
	local path = vim.fn.tempname() .. ".sql"
	local summary, err = support.sync(function(done)
		export.script(target, { path = path }, function(s, e)
			done(s, e)
		end)
	end, 180000)
	local lines = vim.fn.filereadable(path) == 1 and vim.fn.readfile(path) or {}
	pcall(vim.fn.delete, path)
	return lines, summary, err
end

--- The SQL alone: comment lines and blank lines dropped, for the comparison
--- of two exports that may only differ in what their comments describe.
local function sql_lines(lines)
	local kept = {}
	for _, line in ipairs(lines) do
		if not line:match("^%s*%-%-") and not line:match("^%s*$") then
			kept[#kept + 1] = line
		end
	end
	return kept
end

--- The statements to replay, comment-free, through the project's own lexer.
local function sql_statements(lines, dialect)
	local parsed = split.statements(table.concat(lines, "\n") .. "\n", dialect)
	local out = {}
	for _, statement in ipairs(parsed) do
		local bare = {}
		for _, line in ipairs(vim.split(statement.text, "\n", { plain = true })) do
			if not line:match("^%s*%-%-") then
				bare[#bare + 1] = line
			end
		end
		local body = vim.trim(table.concat(bare, "\n"))
		if body ~= "" then
			out[#out + 1] = body
		end
	end
	return out
end

local function create_position(lines, name)
	for index, line in ipairs(lines) do
		local low = line:lower()
		if low:find("create table", 1, true) and low:find(name, 1, true) then
			return index
		end
	end
	return nil
end

--- The shape every engine's script must have; returns false when the export
--- itself failed, so the caller does not pile errors on errors.
local function shape_checks(driver, lines, err, expect)
	check(driver .. ": the export succeeds", err, nil)
	if err then
		return false
	end
	check(driver .. ": the header leads", (lines[1] or ""):find("-- neogrip export: ", 1, true), 1)
	local text = table.concat(lines, "\n")
	for _, needle in ipairs(expect.has or {}) do
		check(("%s: carries %s"):format(driver, needle), text:find(needle, 1, true) ~= nil, true)
	end
	for _, needle in ipairs(expect.lacks or {}) do
		check(("%s: free of %s"):format(driver, needle), text:find(needle, 1, true) == nil, true)
	end
	if expect.unordered then
		-- The engine reports no foreign keys, so there is no graph to order by;
		-- the header note asserted above is the honest half of that.
		note(driver .. ": ordering is not provable here, the driver reports no FKs")
	else
		local parent = create_position(lines, "ddl_parent")
		local child = create_position(lines, "ddl_child")
		check(
			driver .. ": the parent is created before the child",
			parent ~= nil and child ~= nil and parent < child,
			true
		)
	end
	local clean = true
	for _, secret in ipairs(secrets) do
		if text:find(secret, 1, true) then
			clean = false
		end
	end
	check(driver .. ": the fixture password is nowhere in the script", clean, true)
	return true
end

--- Replay every statement into the scratch target; nil when all succeeded.
local function replay(connection, statements)
	for index, statement in ipairs(statements) do
		local _, err = support.run(connection, statement, { mode = "exec", timeout = 90000 })
		if err then
			return ("statement %d failed: %s\n%s"):format(index, err.message, statement)
		end
	end
	return nil
end

--- The whole dance for one engine: shape, determinism, replay, re-export.
--- `scratch.prepare` makes the empty scratch target and answers the
--- connection to replay into; `scratch.target` is what to re-export.
local function exercise(driver, target, expect, scratch)
	support.describe("live/ddl: " .. driver)
	local connection = connections[driver]
	if not support.reachable(connection) then
		note("skipped: not reachable")
		return
	end
	connections_module.register(connection)
	if connection.file then
		support.ensure_fixture(connection)
	end

	local lines, summary, err = script_of(target)
	if not shape_checks(driver, lines, err, expect) then
		return
	end
	check(driver .. ": the counts name tables and views", {
		(summary.tables or 0) > 0,
		(summary.views or 0) > 0,
	}, { true, true })

	local again = script_of(target)
	check(driver .. ": two exports are byte-identical", again, lines)

	if not scratch then
		note(driver .. ": replay is shape-only here, by design")
		return
	end

	local replay_connection, prepare_err = scratch.prepare()
	if not replay_connection then
		support.fail(driver .. ": scratch target", prepare_err)
		return
	end
	connections_module.register(replay_connection)

	local failure = replay(replay_connection, sql_statements(lines, connection.driver))
	check(driver .. ": every statement of the replay succeeds", failure, nil)
	if failure then
		return
	end

	local replayed = script_of(scratch.target(replay_connection))
	check(
		driver .. ": the replayed schema exports the same statements",
		sql_lines(replayed),
		sql_lines(lines)
	)
end

-- PostgreSQL: a scratch database on the same server; its own `public` means
-- the script replays with no rewriting at all.
exercise("postgres", { server = "test-pg", namespace = "public" }, {
	has = { '"Odd Name"', "ADD CONSTRAINT", "CHECK", "CREATE UNIQUE INDEX" },
}, {
	prepare = function()
		local pg = connections.postgres
		support.run(pg, "drop database if exists ddl_replay with (force)", { mode = "exec" })
		local _, err = support.run(pg, "create database ddl_replay", { mode = "exec" })
		if err then
			return nil, err.message
		end
		return vim.tbl_extend("force", pg, {
			id = "test-pg-replay",
			name = "test pg replay",
			database = "ddl_replay",
		})
	end,
	target = function(replay_connection)
		return { server = replay_connection.id, namespace = "public" }
	end,
})

-- MySQL and MariaDB: the database arrives as a catalog, so the scratch is a
-- database and the unqualified native text lands in it unchanged.
for _, driver in ipairs({ "mysql", "mariadb" }) do
	exercise(driver, { server = connections[driver].id }, {
		has = { "`Odd Name`", "CHECK", "ddl_parent_label_uq" },
	}, {
		prepare = function()
			local base = connections[driver]
			support.run(base, "drop database if exists ddl_replay", { mode = "exec" })
			local _, err = support.run(base, "create database ddl_replay", { mode = "exec" })
			if err then
				return nil, err.message
			end
			return vim.tbl_extend("force", base, {
				id = base.id .. "-replay",
				name = base.name .. " replay",
				database = "ddl_replay",
			})
		end,
		target = function(replay_connection)
			return { server = replay_connection.id }
		end,
	})
end

-- SQL Server: a scratch database whose own dbo receives the [dbo] statements.
exercise("mssql", { server = "test-ms", namespace = "dbo" }, {
	has = { "[Odd Name]", "CREATE UNIQUE INDEX", "-- CHECK constraints are not reported" },
}, {
	prepare = function()
		local ms = connections.mssql
		support.run(ms, "drop database if exists ddl_replay", { mode = "exec" })
		local _, err = support.run(ms, "create database ddl_replay", { mode = "exec" })
		if err then
			return nil, err.message
		end
		return vim.tbl_extend("force", ms, {
			id = "test-ms-replay",
			name = "test mssql replay",
			database = "ddl_replay",
		})
	end,
	target = function(replay_connection)
		return { server = replay_connection.id, namespace = "dbo" }
	end,
})

-- SQLite: the scratch is a fresh file, and sqlite_master hands back the
-- replayed text verbatim.
exercise("sqlite", { server = "test-lite" }, {
	has = { '"Odd Name"', "check (total >= 0)", 'CREATE UNIQUE INDEX "ddl_parent_label_uq"' },
}, {
	prepare = function()
		local file = temp_dir .. "/neogrip-ddl-replay.sqlite"
		vim.fn.delete(file)
		return vim.tbl_extend("force", connections.sqlite, {
			id = "test-lite-replay",
			name = "test sqlite replay",
			file = file,
		})
	end,
	target = function(replay_connection)
		return { server = replay_connection.id }
	end,
})

-- DuckDB: a fresh file too; JDBC reports no CHECK there, and the script must
-- say so instead of guessing.
exercise("duckdb", { server = "test-duck", namespace = "main" }, {
	has = {
		'"Odd Name"',
		"-- CHECK constraints are not reported",
		"-- Foreign keys are not reported",
	},
	unordered = true,
}, {
	prepare = function()
		local file = temp_dir .. "/neogrip-ddl-replay.duckdb"
		vim.fn.delete(file)
		return vim.tbl_extend("force", connections.duckdb, {
			id = "test-duck-replay",
			name = "test duckdb replay",
			file = file,
		})
	end,
	target = function(replay_connection)
		return { server = replay_connection.id, namespace = "main" }
	end,
})

-- The database id itself: on an engine whose databases arrive as catalogs,
-- the namespace slot holds the database and the tables are named once.
for _, driver in ipairs({ "mysql", "mariadb" }) do
	support.describe("live/ddl: a " .. driver .. " database id")
	local base = connections[driver]
	if not support.reachable(base) then
		note("skipped: not reachable")
	else
		local nodb = vim.deepcopy(base)
		nodb.id = base.id .. "-nodb"
		nodb.name = base.name .. " nodb"
		nodb.database = nil
		connections_module.register(nodb)
		local id = tree.id({ server = nodb.id, instance = "testdb" })
		local lines, _, err = script_of(id)
		check(driver .. ": a database id exports", err, nil)
		if not err then
			local text = table.concat(lines, "\n")
			check(driver .. ": the tables are named once, not twice", {
				select(2, text:gsub("CREATE TABLE `ddl_parent`", "")),
				select(2, text:gsub("CREATE TABLE `ddl_child`", "")),
				select(2, text:gsub("CREATE TABLE `torture`", "")),
			}, { 1, 1, 1 })
		end
	end
end

-- Trino: tpch is read-only and FKs do not exist, so the shape is the claim.
support.describe("live/ddl: trino")
local trino = connections.trino
if not support.reachable(trino) then
	note("skipped: not reachable")
else
	connections_module.register(trino)
	local lines, _, err = script_of({ server = "test-trino", instance = "tpch", namespace = "tiny" })
	check("trino: the export succeeds", err, nil)
	if not err then
		local text = table.concat(lines, "\n")
		check(
			"trino: the names have three parts (ADR-0039)",
			text:find("CREATE TABLE tpch.tiny.", 1, true) ~= nil,
			true
		)
		note("trino: replay is shape-only here, by design")
	end
end

-- MongoDB: a collection has no DDL, and the script says so per collection.
support.describe("live/ddl: mongodb")
local mongo = connections.mongodb
if not support.reachable(mongo) then
	note("skipped: not reachable")
else
	connections_module.register(mongo)
	local lines, summary, err = script_of({ server = "test-mongo" })
	check("mongodb: the export succeeds", err, nil)
	if not err then
		local text = table.concat(lines, "\n")
		check("mongodb: every collection is a comment", {
			text:find("-- orders: a collection has no DDL", 1, true) ~= nil,
			(summary.collections or 0) >= 2,
			#sql_lines(lines),
		}, { true, true, 0 })
		note("mongodb: replay is shape-only here, by design")
	end
end

-- The scratch databases are dropped on the next run's prepare; the processes
-- they held are drained with everything else by tests/run.lua.
