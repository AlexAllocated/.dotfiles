-- This small entrypoint remains in the system/Home Manager generation. A
-- separately accepted editor release owns the specs and pins used after it.
local root = vim.env.DOTFILES_NVIM_CONFIG_ROOT
if vim.env.DOTFILES_NVIM_AUTOMATION ~= "1" then
	root = nil
	local state = vim.env.DOTCTL_STATE_HOME
		or vim.fs.joinpath(vim.env.XDG_STATE_HOME or vim.fn.expand("~/.local/state"), "dotfiles")
	local pointer = vim.fs.joinpath(state, "active-editor.json")
	if vim.fn.filereadable(pointer) == 1 then
		local value = vim.json.decode(table.concat(vim.fn.readfile(pointer), "\n"))
		assert(value.schema_version == 1 and type(value.profiles) == "table", "Invalid accepted editor receipt")
		local profile = vim.env.DOTFILES_PROFILE
		local marker = vim.fn.expand("~/.local/share/dotfiles/profile")
		if not profile and vim.fn.filereadable(marker) == 1 then
			profile = vim.fn.readfile(marker)[1]
		end
		local selected = value.profiles[profile == "macos-managed" and "macos-managed" or "default"]
		if selected then
			assert(type(selected.root) == "string", "Accepted editor receipt has no source path")
			root = vim.fs.joinpath(selected.root, "nvim")
			assert(
				vim.fn.filereadable(vim.fs.joinpath(root, "init.lua")) == 1,
				"Accepted editor source is missing: " .. root
			)
		end
	end
end
root = root or vim.fn.stdpath("config")
vim.env.DOTFILES_NVIM_CONFIG_ROOT = root
vim.g.dotfiles_editor_root = root
vim.opt.rtp:prepend(root)
package.path = root .. "/lua/?.lua;" .. root .. "/lua/?/init.lua;" .. package.path
require("config.lazy")
