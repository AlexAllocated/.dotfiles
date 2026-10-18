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
		if not vim.tbl_contains(opts.ensure_installed, "rust-analyzer") then
			table.insert(opts.ensure_installed, "rust-analyzer")
		end
		if vim.env.DOTFILES_NVIM_MASON_UPDATE ~= "1" then
			local _, registry = require("config.bootstrap").read_mason_lock()
			opts.registries = { "github:mason-org/mason-registry@" .. registry.version }
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
			local ok, pins = pcall(require("config.bootstrap").read_mason_lock)
			if not ok then
				vim.notify(pins, vim.log.levels.WARN)
				return
			end
			for tool, version in pairs(pins) do
				local package = registry.get_package(tool)
				if not package:is_installed() and not package:is_installing() then
					package:install({ version = version })
				end
			end
		end)
	end,
	-- { "mason-org/mason.nvim", version = "^1.0.0" },
	-- { "mason-org/mason-lspconfig.nvim", version = "^1.0.0" },
}
