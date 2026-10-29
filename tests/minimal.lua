-- The whole test bootstrap: the repository on the runtime path, no plugin
-- manager, so the suites exercise the modules rather than a loader. kvstore is
-- replaced by an in-memory fake so no test can ever touch a real keystore.
local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
-- The user's own config must not leak into the suites: locally it masked a
-- stale require that only failed on the bare CI runner.
vim.opt.rtp:remove(vim.fn.stdpath("config"))
vim.opt.rtp:remove(vim.fn.stdpath("config") .. "/after")
vim.opt.rtp:prepend(root)
package.path = root .. "/?.lua;" .. root .. "/lua/?.lua;" .. root .. "/lua/?/init.lua;" .. package.path

package.preload["kvstore"] = function()
	return dofile(root .. "/tests/fake_kvstore.lua")
end
