return {
	"Wansmer/treesj",
	event = "BufEnter",
	keys = {
		{ "<space>cj", "<CMD>TSJToggle<CR>", desc = "Toggle Inline/Block" },
		-- { "<space>rj", "<CMD>TSJJoin<CR>", desc = "Inline" },
		-- { "<space>rs", "<CMD>TSJSplit<CR>", desc = "Block" },
	},
	dependencies = {
		"nvim-treesitter/nvim-treesitter",
	},
	opts = {
		use_default_keymaps = false,
		max_join_length = 10000,
	},
}
