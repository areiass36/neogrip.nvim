-- Test bootstrap: the repository on the runtime path, with kvstore replaced
-- by an in-memory fake so no test can ever touch a real keystore.
local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
-- The user's config must not leak in: locally it masked a stale require that only failed on CI.
vim.opt.rtp:remove(vim.fn.stdpath("config"))
vim.opt.rtp:remove(vim.fn.stdpath("config") .. "/after")
vim.opt.rtp:prepend(root)
package.path = root .. "/?.lua;" .. root .. "/lua/?.lua;" .. root .. "/lua/?/init.lua;" .. package.path

package.preload["kvstore"] = function()
	return dofile(root .. "/tests/fake_kvstore.lua")
end
