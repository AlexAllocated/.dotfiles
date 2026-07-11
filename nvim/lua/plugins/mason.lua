return {
	"mason-org/mason.nvim",
	optional = true,
	build = false,
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
		if vim.env.DOTFILES_NVIM_PIN_UPDATE == "1" then
			opts.ensure_installed = {}
		elseif not vim.tbl_contains(opts.ensure_installed, "rust-analyzer") then
			table.insert(opts.ensure_installed, "rust-analyzer")
		end
		opts.ui = vim.tbl_deep_extend("force", opts.ui or {}, {
			border = "rounded",
		})
	end,
	config = function(_, opts)
		require("mason").setup(opts)
		if vim.env.DOTFILES_NVIM_PIN_UPDATE == "1" then
			return
		end

		local registry = require("mason-registry")
		registry:on("package:install:success", function()
			vim.defer_fn(function()
				require("lazy.core.handler.event").trigger({
					event = "FileType",
					buf = vim.api.nvim_get_current_buf(),
				})
			end, 100)
		end)
		registry.refresh(function()
			for _, tool in ipairs(opts.ensure_installed) do
				local package = registry.get_package(tool)
				if not package:is_installed() and not package:is_installing() then
					package:install()
				end
			end
		end)
	end,
	-- { "mason-org/mason.nvim", version = "^1.0.0" },
	-- { "mason-org/mason-lspconfig.nvim", version = "^1.0.0" },
}
