local managed_macos = require("config.profile").managed_macos
local lock_name = managed_macos and "lazy-lock.macos-managed.json" or "lazy-lock.json"

local function resolve_lockfile()
	local configured = vim.env.DOTFILES_NVIM_AUTOMATION == "1" and vim.env.DOTFILES_NVIM_LOCKFILE or nil
	if configured ~= nil and configured ~= "" then
		return configured
	end

	-- An accepted editor release selects its own config root. Never redirect a
	-- normal editor launch into an unrelated writable developer checkout.
	local root = vim.env.DOTFILES_NVIM_CONFIG_ROOT or vim.fn.stdpath("config")
	local tracked = vim.fs.joinpath(root, lock_name)
	assert(vim.fn.filereadable(tracked) == 1, "Missing accepted Neovim lock: " .. tracked)
	return tracked
end

local lockfile = resolve_lockfile()
local pins = vim.json.decode(table.concat(vim.fn.readfile(lockfile), "\n"))
local lazypath = vim.fn.stdpath("data") .. "/lazy/lazy.nvim"
local plugin_pins = require("config.plugin_pins")
plugin_pins.bootstrap(lazypath, assert(pins["lazy.nvim"], "Missing lazy.nvim pin").commit)
vim.opt.rtp:prepend(lazypath)
if not (vim.env.DOTFILES_NVIM_AUTOMATION == "1" and vim.env.DOTFILES_NVIM_PLUGIN_UPDATE == "1") then
	plugin_pins.protect(lockfile)
end

local function resolve_lazyvim_json()
	local configured = vim.env.DOTFILES_NVIM_AUTOMATION == "1" and vim.env.DOTFILES_LAZYVIM_JSON or nil
	if configured ~= nil and configured ~= "" then
		return configured
	end

	local configured_lockfile = vim.env.DOTFILES_NVIM_AUTOMATION == "1" and vim.env.DOTFILES_NVIM_LOCKFILE or nil
	if configured_lockfile ~= nil and configured_lockfile ~= "" then
		local alongside_lockfile = vim.fs.joinpath(vim.fs.dirname(configured_lockfile), "lazyvim.json")
		if vim.fn.filewritable(alongside_lockfile) == 1 then
			return alongside_lockfile
		end
	end

	local root = vim.env.DOTFILES_NVIM_CONFIG_ROOT or vim.fn.stdpath("config")
	return vim.fs.joinpath(root, "lazyvim.json")
end

vim.g.lazyvim_json = resolve_lazyvim_json()
if managed_macos then
	local config = vim.json.decode(table.concat(vim.fn.readfile(vim.g.lazyvim_json), "\n"))
	config.extras = require("config.extras").filter(config.extras)
	local target = vim.fs.joinpath(vim.fn.stdpath("state"), "lazyvim.macos-managed.json")
	vim.fn.mkdir(vim.fs.dirname(target), "p")
	vim.fn.writefile({ vim.json.encode(config) }, target)
	vim.g.lazyvim_json = target
end

require("lazy").setup({
	lockfile = lockfile,
	ui = {
		border = "rounded",
	},
	rocks = {
		hererocks = true,
	},
	spec = {
		-- Import built-in LazyVim specs.
		{ "LazyVim/LazyVim", import = "lazyvim.plugins" },
		-- Override versions for lazy.nvim and LazyVim.
		{ "folke/lazy.nvim", version = false },
		{ "LazyVim/LazyVim", version = false },
		-- Import our own plugin specs.
		{ import = "plugins" },
	},
	defaults = {
		-- By default, only LazyVim plugins will be lazy-loaded. Your custom plugins will load during startup.
		-- If you know what you're doing, you can set this to `true` to have all your custom plugins lazy-loaded by default.
		lazy = true,
		-- It's recommended to leave version=false for now, since a lot the plugin that support versioning,
		-- have outdated releases, which may break your Neovim install.
		version = false, -- always use the latest git commit
		-- version = "*", -- try installing the latest stable version for plugins that support semver
	},
	install = { colorscheme = { "tokyonight", "catppuccin", "gruvbox" } },
	checker = {
		-- updoot updates and validates the tracked lockfile, then restores the
		-- active runtime from it. Avoid a second, unpinned network check during
		-- ordinary editor startup.
		enabled = false,
	},
	performance = {
		rtp = {
			-- disable some rtp plugins
			disabled_plugins = {
				"gzip",
				-- "matchit",
				-- "matchparen",
				-- "netrwPlugin",
				"tarPlugin",
				"tohtml",
				"tutor",
				"zipPlugin",
			},
		},
	},
})
