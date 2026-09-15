-- Extras that managed company machines must not load. Kept as a pure Lua module,
-- free of vim APIs, so tests/macos-managed.bash can exercise it without Neovim.
local M = {}

-- Copilot-backed assistants stay off company hardware.
M.blocked_prefixes = { "lazyvim.plugins.extras.ai." }

-- nil_ls is built from source by Mason, and nil's build script shells out to
-- `nix` to enumerate builtins. The managed profile never installs Nix, so the
-- cargo build fails on every startup that touches a Nix buffer.
M.blocked_extras = { ["lazyvim.plugins.extras.lang.nix"] = true }

local function is_blocked(extra)
	if M.blocked_extras[extra] then
		return true
	end
	for _, prefix in ipairs(M.blocked_prefixes) do
		if extra:sub(1, #prefix) == prefix then
			return true
		end
	end
	return false
end

function M.filter(extras)
	local kept = {}
	for _, extra in ipairs(extras) do
		if not is_blocked(extra) then
			kept[#kept + 1] = extra
		end
	end
	return kept
end

return M
