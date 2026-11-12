-- Facts about the operating system, shared by every module that touches paths
-- or external processes.
local M = {}

M.is_windows = vim.fn.has("win32") == 1
M.exe_suffix = M.is_windows and ".exe" or ""
M.path_separator = M.is_windows and ";" or ":"

--- @return string os_name "windows" | "mac" | "linux" | raw sysname
--- @return string arch "x64" | "arm64" | raw machine name
function M.detect()
	local uname = vim.uv.os_uname()
	local is_arm = uname.machine == "arm64" or uname.machine == "aarch64"
	local arch = is_arm and "arm64" or "x64"
	if M.is_windows then
		return "windows", arch
	elseif uname.sysname == "Darwin" then
		return "mac", arch
	elseif uname.sysname == "Linux" then
		return "linux", arch
	end
	return uname.sysname, uname.machine
end

return M
