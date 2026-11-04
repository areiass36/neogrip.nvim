-- The shared test vocabulary: flat suites call describe/check/fail and the
-- runner reads the counters. No framework, because the modules under test are
-- callback-based and the one primitive they need is sync().
local M = {}

M.checks = 0
M.failures = 0

function M.describe(name)
	print("")
	print("== " .. name)
end

function M.note(text)
	print("   " .. text)
end

function M.check(name, got, want)
	M.checks = M.checks + 1
	if vim.deep_equal(got, want) then
		print("ok   " .. name)
	else
		M.failures = M.failures + 1
		print("FAIL " .. name)
		print("     got:  " .. vim.inspect(got))
		print("     want: " .. vim.inspect(want))
	end
end

function M.fail(name, detail)
	M.checks = M.checks + 1
	M.failures = M.failures + 1
	print("FAIL " .. name)
	if detail then
		print("     " .. tostring(detail))
	end
end

-- Block until fn is true, the way a test has to when the module under test is
-- callback-based. Returns whether the condition was met in time.
function M.wait(fn, timeout)
	return vim.wait(timeout or 60000, fn, 50)
end

-- Turn a callback-based function into a synchronous call: starter receives a
-- done(...) to invoke, and sync returns whatever done was given, or nil plus
-- "timeout" when it never came.
function M.sync(starter, timeout)
	local results = nil
	starter(function(...)
		results = vim.F.pack_len(...)
	end)
	local arrived = M.wait(function()
		return results ~= nil
	end, timeout)
	if not arrived then
		return nil, "timeout"
	end
	return vim.F.unpack_len(results)
end

-- Passwords match tests/containers.sh; the fixtures read them from kvstore,
-- which the harness replaced with the fake, seeded here from the environment.
M.PASSWORD_ENV = "NVIM_DB_TEST_PW"
M.MSSQL_PASSWORD_ENV = "NVIM_DB_TEST_MSSQL_PW"

function M.seed_secrets()
	local fake = require("kvstore")
	fake.set("test-pw", vim.env[M.PASSWORD_ENV])
	fake.set("test-mssql-pw", vim.env[M.MSSQL_PASSWORD_ENV])
end

local temp_dir = vim.fn.fnamemodify(vim.fn.tempname(), ":h")

--- The connections the live tests use. Ports match tests/containers.sh; the
--- shapes are schema v2 (ADR-0008) after normalization.
function M.connections()
	local password = { type = "password", password = { kvstore = "test-pw" } }
	return {
		postgres = {
			id = "test-pg",
			name = "test pg",
			driver = "postgres",
			host = "127.0.0.1",
			port = 15432,
			database = "testdb",
			auth = vim.tbl_extend("force", password, { user = "testuser" }),
			options = {},
		},
		mysql = {
			id = "test-my",
			name = "test mysql",
			driver = "mysql",
			host = "127.0.0.1",
			port = 13306,
			database = "testdb",
			auth = vim.tbl_extend("force", password, { user = "root" }),
			options = {},
		},
		mariadb = {
			id = "test-maria",
			name = "test mariadb",
			driver = "mariadb",
			host = "127.0.0.1",
			port = 13307,
			database = "testdb",
			auth = vim.tbl_extend("force", password, { user = "root" }),
			options = {},
		},
		mssql = {
			id = "test-ms",
			name = "test mssql",
			driver = "mssql",
			host = "127.0.0.1",
			port = 11433,
			database = "master",
			schema = "dbo",
			auth = { type = "password", user = "sa", password = { kvstore = "test-mssql-pw" } },
			options = {},
		},
		sqlite = {
			id = "test-lite",
			name = "test sqlite",
			driver = "sqlite",
			-- A temp path from nvim itself, not a hardcoded /tmp: on Windows
			-- nvim resolves "/tmp/x" against the drive of the current
			-- directory, so the file the suite read was never the file the
			-- shell wrote, and whether the fixture was there at all depended
			-- on where the runner happened to be started from.
			file = temp_dir .. "/neogrip-test.sqlite",
			auth = { type = "none" },
			options = {},
		},
		duckdb = {
			id = "test-duck",
			name = "test duckdb",
			driver = "duckdb",
			file = temp_dir .. "/neogrip-test.duckdb",
			auth = { type = "none" },
			options = {},
		},
		trino = {
			id = "test-trino",
			name = "test trino",
			driver = "trino",
			host = "127.0.0.1",
			port = 18080,
			-- No catalog on purpose: Trino is the only fixture with an
			-- instance level to walk into, which is what exercises the catalog
			-- travelling in every ref. The user is an option rather than an
			-- auth, because the driver refuses a password without TLS and a
			-- plain-HTTP coordinator trusts whatever name it is given - for
			-- Trino an option lands in the URL and nowhere else (ADR-0012).
			auth = { type = "none" },
			options = { user = "testuser" },
		},
		mongodb = {
			id = "test-mongo",
			name = "test mongo",
			driver = "mongodb",
			host = "127.0.0.1",
			port = 17017,
			database = "shop",
			auth = vim.tbl_extend("force", password, { user = "root" }),
			options = {},
		},
	}
