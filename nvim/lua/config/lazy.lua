local lazypath = vim.fn.stdpath("data") .. "/lazy/lazy.nvim"
if not (vim.uv or vim.loop).fs_stat(lazypath) then
	local lazyrepo = "https://github.com/folke/lazy.nvim.git"
	local out = vim.fn.system({ "git", "clone", "--filter=blob:none", "--branch=stable", lazyrepo, lazypath })
	if vim.v.shell_error ~= 0 then
		vim.api.nvim_echo({
			{ "Failed to clone lazy.nvim:\n", "ErrorMsg" },
			{ out, "WarningMsg" },
			{ "\nPress any key to exit..." },
		}, true, {})
		vim.fn.getchar()
		os.exit(1)
	end
end
vim.opt.rtp:prepend(lazypath)

local function resolve_lockfile()
	local configured = vim.env.DOTFILES_NVIM_LOCKFILE
	if configured ~= nil and configured ~= "" then
		return configured
	end

	local root = vim.env.DOTFILES_ROOT
	if root == nil or root == "" then
		root = vim.fs.joinpath(vim.fn.expand("~"), ".dotfiles")
	end
	local tracked = vim.fs.joinpath(root, "nvim", "lazy-lock.json")
	if vim.fn.filewritable(tracked) == 1 then
		return tracked
	end

	local generated = vim.fs.joinpath(vim.fn.stdpath("config"), "lazy-lock.json")
	if vim.fn.filewritable(generated) == 1 then
		return generated
	end

	local state = vim.fs.joinpath(vim.fn.stdpath("state"), "lazy-lock.json")
	vim.fn.mkdir(vim.fs.dirname(state), "p")
	if vim.fn.filereadable(state) == 0 and vim.fn.filereadable(generated) == 1 then
		vim.fn.writefile(vim.fn.readfile(generated, "b"), state, "b")
	end
	return state
end

local function resolve_lazyvim_json()
	local configured = vim.env.DOTFILES_LAZYVIM_JSON
	if configured ~= nil and configured ~= "" then
		return configured
	end

	local configured_lockfile = vim.env.DOTFILES_NVIM_LOCKFILE
	if configured_lockfile ~= nil and configured_lockfile ~= "" then
		local alongside_lockfile = vim.fs.joinpath(vim.fs.dirname(configured_lockfile), "lazyvim.json")
		if vim.fn.filewritable(alongside_lockfile) == 1 then
			return alongside_lockfile
		end
	end

	local root = vim.env.DOTFILES_ROOT
	if root == nil or root == "" then
		root = vim.fs.joinpath(vim.fn.expand("~"), ".dotfiles")
	end
	local tracked = vim.fs.joinpath(root, "nvim", "lazyvim.json")
	if vim.fn.filewritable(tracked) == 1 then
		return tracked
	end

	local generated = vim.fs.joinpath(vim.fn.stdpath("config"), "lazyvim.json")
	if vim.fn.filewritable(generated) == 1 then
		return generated
	end

	local state = vim.fs.joinpath(vim.fn.stdpath("state"), "lazyvim.json")
	vim.fn.mkdir(vim.fs.dirname(state), "p")
	if vim.fn.filereadable(state) == 0 and vim.fn.filereadable(generated) == 1 then
		vim.fn.writefile(vim.fn.readfile(generated, "b"), state, "b")
	end
	return state
end

vim.g.lazyvim_json = resolve_lazyvim_json()

require("lazy").setup({
	lockfile = resolve_lockfile(),
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
		enabled = true, -- check for plugin updates periodically
		notify = false, -- notify on update
	}, -- automatically check for plugin updates
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
