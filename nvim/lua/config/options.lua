-- Options are automatically loaded before lazy.nvim startup
-- Default options that are always set: https://github.com/LazyVim/LazyVim/blob/main/lua/lazyvim/config/options.lua
-- Add any additional options here

if vim.g.neovide then
	if vim.fn.has("wsl") == 1 then
		if vim.fn.argc() == 0 then
			vim.api.nvim_set_current_dir(vim.env.HOME)
		end
		vim.g.neovide_title_background_color = "#1d2021"
		vim.g.neovide_title_text_color = "#ebdbb2"
	end

	vim.g.neovide_hide_mouse_when_typing = true
	vim.g.neovide_remember_window_size = true
	vim.g.neovide_corner_preference = "round"
	vim.g.neovide_position_animation_length = 0.10
	vim.g.neovide_scroll_animation_length = 0.20
	vim.g.neovide_cursor_animation_length = 0.08
	vim.g.neovide_cursor_short_animation_length = 0.03
	vim.g.neovide_cursor_vfx_mode = "railgun"
	vim.g.neovide_floating_corner_radius = 0.3
end

vim.g.root_spec = { ".git", "compose.yml", "cwd" }
vim.g.lazyvim_prettier_needs_config = true
vim.g.rust_recommended_style = "0"

vim.opt.linebreak = true
vim.opt.expandtab = false
vim.opt.formatoptions:remove({ "r", "o" })
vim.opt.tabstop = 3
vim.opt.shiftwidth = 3
vim.opt.scrolloff = 10
vim.opt.jumpoptions = "stack,view"
vim.opt.relativenumber = false
vim.opt.showbreak = "↪ "
vim.opt.listchars = {
	tab = " ➞ ",
	multispace = "·",
	trail = "·",
	extends = "»",
	precedes = "«",
}

-- vim.opt.guifont = "ComicShannsMono Nerd Font:h12"

if vim.fn.has("wsl") == 1 then
	local w32y = vim.fs.joinpath(vim.fn.getenv("HOME"), ".dotfiles", "bin", "win32yank.exe")
	vim.g.clipboard = {
		name = "WslClipboard",
		copy = {
			["+"] = w32y .. " -i --crlf",
			["*"] = w32y .. " -i --crlf",
		},
		paste = {
			["+"] = w32y .. " -o --lf",
			["*"] = w32y .. " -o --lf",
		},
		cache_enabled = false,
	}
	-- vim.g.clipboard = {
	-- 	name = "WslClipboard",
	-- 	copy = {
	-- 		["+"] = "clip.exe",
	-- 		["*"] = "clip.exe",
	-- 	},
	-- 	paste = {
	-- 		["+"] = 'powershell.exe -NoLogo -NoProfile -c [Console]::Out.Write($(Get-Clipboard -Raw).tostring().replace("`r", ""))',
	-- 		["*"] = 'powershell.exe -NoLogo -NoProfile -c [Console]::Out.Write($(Get-Clipboard -Raw).tostring().replace("`r", ""))',
	-- 	},
	-- 	cache_enabled = 0,
	-- }
end
