-- The things that must not happen: a secret in the process table, a validation
-- that changes data, a write on a read-only connection. There are no
-- confirmations to test (ADR-0016): protection is mechanical or absent.
local support = require("tests.support")
local check, note = support.check, support.note

support.describe("live/safety")
if not support.has_jdk() then
	note("skipped: no JDK available (set NEOGRIP_TEST_JDK)")
	return
end
support.seed_secrets()

local connections = support.connections()
local pg = connections.postgres

support.describe("live/safety: the secret never reaches the process table")
if not support.reachable(pg) then
	note("skipped: nothing listening (tests/containers.sh up)")
else
	local runner = require("neogrip.runner")
	local sidecar = require("neogrip.sidecar")
	local finished = false
	runner.run({ connection = pg, sql = "select pg_sleep(3), 1 as a", mode = "query", limit = 1 }, function()
		finished = true
	end)
	-- Look at the process table while the query is actually running.
	vim.wait(1500, function()
		return false
	end, 100)

	local pid = (sidecar.info(pg.id) or {}).pid
	check("the sidecar is running", pid ~= nil, true)

	-- By pid, not by pattern: this must look at exactly the process we
	-- started, and nothing else that happens to mention it.
	local password = vim.env[support.PASSWORD_ENV] or ""
	-- Windows needs its own way of asking: ps there reports the processes Git
	-- Bash knows about and not a native process's command line.
	local function command_line_of(process)
		if vim.fn.has("win32") == 1 then
			local query = ('(Get-CimInstance Win32_Process -Filter "ProcessId=%d").CommandLine'):format(
				process
			)
			return vim.fn.system({ "powershell", "-NoProfile", "-NonInteractive", "-Command", query })
		end
		return vim.fn.system({ "ps", "-o", "command=", "-p", tostring(process) })
	end
	local command_line = pid and command_line_of(pid) or ""
	note(("argv: %s"):format(vim.trim(command_line):sub(1, 90)))
	check("its command line holds no password", command_line:find(password, 1, true), nil)
	check(
		"nor the url-encoded form",
		command_line:find(require("neogrip.dsn").encode(password), 1, true),
		nil
	)
	check("nor the user name", command_line:find("testuser", 1, true), nil)
	check("nor the jdbc url", command_line:find("jdbc:", 1, true), nil)
	check("and it really is the sidecar", command_line:find("neogrip.Main", 1, true) ~= nil, true)

	support.wait(function()
		return finished
	end)
end

support.describe("live/safety: the secret is not even in the URL")
local dsn = require("neogrip.dsn")
local url = dsn.build(pg)
-- The JDBC URL is built without it: secrets travel inside the connect request
-- (ADR-0009), so there is no string to leak in the first place. Redaction
-- stays as a guard for whatever a server echoes back.
check("the url has no password", url:find(vim.env[support.PASSWORD_ENV] or "@@none@@", 1, true), nil)
check(
	"redacting a password that appears in a message",
	dsn.redact("failed: pw=hunter2", "hunter2"):find("hunter2", 1, true),
	nil
)
check(
	"redacting without knowing it",
	dsn.redact("postgres://user:whatever@host:5432/db"),
	"postgres://user:***@host:5432/db"
)

support.describe("live/safety: validating must not change anything")
if not support.reachable(pg) then
	note("skipped")
else
	local before = support.scalar(pg, "select count(*) from torture")
	check("rows before", before, 2)

	-- Each of these is sent to the server exactly as written. Preparing it
	-- parses and resolves it; none of it runs.
	for _, sql in ipairs({
		"delete from torture",
		"drop table torture",
		"insert into torture(id) values (99)",
		"update torture set s_comma = 'x'",
		"truncate torture",
	}) do
		local _, err = support.run(pg, sql, { mode = "validate" })
		note(("%-40s -> %s"):format(sql, err and err.message:sub(1, 40) or "accepted"))
	end

	check(
		"rows after validating five destructive statements",
		support.scalar(pg, "select count(*) from torture"),
		before
	)
	check(
		"the table is still there",
		support.scalar(pg, "select count(*) from information_schema.tables where table_name = 'torture'"),
		1
	)
	check(
		"and its values are untouched",
		support.scalar(pg, "select count(*) from torture where s_comma = 'a,b'"),
		1
	)
end

support.describe("live/safety: a read-only connection refuses a write, with no prompt")
if not support.reachable(pg) then
	note("skipped")
else
	local readonly = vim.tbl_extend("force", vim.deepcopy(pg), { id = "test-pg-ro2", readonly = true })
	require("neogrip.connections").register(readonly)

	local bufnr = vim.api.nvim_create_buf(false, true)
	vim.bo[bufnr].filetype = "sql"
	vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "delete from torture where id = 1;" })
	vim.api.nvim_set_current_buf(bufnr)
	require("neogrip.resolve").bind(bufnr, readonly.id)

	local messages = {}
	local prompted = false
	local original_notify = vim.notify
	local original_input = vim.ui.input
	local original_select = vim.ui.select
	vim.notify = function(message)
		messages[#messages + 1] = message
	end
	vim.ui.input = function(_, on_confirm)
		prompted = true
		on_confirm(nil)
	end
	vim.ui.select = function(_, _, on_choice)
		prompted = true
		on_choice(nil)
	end
	require("neogrip.execute").run({ bufnr = bufnr })
	vim.wait(1500, function()
		return #messages > 0
	end, 50)
	vim.notify = original_notify
	vim.ui.input = original_input
	vim.ui.select = original_select

	local refused = false
	for _, message in ipairs(messages) do
		if message:find("read%-only") then
			refused = true
		end
	end
	check("it says no", refused, true)
	check("without asking anything (ADR-0016)", prompted, false)
	check("and nothing was deleted", support.scalar(pg, "select count(*) from torture"), 2)
end
