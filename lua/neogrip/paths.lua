local M = {}

M.state_dir = vim.fn.stdpath("state") .. "/neogrip"

-- Artifacts and compiled classes live apart from state, so wiping one never costs the other.
M.data_dir = vim.fn.stdpath("data") .. "/neogrip"

return M
