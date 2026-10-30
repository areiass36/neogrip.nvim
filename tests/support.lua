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
			file = "/tmp/neogrip-test.sqlite",
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

--- Is this server answering? The live tests skip rather than fail when the
--- containers are not up, so the unit tests still run anywhere. A DuckDB file
--- is created by the driver itself, so it only needs a JVM.
function M.reachable(connection)
	if connection.driver == "duckdb" then
		return M.has_jdk()
	end
	if connection.file then
		return vim.fn.filereadable(connection.file) == 1
	end
	local socket = vim.uv.new_tcp()
	local connected = false
	socket:connect(connection.host, connection.port, function(err)
		connected = err == nil
		socket:close()
	end)
	vim.wait(2000, function()
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
