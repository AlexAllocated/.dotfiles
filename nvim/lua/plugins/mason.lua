return {
	"mason-org/mason.nvim",
	optional = true,
	build = vim.env.DOTFILES_NVIM_AUTOMATION == "1" and false or nil,
	cmd = {
		"Mason",
		"MasonInstall",
		"MasonUninstall",
		"MasonUninstallAll",
		"MasonUpdate",
		"MasonLog",
	},
	opts = function(_, opts)
		opts.PATH = "append"
		opts.ensure_installed = opts.ensure_installed or {}
		if not vim.tbl_contains(opts.ensure_installed, "rust-analyzer") then
			table.insert(opts.ensure_installed, "rust-analyzer")
		end
		opts.ui = vim.tbl_deep_extend("force", opts.ui or {}, {
			border = "rounded",
		})
	end,
	-- { "mason-org/mason.nvim", version = "^1.0.0" },
	-- { "mason-org/mason-lspconfig.nvim", version = "^1.0.0" },
}
