local function system_exepath(cmd)
	local path_sep = package.config:sub(1, 1) == "\\" and ";" or ":"
	local path_parts = vim.split(vim.env.PATH or "", path_sep, { plain = true, trimempty = true })
	local mason_bin = (vim.fn.stdpath("data") .. "/mason/bin"):gsub("[/\\]+$", "")

	for _, dir in ipairs(path_parts) do
		local normalized_dir = dir:gsub("[/\\]+$", "")
		if normalized_dir ~= mason_bin then
			local candidate = normalized_dir .. "/" .. cmd
			if vim.fn.executable(candidate) == 1 then
				return candidate
			end
			local windows_candidate = candidate .. ".exe"
			if vim.fn.has("win32") == 1 and vim.fn.executable(windows_candidate) == 1 then
				return windows_candidate
			end
		end
	end
end

local marksman = system_exepath("marksman")

return {
	{
		"neovim/nvim-lspconfig",
		opts = {
			diagnostics = {
				virtual_text = false,
				virtual_lines = true,
				float = {
					header = false,
					border = "rounded",
				},
			},
			inlay_hints = { enabled = false },
			setup = {
				-- Hack to suppress encoding error with clangd.
				clangd = function(_, opts)
					opts.capabilities.offsetEncoding = { "utf-16" }
				end,
			},
			servers = {
				marksman = marksman and {
					mason = false,
					cmd = { marksman, "server" },
				} or {
					enabled = false,
					mason = false,
				},
			},
		},
	},
}
