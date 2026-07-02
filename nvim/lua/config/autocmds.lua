-- Autocmds are automatically loaded on the VeryLazy event
-- Default autocmds that are always set: https://github.com/LazyVim/LazyVim/blob/main/lua/lazyvim/config/autocmds.lua
-- Add any additional autocmds here

local function augroup(name)
	return vim.api.nvim_create_augroup("chev_" .. name, { clear = true })
end

vim.api.nvim_create_autocmd("BufEnter", {
	callback = function()
		vim.opt.formatoptions:remove({ "c", "r", "o" })
	end,
	group = augroup("no_comment_new_line"),
	desc = "Disable New Line Comment",
})

vim.api.nvim_create_autocmd("FileType", {
	pattern = { "markdown", "json" },
	callback = function()
		vim.opt.expandtab = true
	end,
	group = augroup("markdown_expandtab"),
	desc = "Set expandtab for markdown files",
})
