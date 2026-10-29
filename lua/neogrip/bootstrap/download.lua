-- Download a pinned artifact with curl, verify its SHA-256, then install it.
-- Nothing from a downloaded file is extracted or executed before its checksum
-- passes (ADR-0005, ADR-0006). curl and tar ship with macOS, Linux and
-- Windows 10+; the macOS and Windows tar also open .zip files.
local platform = require("neogrip.bootstrap.platform")
local neogrip = require("neogrip")

local M = {}

local in_flight = {}
local gnu_tar = nil

--- GNU tar needs --wildcards before a pattern; bsdtar (macOS, Windows) matches
--- patterns on its own and does not know the flag.
local function wildcards_flag()
	if gnu_tar == nil then
		local version = vim.system({ "tar", "--version" }, { text = true }):wait()
		gnu_tar = ((version.stdout or "") .. (version.stderr or "")):find("GNU tar") ~= nil
	end
	return gnu_tar and { "--wildcards" } or {}
end

--- Hash a file with the hashing tool the OS ships, because reading a 190 MB
--- archive into a Lua string just to hash it would double its cost in memory.
--- @param path string
--- @param callback fun(digest: string|nil, err: string|nil)
function M.sha256_of(path, callback)
	local command
	if platform.is_windows then
		command = { "certutil", "-hashfile", path, "SHA256" }
	elseif vim.fn.executable("sha256sum") == 1 then
		command = { "sha256sum", path }
	elseif vim.fn.executable("shasum") == 1 then
		command = { "shasum", "-a", "256", path }
	else
		return callback(nil, "no SHA-256 tool found (sha256sum or shasum)")
	end
	vim.system(
		command,
		{ text = true },
		vim.schedule_wrap(function(result)
			if result.code ~= 0 then
				return callback(nil, "hashing failed: " .. (result.stderr or ""))
			end
			-- certutil prints a header line, the digest, and a footer; the
			-- unix tools print "<digest>  <path>". The digest is the first
			-- run of exactly 64 hex characters either way.
			local digest = nil
			for candidate in (result.stdout or ""):lower():gmatch("%x+") do
				if #candidate == 64 then
					digest = candidate
					break
				end
			end
			if not digest then
				return callback(nil, "could not read a digest from the hashing tool's output")
			end
			callback(digest, nil)
		end)
	)
end

local function verify(name, path, sha256, on_done)
	M.sha256_of(path, function(digest, err)
		if not digest then
			pcall(vim.fn.delete, path)
			neogrip.notify(("could not verify %s: %s"):format(name, err), vim.log.levels.ERROR)
			return on_done(false)
		end
		if digest ~= sha256:lower() then
			-- A wrong checksum is a wrong artifact; keeping it would invite a
			-- retry to "fix" it by running it anyway.
			pcall(vim.fn.delete, path)
			neogrip.notify(
				("checksum mismatch for %s: expected %s, got %s"):format(name, sha256, digest),
				vim.log.levels.ERROR
			)
			return on_done(false)
		end
		on_done(true)
	end)
end

local function fetch(name, url, destination, on_done)
	-- Downloaded next to the target and moved or extracted from there, so an
	-- interrupted download never leaves something that looks installed.
	local curl = { "curl", "-fsSL", "-o", destination, url }
	if platform.is_windows then
		-- Corporate TLS inspection (e.g. Cloudflare WARP) serves certificates
		-- without revocation info, which Windows curl (schannel) rejects.
		table.insert(curl, 2, "--ssl-revoke-best-effort")
	end
	vim.system(
		curl,
		{},
		vim.schedule_wrap(function(result)
			if result.code ~= 0 then
				pcall(vim.fn.delete, destination)
				neogrip.notify(
					("failed to download %s: %s"):format(name, result.stderr or ""),
					vim.log.levels.ERROR
				)
				return on_done(false)
			end
			on_done(true)
		end)
	)
end

--- Fetch a single file - a JDBC driver is a jar, which is the artifact itself.
--- @param name string label for notifications and in-flight deduplication
--- @param url string
--- @param sha256 string pinned digest the download must match
--- @param destination string full path of the file to write
--- @param on_done fun(ok: boolean)
function M.file(name, url, sha256, destination, on_done)
	if in_flight[name] then
		table.insert(in_flight[name], on_done)
		return
	end
	in_flight[name] = { on_done }
	local function finish(ok)
		local callbacks = in_flight[name]
		in_flight[name] = nil
		for _, callback in ipairs(callbacks) do
			callback(ok)
		end
	end

	vim.fn.mkdir(vim.fs.dirname(destination), "p")
	local partial = destination .. ".part"
	fetch(name, url, partial, function(fetched)
		if not fetched then
			return finish(false)
		end
		verify(name, partial, sha256, function(verified)
			if not verified then
				return finish(false)
			end
			local renamed = vim.uv.fs_rename(partial, destination) ~= nil
			if renamed then
				neogrip.notify(name .. " ready")
			else
				pcall(vim.fn.delete, partial)
			end
			finish(renamed)
		end)
	end)
end

--- Fetch an archive, verify it, then extract into destination.
--- @param name string label for notifications and in-flight deduplication
--- @param url string
--- @param sha256 string pinned digest the archive must match before extraction
--- @param destination string directory to extract into
--- @param strip_components integer leading path components to drop
--- @param on_done fun(ok: boolean)
--- @param members string[]|nil only extract these archive members
function M.archive(name, url, sha256, destination, strip_components, on_done, members)
	if in_flight[name] then
		table.insert(in_flight[name], on_done)
		return
	end
	in_flight[name] = { on_done }
	local function finish(ok)
		local callbacks = in_flight[name]
		in_flight[name] = nil
		for _, callback in ipairs(callbacks) do
			callback(ok)
		end
	end

	local temp_dir = neogrip.data_dir .. "/.download-" .. name:gsub("[^%w._-]", "_")
	vim.fn.delete(temp_dir, "rf")
	vim.fn.mkdir(temp_dir, "p")
	local archive = temp_dir .. "/" .. url:match("[^/]+$")

	neogrip.notify("downloading " .. name .. "...")
	fetch(name, url, archive, function(fetched)
		if not fetched then
			vim.fn.delete(temp_dir, "rf")
			return finish(false)
		end
		verify(name, archive, sha256, function(verified)
			if not verified then
				vim.fn.delete(temp_dir, "rf")
				return finish(false)
			end

			local tar = { "tar", "-xf", archive, "-C", destination }
			if strip_components > 0 then
				table.insert(tar, "--strip-components=" .. strip_components)
			end
			if members and #members > 0 then
				vim.list_extend(tar, wildcards_flag())
				vim.list_extend(tar, members)
			end
			vim.fn.mkdir(destination, "p")

			vim.system(
				tar,
				{},
				vim.schedule_wrap(function(extract)
					vim.fn.delete(temp_dir, "rf")
					vim.fn.delete(destination .. "/__MACOSX", "rf")
					if extract.code ~= 0 then
						neogrip.notify(
							"failed to extract " .. name .. ": " .. (extract.stderr or ""),
							vim.log.levels.ERROR
						)
						return finish(false)
					end
					neogrip.notify(name .. " ready")
					finish(true)
				end)
			)
		end)
	end)
end

return M
