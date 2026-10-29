-- JDBC drivers, one jar per database, downloaded when that database is first
-- used, pinned and checksum-verified (ADR-0006).
--
-- Each connection runs with only its own driver on the classpath. That is not
-- tidiness: the MongoDB driver bundles a GraalVM JavaScript engine, and having
-- it on the classpath of a PostgreSQL connection prints warnings and slows the
-- start of every query (ADR-0003).
--
-- Digests computed from the official artifacts on 2026-10-29 and cross-checked
-- against the repository's published hashes. Bumping a version means updating
-- jar, url and sha256 together.
local download = require("neogrip.bootstrap.download")
local neogrip = require("neogrip")

local MAVEN = "https://repo1.maven.org/maven2"

--- @class neogrip.Driver
--- @field jar string file name under data_dir/jdbc
--- @field url string
--- @field sha256 string pinned digest of the jar
local DRIVERS = {
	postgres = {
		jar = "postgresql-42.7.7.jar",
		url = MAVEN .. "/org/postgresql/postgresql/42.7.7/postgresql-42.7.7.jar",
		sha256 = "157963d60ae66d607e09466e8c0cdf8087e9cb20d0159899ffca96bca2528460",
	},
	mysql = {
		jar = "mysql-connector-j-9.3.0.jar",
		url = MAVEN .. "/com/mysql/mysql-connector-j/9.3.0/mysql-connector-j-9.3.0.jar",
		sha256 = "6c8e6692b521376d89bc5618c16cdeaf8c61854329f4fa25677ed08776c5bb76",
	},
	mariadb = {
		jar = "mariadb-java-client-3.5.3.jar",
		url = MAVEN .. "/org/mariadb/jdbc/mariadb-java-client/3.5.3/mariadb-java-client-3.5.3.jar",
		sha256 = "85c4ba2f221d0dfd439c26affbb294f784960763544263c65aba9c2c76858706",
	},
	mssql = {
		jar = "mssql-jdbc-12.10.0.jre11.jar",
		url = MAVEN .. "/com/microsoft/sqlserver/mssql-jdbc/12.10.0.jre11/mssql-jdbc-12.10.0.jre11.jar",
		sha256 = "8b80e2a3d254c26f66d479bc51d2d235f054eeb6e8394260c129bbd7fc7394a7",
	},
	sqlite = {
		jar = "sqlite-jdbc-3.49.1.0.jar",
		url = MAVEN .. "/org/xerial/sqlite-jdbc/3.49.1.0/sqlite-jdbc-3.49.1.0.jar",
		sha256 = "5c8609d2ca341deb8c6f71778974b5ba4995c7d32d7c7c89d9392a3e72c39291",
	},
	duckdb = {
		jar = "duckdb_jdbc-1.3.1.0.jar",
		url = MAVEN .. "/org/duckdb/duckdb_jdbc/1.3.1.0/duckdb_jdbc-1.3.1.0.jar",
		sha256 = "612c1e55e45fb496902b8ec7f9bb957a404813e6d1fc1c4531df000d1bab2d07",
	},
	-- Trino is a query engine in front of other stores rather than a store, so
	-- this jar speaks its HTTP protocol instead of a database wire protocol.
	trino = {
		jar = "trino-jdbc-484.jar",
		url = MAVEN .. "/io/trino/trino-jdbc/484/trino-jdbc-484.jar",
		sha256 = "46476af2968e6f3234e8b22d7e29c26e6d7213ce88ab546a29c4c318c921cd34",
	},
	-- JetBrains', the one DataGrip itself uses: Apache-2.0, and the only JDBC
	-- driver that talks to a plain mongod. MongoDB's own driver needs the
	-- Atlas SQL interface, which a local server does not have. Gated by the
	-- spike recorded against ADR-0020 before the MongoDB phase starts.
	mongodb = {
		jar = "mongo-jdbc-standalone-1.21.jar",
		url = "https://github.com/DataGrip/mongo-jdbc-driver/releases/download/v1.21/mongo-jdbc-standalone-1.21.jar",
		sha256 = "9bc867a24c22fdfbbdfe06e50c34c5f359c9260b3c7de06d5588701adcba8ef3",
	},
}

local M = {}

M.dir = neogrip.data_dir .. "/jdbc"

--- @return string|nil path to the jar for this driver, when already installed
function M.jar(driver)
	local spec = DRIVERS[driver]
	if not spec then
		return nil
	end
	local path = ("%s/%s"):format(M.dir, spec.jar)
	return vim.fn.filereadable(path) == 1 and path or nil
end

function M.drivers()
	return vim.tbl_keys(DRIVERS)
end

--- @param on_done fun(path: string|nil, err: string|nil)
function M.ensure(driver, on_done)
	local spec = DRIVERS[driver]
	if not spec then
		return on_done(nil, ("no JDBC driver known for %q"):format(tostring(driver)))
	end

	local existing = M.jar(driver)
	if existing then
		return on_done(existing, nil)
	end

	local path = ("%s/%s"):format(M.dir, spec.jar)
	neogrip.notify(("downloading the %s JDBC driver..."):format(driver))
	download.file(spec.jar, spec.url, spec.sha256, path, function(ok)
		if not ok then
			return on_done(nil, ("could not download the %s driver"):format(driver))
		end
		on_done(path, nil)
	end)
end

return M
