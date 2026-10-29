-- The checksum discipline without a network: hashing matches vim.fn.sha256,
-- a verified download installs, and a wrong digest refuses to install and
-- leaves nothing behind. curl reads file:// urls, so the "download" is local.
local support = require("tests.support")
local download = require("neogrip.bootstrap.download")

support.describe("bootstrap download")

local temp_root = vim.fn.tempname()
vim.fn.mkdir(temp_root, "p")

local content = "neogrip checksum probe\n"
local source = temp_root .. "/artifact.bin"
vim.fn.writefile({ content:sub(1, -2) }, source)
local expected = vim.fn.sha256(table.concat(vim.fn.readfile(source, "b"), "\n"))

local digest, digest_err = support.sync(function(done)
	download.sha256_of(source, done)
end)
support.check("hashing a file reports no error", digest_err, nil)
support.check("the digest matches vim.fn.sha256 of the content", digest, expected)

local url = "file:///" .. source:gsub("\\", "/")

local good_destination = temp_root .. "/installed.bin"
local ok = support.sync(function(done)
	download.file("probe-good", url, expected, good_destination, done)
end)
support.check("a verified download installs", ok, true)
support.check("the installed file exists", vim.fn.filereadable(good_destination), 1)

local bad_destination = temp_root .. "/refused.bin"
local refused = support.sync(function(done)
	download.file("probe-bad", url, string.rep("0", 64), bad_destination, done)
end)
support.check("a wrong digest refuses to install", refused, false)
support.check("nothing is left at the destination", vim.fn.filereadable(bad_destination), 0)
support.check("no partial file is left either", vim.fn.filereadable(bad_destination .. ".part"), 0)

vim.fn.delete(temp_root, "rf")
