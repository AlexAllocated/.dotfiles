local function run(command, opts)
	local result = vim.system(command, opts):wait()
	if result.code ~= 0 then
		local stderr = vim.trim(result.stderr or "")
		local stdout = vim.trim(result.stdout or "")
		error(
			string.format(
				"markdown-preview.nvim build failed: %s\n%s",
				table.concat(command, " "),
				stderr ~= "" and stderr or stdout
			)
		)
	end
end

return {
	{
		"mfussenegger/nvim-lint",
		opts = function(_, opts)
			local lint = require("lint")
			opts.linters = opts.linters or {}
			-- Prose can wrap visually; keep all other project Markdown diagnostics.
			opts.linters["markdownlint-cli2"] = require("lint.util").wrap(
				lint.linters["markdownlint-cli2"],
				function(diagnostic)
					if not diagnostic.message:find("MD013/line-length", 1, true) then
						return diagnostic
					end
				end
			)
		end,
	},
	{
		"iamcco/markdown-preview.nvim",
		build = function(plugin)
			local app_dir = plugin.dir .. "/app"
			if vim.fn.isdirectory(app_dir .. "/node_modules/tslib") == 1 then
				return
			end

			if vim.fn.executable("bun") == 1 then
				run({ "bun", "install" }, { cwd = app_dir, text = true })
			elseif vim.fn.executable("npm") == 1 then
				run({ "npm", "install", "--omit=dev", "--no-package-lock", "--no-audit", "--no-fund" }, {
					cwd = app_dir,
					text = true,
				})
			else
				error("markdown-preview.nvim requires bun or npm to install app dependencies")
			end
		end,
	},
}
