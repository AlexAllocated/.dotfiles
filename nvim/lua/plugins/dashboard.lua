return {
	"folke/snacks.nvim",
	optional = true,
	opts = function(_, opts)
		-- Find the color of strings in the current theme and use it as dashboard header color.
		local string_hl = vim.api.nvim_get_hl(0, { name = "String", link = false })
		vim.api.nvim_set_hl(0, "SnacksDashboardHeader", { fg = string_hl.fg })

		-- Define function to pick logo based on working directory.
		local function pickLogo()
			-- local filepath = vim.fn.getcwd() or ""
			-- local hostname = vim.fn.hostname() or ""
			-- if string.match(filepath .. hostname, "") then
			-- 	return [[
			-- 	]]
			-- else
			-- 			return [[
			--  ██████╗██╗  ██╗███████╗██╗   ██╗
			-- ██╔════╝██║  ██║██╔════╝██║   ██║
			-- ██║     ███████║█████╗  ██║   ██║
			-- ██║     ██╔══██║██╔══╝  ╚██╗ ██╔╝
			-- ╚██████╗██║  ██║███████╗ ╚████╔╝
			--  ╚═════╝╚═╝  ╚═╝╚══════╝  ╚═══╝
			-- 			]]
			return [[
   ░███    ░██             ░██    ░██ 
  ░██░██   ░██              ░██  ░██  
 ░██  ░██  ░██               ░██░██   
░█████████ ░██     ░██████    ░███    
░██    ░██ ░██               ░██░██   
░██    ░██ ░██              ░██  ░██  
░██    ░██ ░███████        ░██    ░██ 
			]]
			-- end
		end

		-- Retrieve relevant logo and set it as dashboard header.
		local logo = pickLogo()
		opts.dashboard.preset.header = logo
		return opts
	end,
}
