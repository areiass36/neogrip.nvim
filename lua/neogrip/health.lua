-- :checkhealth neogrip, answering from the same checks the doctor runs.
local M = {}

function M.check()
	local health = vim.health
	health.start("neogrip")

	if vim.fn.has("nvim-0.12") == 1 then
		health.ok("neovim 0.12+")
	else
		health.error("neovim 0.12 or newer is required")
	end

	if pcall(require, "kvstore") then
		health.ok("kvstore.nvim is available")
	else
		health.error("kvstore.nvim is missing", { "install areiass36/kvstore.nvim; it holds every secret" })
	end

	local jdk = require("neogrip.bootstrap.jdk")
	if jdk.installed() then
		health.ok("JDK: " .. jdk.java())
	else
		health.info("no JDK yet; it downloads on first connect (about 190 MB, once)")
	end

	local sidecar = require("neogrip.sidecar")
	if sidecar.compiled() then
		health.ok("sidecar compiled: " .. sidecar.classes_dir)
	else
		health.info("sidecar not compiled yet; it builds on first connect")
	end

	local count = #require("neogrip.connections").all()
	if count > 0 then
		health.ok(("%d connection(s) configured"):format(count))
	else
		health.warn("no connections configured", { "run :NGripInit to create .nvim/database.json" })
	end
end

return M
