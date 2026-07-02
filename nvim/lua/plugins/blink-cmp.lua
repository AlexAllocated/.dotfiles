return {
	"saghen/blink.cmp",
	optional = true,
	dependencies = {
		"moyiz/blink-emoji.nvim",
	},
	opts = function(_, opts)
		opts.enabled = function()
			return not vim.tbl_contains({ "copilot-chat" }, vim.bo.filetype)
				and vim.bo.buftype ~= "prompt"
				and vim.b.completion ~= false
		end

		opts.sources.providers.emoji = {
			module = "blink-emoji",
			name = "Emoji",
			score_offset = 15,
			opts = { insert = true },
		}
		table.insert(opts.sources.default, "emoji")

		return opts
	end,
}
