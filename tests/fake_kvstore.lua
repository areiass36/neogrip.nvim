-- An in-memory stand-in for kvstore.nvim with the same public surface, so the
-- suites can hand out secrets without a vault, a keystore or a prompt.
local M = {}

M.options = { backend = "fake", confirm_value = false }

local store = {}

function M.setup(opts)
	M.options = vim.tbl_deep_extend("force", M.options, opts or {})
	return M.options
end

function M.get(key, _opts)
	return store[key]
end

function M.set(key, value)
	store[key] = value
	return true
end

-- Test-only helper: suites seed and wipe the store through these rather than
-- reaching into module internals.
function M.reset(values)
	store = values or {}
end

return M
