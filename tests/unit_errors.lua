-- Reading what the runner says about a failure, and deciding where to mark it.
local support = require("tests.support")
local check = support.check
local errors = require("neogrip.errors")

support.describe("errors: a JDBC failure")
local parsed = errors.from_rpc({
	code = -32010,
	message = 'ERROR: column "nosuchcol" does not exist\n  Position: 8',
	data = { state = "42703", vendorCode = 0, position = 7 },
})
check("the SQLState is kept", parsed.state, "42703")
check("only the first line is the message", parsed.message, 'ERROR: column "nosuchcol" does not exist')
check("the position comes through", parsed.position, 7)
check("and the name is still extracted as a fallback", parsed.token, "nosuchcol")

parsed = errors.from_rpc({
	code = -32010,
	message = "Unknown column 'nosuchcol' in 'field list'",
	data = { state = "42S22", vendorCode = 1054 },
})
check("a vendor code", parsed.code, 1054)
check("with no position", parsed.position, nil)
check("the token is found", parsed.token, "nosuchcol")

parsed = errors.from_rpc({
	code = -32010,
	message = "[SQLITE_ERROR] no such table: nope",
	data = { state = "null", vendorCode = 0 },
})
check("a driver without a SQLState", parsed.state, nil)
check("token from an unquoted message", parsed.token, "nope")

support.describe("errors: nothing leaks into the message")
parsed = errors.from_rpc(
	{ code = -32010, message = "failed for jdbc:postgresql://user:hunter2@host/db" },
	{ password = "hunter2" }
)
check("the password is masked", parsed.message:find("hunter2", 1, true), nil)
parsed = errors.from_rpc({ code = -32010, message = "login failed: Password=s3cret;Encrypt=false" })
check("and so is a connection-string property", parsed.message:find("s3cret", 1, true), nil)

support.describe("errors: where to underline")
local bufnr = vim.api.nvim_create_buf(false, true)
vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {
	"select 1;",
	"select id, nosuchcol",
	"  from torture;",
})
local statement = { text = "select id, nosuchcol\n  from torture", start_line = 2, end_line = 3 }

-- A server position is an offset into the statement, not into the buffer.
local line, from, to = errors.locate({ position = 11 }, statement, bufnr)
check("the position becomes a buffer line", line, 1)
check(
	"and lands on the name",
	vim.api.nvim_buf_get_lines(bufnr, line, line + 1, false)[1]:sub(from + 1, to),
	"nosuchcol"
)

-- An offset past the first line is carried onto the right one.
line = errors.locate({ position = 23 }, statement, bufnr)
check("an offset on the second line", line, 2)

line, from, to = errors.locate({ token = "nosuchcol" }, statement, bufnr)
check("without a position, the token is searched for", line, 1)
check("and found", vim.api.nvim_buf_get_lines(bufnr, line, line + 1, false)[1]:sub(from + 1, to), "nosuchcol")

line = errors.locate({ line = 2 }, statement, bufnr)
check("a reported line is relative to the statement", line, 2)

line = errors.locate({}, statement, bufnr)
check("with nothing to go on, the statement's first line", line, 1)

-- A name that also appears above the statement must not drag the mark up.
vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {
	"-- nosuchcol in a comment",
	"select nosuchcol from t;",
})
line = errors.locate(
	{ token = "nosuchcol" },
	{ text = "select nosuchcol from t", start_line = 2, end_line = 2 },
	bufnr
)
check("the search stays inside the statement", line, 1)