end

--- Live suites need a JVM; without one they skip rather than fail.
function M.has_jdk()
	return require("neogrip.bootstrap.jdk").javac() ~= nil
end

local seeded = {}

--- The standard torture fixture in a database that arrives without one.
---
--- The same reason DuckDB's fixture is made this way: a file database has no
--- container, so tests/containers.sh cannot reach it. SQLite used to be seeded
--- by the sqlite3 CLI, which assumed an executable that is not there on a
--- stock Windows box and wrote to a different path than the JVM resolved
--- anyway. Memoized, and the stale file is dropped first, so a run starts from
--- a known fixture rather than from whatever an earlier run left behind.
function M.ensure_fixture(connection)
	if seeded[connection.id] then
		return true
	end
	seeded[connection.id] = true
	local statements = nil
	if connection.driver == "sqlite" then
		vim.fn.delete(connection.file)
		-- One statement per call: a single string of three would be split by
		-- the sequence rule of ADR-0030 and the failure would read as a
		-- parse error.
		statements = {
			"create table torture(id integer primary key, s_null text, s_empty text, "
				.. "s_comma text, cjk text)",
			"insert into torture values (1,null,'','a,b','日本語')",
			"insert into torture values (2,null,'','x','中文')",
		}
	elseif connection.driver == "trino" then
		-- Trino has a container but nothing in it to write to: tpch is generated
		-- and read-only, and the memory catalog starts empty and dies with the
		-- process. So it is seeded here like the file databases are, and named in
		-- full because the connection deliberately pins no catalog - that is what
		-- gives the tree an instance level to walk into.
		statements = {
			"drop table if exists memory.default.torture",
			"create table memory.default.torture as select * from (values "
				.. "(1, cast(null as varchar), '', 'a,b', '日本語'), "
				.. "(2, cast(null as varchar), '', 'x', '中文')"
				.. ") as t(id, s_null, s_empty, s_comma, cjk)",
		}
	elseif connection.driver == "duckdb" then
		-- A DuckDB file is a fresh temp path per process, so a suite run on its
		-- own finds nothing in it. The suites that want a particular shape
		-- replace this one straight after; what this guarantees is only that
		-- `torture` exists, which is what the suites that merely name it need -
		-- live_diagnostics asked for a column of it and got "Table with name
		-- torture does not exist" whenever it ran without live_jdbc ahead of it.
		statements = {
			"create table if not exists torture(id integer, s_null varchar, s_empty varchar, "
				.. "s_comma varchar, cjk varchar)",
			"delete from torture",
			"insert into torture values (1,null,'','a,b','日本語'),(2,null,'','x','中文')",
		}
	end
	for _, sql in ipairs(statements or {}) do
		local _, err = M.run(connection, sql, { mode = "exec", timeout = 90000 })
		if err then
			return false, err.message
		end
	end
	return true
end

--- Is this server answering? The live tests skip rather than fail when the
--- containers are not up, so the unit tests still run anywhere. A file
--- database is created by the driver itself, so it only needs a JVM - asking
--- whether the file is already there would skip the very first run and make
--- the suite depend on an artifact of the last one.
function M.reachable(connection)
	if connection.file then
		return M.has_jdk()
	end
	local socket = vim.uv.new_tcp()
	local connected = false
	socket:connect(connection.host, connection.port, function(err)
		connected = err == nil
		socket:close()
	end)
	-- Trino's coordinator binds its HTTP port well before it will plan a
	-- query, and the handshake itself is slower than a database socket, so it
	-- gets longer here. The real gate is tests/containers.sh, which does not
	-- return until Trino answers `select 1`.
	vim.wait(connection.driver == "trino" and 5000 or 2000, function()
		return socket:is_closing()
	end, 20)
	return connected
end

function M.run(connection, sql, opts)
	opts = opts or {}
	local request = vim.tbl_extend("force", {
		connection = connection,
		sql = sql,
		mode = "query",
		limit = opts.limit or 0,
	}, opts)
	return M.sync(function(done)
		require("neogrip.runner").run(request, function(result, err)
			done(result, err)
		end)
	end, opts.timeout)
end

--- The next batch of a result left open under `hash` (ADR-0031).
function M.next_batch(connection, hash, limit)
	return M.sync(function(done)
		require("neogrip.runner").run({
			connection = connection,
			mode = "next",
			hash = hash,
			limit = limit or 0,
		}, function(result, err)
			done(result, err)
		end)
	end)
end

--- First cell of the first row, as a number when it looks like one.
function M.scalar(connection, sql)
	local result, err = M.run(connection, sql)
	if err then
		return nil, err.message
	end
	local value = result.rows[1] and result.rows[1][1]
	return tonumber(value) or value
end

return M
