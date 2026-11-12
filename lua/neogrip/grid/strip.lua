-- The tab strip, dressed as the native tab bar and hung on the result window's 'winbar'
-- (ADR-0045). It carries the strip and nothing else.
local registry = require("neogrip.grid.registry")

local M = {}

-- The strip is tighter than a buffer name: a cell about the size of a file name in the
-- native tab bar.
local STRIP_WIDTH = 18

--- Escape '%' so the text is safe inside a statusline-format string.
local function escape(text)
	return (tostring(text):gsub("%%", "%%%%"))
end

--- What names a tab in the strip: the statement it ran, or the buffer name's label.
local function tab_label(bufnr)
	local entry = registry.waiting[bufnr]
	local state = registry.states[bufnr]
	local statement = (entry and entry.statement) or (state and state.statement)
	if statement and statement.text then
		return registry.label_of(statement.text, STRIP_WIDTH)
	end
	local name = vim.api.nvim_buf_get_name(bufnr)
	return registry.label_of(name:match("([^/\\]+)$"), STRIP_WIDTH)
end

--- The tab strip in the native tabline's faces.
--- @param bufnr integer the tab on screen, the one marked active
--- @return string ready for 'winbar'
function M.text(bufnr)
	if #registry.tabs == 0 then
		return ""
	end
	local out = {}
	for index, tab in ipairs(registry.tabs) do
		local group = "NGripGridTab"
		local entry = registry.waiting[tab]
		if tab == bufnr then
			group = "NGripGridTabActive"
		elseif entry and entry.failed then
			group = "NGripGridTabError"
		elseif entry then
			group = "NGripGridTabRunning"
		end
		out[#out + 1] = ("%%#%s# %d %s "):format(group, index, escape(tab_label(tab)))
	end
	return table.concat(out, "") .. "%#NGripGridTabFill#"
end

--- Hang the strip on the result window as a literal string, never a `%!`
--- expression: assigning the option already marks the window for redraw (ADR-0045).
function M.paint()
	local winid = registry.window()
	if not winid then
		return
	end
	local text = M.text(vim.api.nvim_win_get_buf(winid))
	pcall(vim.api.nvim_set_option_value, "winbar", text, { win = winid, scope = "local" })
end

return M
