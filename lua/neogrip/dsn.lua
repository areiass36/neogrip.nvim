-- JDBC connection URLs.
--
-- The password is never part of the URL: it goes to the Java process on the
-- first line of its stdin (lua/db/jvm.lua), so it appears neither in argv nor
-- in anything the driver might echo back in an error.
local M = {}

local DEFAULT_PORTS = {
	postgres = 5432,
	mysql = 3306,
	mariadb = 3306,
	mssql = 1433,
	mongodb = 27017,
	trino = 8080,
}

local function encode(value)
	return (
		tostring(value):gsub("[^%w%-%._~]", function(char)
			return ("%%%02X"):format(string.byte(char))
		end)
	)
end

M.encode = encode

local function query_string(options, separator, leading)
	local parts = {}
	for key, value in pairs(options or {}) do
		parts[#parts + 1] = ("%s=%s"):format(key, value)
	end
	if #parts == 0 then
		return ""
	end
	table.sort(parts)
	return leading .. table.concat(parts, separator)
end

--- @param connection table
--- @return string|nil url, string|nil error
function M.build(connection)
	local driver = connection.driver
	local host = connection.host or "127.0.0.1"
	local port = connection.port or DEFAULT_PORTS[driver]
	local options = vim.deepcopy(connection.options or {})

	if driver == "sqlite" then
		if not connection.file then
			return nil, ("connection %q has no file"):format(connection.id)
		end
		return "jdbc:sqlite:" .. connection.file
	end

	if driver == "duckdb" then
		if not connection.file then
			return nil, ("connection %q has no file"):format(connection.id)
		end
		return "jdbc:duckdb:" .. connection.file
	end

	if driver == "postgres" then
		-- A local server almost never speaks TLS, and without this the driver
		-- reports the refused handshake as if it were a password problem.
		if options.sslmode == nil and (host == "127.0.0.1" or host == "localhost" or host == "::1") then
			options.sslmode = "disable"
		end
		return ("jdbc:postgresql://%s:%d/%s%s"):format(
			host,
			port,
			connection.database or "",
			query_string(options, "&", "?")
		)
	end

	if driver == "mysql" or driver == "mariadb" then
		-- Without this the connector negotiates latin1 and every non-ASCII
		-- value comes back mojibaked.
		options.characterEncoding = options.characterEncoding or "UTF-8"
		options.connectionCollation = options.connectionCollation or "utf8mb4_unicode_ci"
		local scheme = driver == "mariadb" and "mariadb" or "mysql"
		return ("jdbc:%s://%s:%d/%s%s"):format(
			scheme,
			host,
			port,
			connection.database or "",
			query_string(options, "&", "?")
		)
	end

	if driver == "mssql" then
		if options.encrypt == nil then
			options.encrypt = "false"
		end
		if connection.database then
			options.databaseName = connection.database
		end
		-- SQL Server's JDBC URL uses semicolons, not a query string.
		return ("jdbc:sqlserver://%s:%d%s"):format(host, port, query_string(options, ";", ";"))
	end

	if driver == "trino" then
		-- Trino speaks HTTP, and what follows the host is catalog[/schema],
		-- not a database. Port 443 is TLS everywhere in practice, and without
		-- SSL=true the driver reports a TLS server as an unexpected end of
		-- stream rather than as the wrong scheme.
		if options.SSL == nil and port == 443 then
			options.SSL = "true"
		end
		local path = connection.database or ""
		if path ~= "" and connection.schema then
			path = path .. "/" .. connection.schema
		end
		-- An empty catalog segment is rejected by the driver, so with no
		-- catalog the path is left off entirely. A query then names the catalog
		-- itself (catalog.schema.table), which is how Trino SQL is usually
		-- written anyway; walking into a catalog in the explorer fills it in.
		return ("jdbc:trino://%s:%d%s%s"):format(
			host,
			port,
			path ~= "" and ("/" .. path) or "",
			query_string(options, "&", "?")
		)
	end

	if driver == "mongodb" then
		if connection.auth and connection.auth.user and options.authSource == nil then
			options.authSource = "admin"
		end
		local scheme = options.srv == "true" and "mongodb+srv" or "mongodb"
		options.srv = nil
		local authority = scheme == "mongodb+srv" and host or ("%s:%d"):format(host, port)
		return ("jdbc:%s://%s/%s%s"):format(
			scheme,
			authority,
			connection.database or "",
			query_string(options, "&", "?")
		)
	end

	return nil, ("no JDBC url for driver %q"):format(tostring(driver))
end

--- Mask anything that looks like a credential before it reaches the user.
function M.redact(text, password)
	if type(text) ~= "string" then
		return text
	end
	local redacted = text
	if password and password ~= "" then
		redacted = redacted:gsub(vim.pesc(password), "***")
		redacted = redacted:gsub(vim.pesc(encode(password)), "***")
	end
	redacted = redacted:gsub("(%w+://[^:/@%s]+):[^@%s]*@", "%1:***@")
	redacted = redacted:gsub("([Pp]assword=)[^;%s&]*", "%1***")
	return redacted
end

--- The options that have to reach the driver as JDBC properties.
---
--- build() writes them into the url for every driver but the two whose url is
--- a bare file path, and passing them a second time as properties is not
--- harmless: the Trino driver refuses a property it sees in both places
--- ("Connection property SSLVerification is passed both by URL and
--- properties") rather than picking one. So the url owns them wherever it can
--- carry them, and this is what is left over.
local FILE_URL_DRIVERS = {
	sqlite = true,
	duckdb = true,
}

function M.properties(connection)
	if FILE_URL_DRIVERS[connection.driver] then
		return connection.options or {}
	end
	return {}
end

function M.default_port(driver)
	return DEFAULT_PORTS[driver]
end

return M
