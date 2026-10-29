-- Guards that fire before any connection is needed, so they test without a DB.
local support = require("tests.support")
local check = support.check
local execute = require("neogrip.execute")

support.describe("execute: a statement that is only comments is not sent")

local function run_buffer(lines)
	local bufnr = vim.api.nvim_create_buf(false, true)
	vim.bo[bufnr].filetype = "sql"
	vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
	vim.api.nvim_set_current_buf(bufnr)
	vim.api.nvim_win_set_cursor(0, { 1, 0 })

	local message = nil
	local original = vim.notify
	vim.notify = function(text)
		message = text
	end
	execute.run({ bufnr = bufnr })
	vim.wait(500, function()
		return message ~= nil
	end, 20)
	vim.notify = original
	return message
end

check(
	"a line comment alone says there is no statement",
	run_buffer({ "-- just a note" }),
	"[neogrip] no statement under the cursor"
)
check(
	"a block comment alone too",
	run_buffer({ "/* a note", "spanning lines */" }),
	"[neogrip] no statement under the cursor"
)
check("a blank buffer too", run_buffer({ "", "   " }), "[neogrip] no statement under the cursor")
check(
	"a comment followed by whitespace, no trailing newline",
	run_buffer({ "-- trailing", "  " }),
	"[neogrip] no statement under the cursor"
)
