-- A JVM that belongs to this plugin and to nothing else.
--
-- Whatever `java` happens to be on PATH would make the plugin depend on the
-- user's toolchain - a version manager with no version selected, a JRE without
-- javac, a JDK 8 from years ago - so a Temurin JDK is downloaded into the
-- plugin's data directory and that one is used, always. A JDK rather than a
-- JRE because the sidecar is compiled on first use (ADR-0004).
--
-- Releases are pinned to exact artifacts with their SHA-256, taken from the
-- Adoptium API on 2026-10-29, because "latest" cannot be checksummed
-- (ADR-0005). Bumping means updating url and sha256 together.
local platform = require("neogrip.bootstrap.platform")
local download = require("neogrip.bootstrap.download")
local neogrip = require("neogrip")

local GITHUB = "https://github.com/adoptium/temurin21-binaries/releases/download"
local RELEASES = {
	linux = {
		x64 = {
			url = GITHUB .. "/jdk-21.0.13%2B9/OpenJDK21U-jdk_x64_linux_hotspot_21.0.13_9.tar.gz",
			sha256 = "d7f5d5cf865a2902b70ff549b97586a7d3f234e016f041ab447ea740c7d66d1c",
		},
		arm64 = {
			url = GITHUB .. "/jdk-21.0.13%2B9/OpenJDK21U-jdk_aarch64_linux_hotspot_21.0.13_9.tar.gz",
			sha256 = "e3522e707fc7dbe2a72c30746b1e7068301a0213ecd213d4491f35a14eb55578",
		},
	},
	mac = {
		x64 = {
			url = GITHUB .. "/jdk-21.0.13%2B9/OpenJDK21U-jdk_x64_mac_hotspot_21.0.13_9.tar.gz",
			sha256 = "9aa1d1c17ae5467a022679e7e0af5c00797d94ac462ed1a46f4db07a8a34a6dd",
		},
		arm64 = {
			url = GITHUB .. "/jdk-21.0.13%2B9/OpenJDK21U-jdk_aarch64_mac_hotspot_21.0.13_9.tar.gz",
			sha256 = "bf036b35b071bfb2f54f2c0af8ee8d88afa95ee6eb3dce02c0f94cfc2524d04a",
		},
	},
	windows = {
		-- Temurin's Windows build lags the others by a patch level; each
		-- target pins the artifact that actually exists for it.
		x64 = {
			url = GITHUB .. "/jdk-21.0.12.1%2B1/OpenJDK21U-jdk_x64_windows_hotspot_21.0.12.1_1.zip",
			sha256 = "f9d6e191ab098c0d416e7d588a24420a8621cd2f4720dab2459b8b7b2d2d8b4e",
		},
	},
}

local M = {}

M.dir = neogrip.data_dir .. "/jdk"

--- The layout differs: macOS nests the runtime under Contents/Home. CI and
--- tests can point NEOGRIP_TEST_JDK at an existing JDK to skip the download.
--- @return string|nil
local function find_executable(name)
	local roots = { vim.env.NEOGRIP_TEST_JDK, M.dir }
	for _, root in ipairs(roots) do
		if root and root ~= "" then
			local candidates = {
				("%s/bin/%s%s"):format(root, name, platform.exe_suffix),
				("%s/Contents/Home/bin/%s%s"):format(root, name, platform.exe_suffix),
			}
			for _, path in ipairs(candidates) do
				if vim.fn.executable(path) == 1 then
					return path
				end
			end
		end
	end
	return nil
end

--- @return string|nil path to java
function M.java()
	return find_executable("java")
end

--- @return string|nil path to javac, needed to build the sidecar
function M.javac()
	return find_executable("javac")
end

function M.installed()
	return M.java() ~= nil and M.javac() ~= nil
end

--- @param on_done fun(ok: boolean)
function M.ensure(on_done)
	on_done = on_done or function() end
	if M.installed() then
		return on_done(true)
	end

	local os_name, arch = platform.detect()
	local release = RELEASES[os_name] and RELEASES[os_name][arch]
	if not release then
		neogrip.notify(("no pinned Temurin JDK for %s/%s"):format(os_name, arch), vim.log.levels.WARN)
		return on_done(false)
	end

	neogrip.notify("downloading a JDK for the sidecar (about 190 MB, once)")
	-- The archive has a single jdk-<version> directory at its root.
	download.archive("temurin jdk", release.url, release.sha256, M.dir, 1, function(ok)
		if ok and not M.installed() then
			neogrip.notify("the JDK archive extracted but no java was found in it", vim.log.levels.ERROR)
			return on_done(false)
		end
		on_done(ok)
	end)
end

return M
