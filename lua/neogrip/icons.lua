-- The handful of glyphs the explorer and documents draw. Plain Unicode that
-- every monospace font carries - no icon font required - and overridable from
-- setup({ icons = { ... } }).
local config = require("neogrip.config")

local DEFAULTS = {
	database = "◆",
	folder = "▸",
	table = "▪",
	file = "·",
	branch = "└",
	check = "ok",
	cross = "!!",
}

local M = setmetatable({}, {
	__index = function(_, key)
		local configured = config.get().icons
		if type(configured) == "table" and configured[key] ~= nil then
			return configured[key]
		end
		return DEFAULTS[key]
	end,
})

return M
