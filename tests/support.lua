-- Shared test vocabulary: no framework, because the modules under test are
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

function M.wait(fn, timeout)
	return vim.wait(timeout or 60000, fn, 50)
end

-- Turns a callback-based function into a synchronous call; returns nil plus "timeout" when
-- done(...) never came.
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

-- Passwords match tests/containers.sh and reach the suites only through the fake kvstore,
-- seeded from the environment; no real credentials.
M.PASSWORD_ENV = "NVIM_DB_TEST_PW"
M.MSSQL_PASSWORD_ENV = "NVIM_DB_TEST_MSSQL_PW"

function M.seed_secrets()
	local fake = require("kvstore")
	fake.set("test-pw", vim.env[M.PASSWORD_ENV])
	fake.set("test-mssql-pw", vim.env[M.MSSQL_PASSWORD_ENV])
end

local temp_dir = vim.fn.fnamemodify(vim.fn.tempname(), ":h")

--- Live-test connections: ports match tests/containers.sh, shapes are schema v2 (ADR-0008).
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
			-- A temp path from nvim, not a hardcoded /tmp: on Windows "/tmp/x" resolves against
			-- the current drive, so the suite read a different file than the shell wrote.
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
			-- No catalog on purpose (exercises the instance level), and user as an option, not
			-- an auth, because the driver refuses a password without TLS (ADR-0012).
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
	return require("neogrip.gripd.bootstrap.jdk").javac() ~= nil
end

local seeded = {}

--- Seeds the torture fixture from here, not tests/containers.sh: the sqlite3 CLI it used is
--- absent on a stock Windows box and wrote to a different path than the JVM resolved anyway.
function M.ensure_fixture(connection)
	if seeded[connection.id] then
		return true
	end
	seeded[connection.id] = true
	local statements = nil
	if connection.driver == "sqlite" then
		vim.fn.delete(connection.file)
		-- One statement per call: a single string would be split by the ADR-0030 sequence rule.
		statements = {
			"create table torture(id integer primary key, s_null text, s_empty text, "
				.. "s_comma text, cjk text)",
			"insert into torture values (1,null,'','a,b','日本語')",
			"insert into torture values (2,null,'','x','中文')",
			"create table ddl_parent(id integer not null, part integer not null, "
				.. 'label text not null, total numeric default 0, "Odd Name" text, '
				.. "constraint ddl_parent_pk primary key (id, part), "
				.. "constraint ddl_parent_total_ck check (total >= 0))",
			"create unique index ddl_parent_label_uq on ddl_parent(label)",
			"create table ddl_child(id integer primary key, parent_id integer not null, "
				.. "parent_part integer not null, "
				.. "constraint ddl_child_parent_fk foreign key (parent_id, parent_part) "
				.. "references ddl_parent(id, part))",
			"create view ddl_sight as select id, s_comma from torture",
		}
	elseif connection.driver == "trino" then
		-- Trino's memory catalog starts empty and dies with the process, so it is seeded here,
		-- named in full because the connection pins no catalog.
		statements = {
			"drop table if exists memory.default.torture",
			"create table memory.default.torture as select * from (values "
				.. "(1, cast(null as varchar), '', 'a,b', '日本語'), "
				.. "(2, cast(null as varchar), '', 'x', '中文')"
				.. ") as t(id, s_null, s_empty, s_comma, cjk)",
		}
	elseif connection.driver == "duckdb" then
		-- Only guarantees `torture` exists: live_diagnostics failed with "Table with name
		-- torture does not exist" whenever it ran without live_jdbc ahead of it.
		statements = {
			"create table if not exists torture(id integer, s_null varchar, s_empty varchar, "
				.. "s_comma varchar, cjk varchar)",
			"delete from torture",
			"insert into torture values (1,null,'','a,b','日本語'),(2,null,'','x','中文')",
			"drop view if exists ddl_sight",
			"drop table if exists ddl_child",
			"drop table if exists ddl_parent",
			"create table ddl_parent(id integer not null, part integer not null, "
				.. 'label varchar not null, total decimal(10,2) default 0, "Odd Name" varchar, '
				.. "constraint ddl_parent_pk primary key (id, part), "
				.. "constraint ddl_parent_total_ck check (total >= 0))",
			"create unique index ddl_parent_label_uq on ddl_parent(label)",
			"create table ddl_child(id integer primary key, parent_id integer not null, "
				.. "parent_part integer not null, "
				.. "constraint ddl_child_parent_fk foreign key (parent_id, parent_part) "
				.. "references ddl_parent(id, part))",
			"create view ddl_sight as select id, s_comma from torture",
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

--- Reachability probe: live suites skip rather than fail when the containers are not up, and
--- a file database only needs a JVM since the driver creates the file itself.
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
	-- Trino's handshake is slower than a database socket, so it gets a longer wait.
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
		require("neogrip.gripd.runner").run(request, function(result, err)
			done(result, err)
		end)
	end, opts.timeout)
end

--- The next batch of a result left open under `hash` (ADR-0031).
function M.next_batch(connection, hash, limit, opts)
	opts = opts or {}
	local request = vim.tbl_extend("force", {
		connection = connection,
		mode = "next",
		hash = hash,
		limit = limit or 0,
	}, opts)
	return M.sync(function(done)
		require("neogrip.gripd.runner").run(request, function(result, err)
			done(result, err)
		end)
	end, opts.timeout)
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
