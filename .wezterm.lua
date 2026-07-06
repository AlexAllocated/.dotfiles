require("color_schemes")
require("events")
require("keymaps")
require("mousemaps")

local wezterm = require("wezterm")
local config = require("config")

local color_schemes = wezterm.get_builtin_color_schemes()
for k, v in pairs(config.color_schemes) do
	color_schemes[k] = v
end

-- config.color_scheme = "Tokyo Night Storm"
-- config.color_scheme = "Tokyo Night Moon"
-- config.color_scheme = "Tokyo Night"
-- config.color_scheme = "Catppuccin Frappe"
-- config.color_scheme = "Catppuccin Macchiato"
-- config.color_scheme = "Catppuccin Mocha"
config.color_scheme = "GruvboxDarkHard"
-- config.color_scheme = "Matrix (terminal.sexy)"

config.font_size = 14
config.font = wezterm.font_with_fallback({
	-- { family = "BigBlueTermPlus Nerd Font", weight = "Regular" },
	{ family = "BigBlueTerm437 Nerd Font", weight = "Bold" },
	-- { family = "Cartograph CF", weight = "Bold" },
	-- { family = "ComicShannsMono Nerd Font", weight = "Regular" },
	-- { family = "Comic Shanns", weight = "Regular" },
	-- { family = "Fira Code", weight = "Regular" },
	-- { family = "ProggyClean Nerd Font", weight = "Regular" },
	-- { family = "ShureTechMono Nerd Font", weight = "Regular" },
	-- { family = "Terminess Nerd Font", weight = "Bold" },
})

config.adjust_window_size_when_changing_font_size = false
config.bold_brightens_ansi_colors = "BrightAndBold"
config.default_cursor_style = "BlinkingBlock"
config.enable_scroll_bar = false
-- config.enable_wayland = true
config.exit_behavior_messaging = "Verbose"
config.front_end = "WebGpu" -- ["OpenGL", "Software", "WebGpu"]
config.hide_mouse_cursor_when_typing = true
config.hide_tab_bar_if_only_one_tab = false
-- config.macos_window_background_blur = 0
config.max_fps = 240
config.mouse_wheel_scrolls_tabs = false
config.native_macos_fullscreen_mode = true
config.scrollback_lines = 10000
config.show_tab_index_in_tab_bar = true
config.tab_bar_at_bottom = false
-- config.term = "wezterm"
config.use_fancy_tab_bar = true
config.webgpu_power_preference = "HighPerformance"
-- config.webgpu_preferred_adapter = wezterm.gui.enumerate_gpus()[2]
-- config.window_background_opacity = 1
-- config.window_close_confirmation = "NeverPrompt"
config.window_decorations = "INTEGRATED_BUTTONS|RESIZE"
-- config.window_padding = { left = 10, right = 10, top = 25, bottom = 10 }
config.window_padding = { left = 0, right = 0, top = 10, bottom = 0 }

-- Determine system path.
local wallpaper_path = "~/.dotfiles/images/wezterm-wallpapers/"
if wezterm.target_triple:match("windows") then
	local available = {}
	for _, domain in ipairs(wezterm.default_wsl_domains()) do
		available[domain.distribution] = domain
	end

	config.wsl_domains = {}
	local nixos = available.NixOS
	if nixos then
		nixos.username = "alex"
		nixos.default_cwd = "/home/alex"
		table.insert(config.wsl_domains, nixos)
		config.default_domain = nixos.name
	end
	config.default_cwd = "/home/alex"
	wallpaper_path = "\\\\wsl.localhost\\NixOS\\home\\alex\\.dotfiles\\images\\wezterm-wallpapers\\"
	-- config.default_prog = { "wsl.exe" }
	config.win32_system_backdrop = "Disable" -- ["Auto", "Acrylic", "Mica", "Tabbed" "Disable"]
elseif wezterm.target_triple:match("darwin") then
	local home = os.getenv("HOME") or "/Users/alexford"
	wallpaper_path = home .. "/.dotfiles/images/wezterm-wallpapers/"

	local managed_profile = nil
	local profile_file = io.open(home .. "/.local/share/dotfiles/profile", "r")
	if profile_file then
		managed_profile = profile_file:read("*l")
		profile_file:close()
	end

	config.launch_menu = config.launch_menu or {}
	table.insert(config.launch_menu, {
		label = "Dotfiles Docker",
		args = { "zsh", "-lc", "dotctl shell macos-docker" },
	})

	if managed_profile == "macos-docker" and os.getenv("DOTFILES_WEZTERM_HOST_SHELL") ~= "1" then
		config.default_prog = { "zsh", "-lc", "dotctl shell macos-docker" }
		config.default_cwd = home
	end
end

local function get_random_wallpaper()
	-- Get random wallpaper image.
	local wallpapers = wezterm.read_dir(wallpaper_path)
	if #wallpapers > 0 then
		math.randomseed(os.time())
		return wallpapers[math.random(#wallpapers)]
	end
	return nil
end

-- if wallpaper then
-- config.background = {
-- 	{
-- 		source = {
-- 			-- File = wallpaper_path .. "svgmeadow.png",
-- 			File = get_random_wallpaper(),
-- 		},
-- 		opacity = 1,
-- 		attachment = "Fixed",
-- 		repeat_x = "NoRepeat",
-- 		repeat_y = "NoRepeat",
-- 		vertical_align = "Bottom",
-- 		horizontal_align = "Center",
-- 		height = "Cover",
-- 		width = "Cover",
-- 	},
-- 	{
-- 		source = {
-- 			-- Color = "#000000",
-- 			Color = color_schemes[config.color_scheme].background,
-- 		},
-- 		opacity = 0.9,
-- 		width = "100%",
-- 		height = "100%",
-- 	},
-- }
-- end

return config
