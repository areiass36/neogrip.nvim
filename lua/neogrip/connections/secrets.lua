-- Secrets are read from kvstore.nvim at connect time and handed over; nothing is cached here.
local M = {}

--- Resolve kvstore references into an auth table for the connect request; the callback shape
--- stays asynchronous so the runner never has to know the read is synchronous today.
--- @param connection table
--- @param callback fun(auth: table|nil, err: string|nil)
function M.resolve(connection, callback)
	local source = connection.auth or { type = "none" }
	local auth =
		{ type = source.type, user = source.user, client_id = source.client_id, tenant = source.tenant }

	local ok, kvstore = pcall(require, "kvstore")
	for field, reference in pairs(source) do
		if type(reference) == "table" and reference.kvstore then
			if not ok then
				return callback(nil, "kvstore.nvim is not available; it holds every secret")
			end
			local value = kvstore.get(reference.kvstore)
			if value == nil then
				return callback(
					nil,
					("no value stored for kvstore key %q; store it with :KVStore %s"):format(
						reference.kvstore,
						reference.kvstore
					)
				)
			end
			auth[field] = value
		end
	end
	callback(auth, nil)
end

return M
