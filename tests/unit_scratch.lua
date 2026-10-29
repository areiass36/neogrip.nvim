-- Cleaning up after sessions that are gone.
local support = require("tests.support")
local check = support.check
local neogrip = require("neogrip")
local requery = require("neogrip.grid.requery")

support.describe("scratch: a dead session's files are collected")
local scratch_dir = neogrip.state_dir .. "/scratch"
local results_dir = neogrip.state_dir .. "/results"
vim.fn.mkdir(scratch_dir, "p")
vim.fn.mkdir(results_dir, "p")

-- A pid that cannot be running: the kernel would have to wrap around to reuse it.
local dead = 4000000
local mine = vim.uv.os_getpid()
vim.fn.writefile({ "" }, ("%s/%d.duckdb"):format(scratch_dir, dead))
vim.fn.mkdir(("%s/%d"):format(results_dir, dead), "p")
vim.fn.writefile({ "a" }, ("%s/%d/r1.csv"):format(results_dir, dead))
vim.fn.writefile({ "" }, ("%s/%d.duckdb"):format(scratch_dir, mine))
vim.fn.mkdir(("%s/%d"):format(results_dir, mine), "p")

check("the dead session's scratch exists", vim.fn.filereadable(("%s/%d.duckdb"):format(scratch_dir, dead)), 1)
requery.setup()

check("it is gone afterwards", vim.fn.filereadable(("%s/%d.duckdb"):format(scratch_dir, dead)), 0)
check("and so are its results", vim.fn.isdirectory(("%s/%d"):format(results_dir, dead)), 0)
check(
	"while this session's scratch is left alone",
	vim.fn.filereadable(("%s/%d.duckdb"):format(scratch_dir, mine)),
	1
)
check("and its results folder too", vim.fn.isdirectory(("%s/%d"):format(results_dir, mine)), 1)

support.describe("scratch: and on exit this session cleans up after itself")
vim.api.nvim_exec_autocmds("VimLeavePre", { group = "NeogripScratch" })
check("the scratch is deleted", vim.fn.filereadable(requery.scratch_path()), 0)
check("and the results folder", vim.fn.isdirectory(("%s/%d"):format(results_dir, mine)), 0)
