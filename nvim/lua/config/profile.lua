local marker = vim.fn.expand("~/.local/share/dotfiles/profile")
local profile = vim.env.DOTFILES_PROFILE
if not profile and vim.fn.filereadable(marker) == 1 then
	profile = vim.fn.readfile(marker)[1]
end
return { managed_macos = profile == "macos-managed" }
