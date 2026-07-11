return {
	{
		"nvim-treesitter/nvim-treesitter",
		build = false,
		cmd = {
			"TSInstall",
			"TSInstallFromGrammar",
			"TSInstallSync",
			"TSLog",
			"TSUninstall",
			"TSUpdate",
			"TSUpdateSync",
		},
		opts = function(_, opts)
			opts = opts or {}
			if vim.env.DOTFILES_NVIM_PIN_UPDATE == "1" then
				opts.ensure_installed = {}
			end
			if vim.fn.exists(":TSUpdateSync") == 0 then
				vim.api.nvim_create_user_command("TSUpdateSync", function(args)
					require("nvim-treesitter.install").update(args.fargs, { summary = true })
				end, {
					nargs = "*",
					bar = true,
					desc = "Update treesitter parsers synchronously",
				})
			end
			if #vim.api.nvim_list_uis() == 0 then
				opts.sync_install = true
			end
			return opts
		end,
	},
}
