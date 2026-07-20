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
config.exit_behavior_messaging = "Verbose"
config.front_end = "WebGpu" -- ["OpenGL", "Software", "WebGpu"]
config.hide_mouse_cursor_when_typing = true
config.hide_tab_bar_if_only_one_tab = true
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
config.window_close_confirmation = "AlwaysPrompt"
config.window_decorations = "INTEGRATED_BUTTONS|RESIZE"
-- config.window_padding = { left = 10, right = 10, top = 25, bottom = 10 }
config.window_padding = { left = 0, right = 0, top = 10, bottom = 0 }

if wezterm.target_triple:match("windows") then
	local available = {}
	for _, domain in ipairs(wezterm.default_wsl_domains()) do
		available[domain.distribution] = domain
	end

	config.wsl_domains = {}
	local nixos = available.NixOS
	if nixos then
		table.insert(config.wsl_domains, nixos)
		config.default_domain = nixos.name
	end
	-- config.default_prog = { "wsl.exe" }
	config.win32_system_backdrop = "Disable" -- ["Auto", "Acrylic", "Mica", "Tabbed" "Disable"]
elseif wezterm.target_triple:match("linux") then
	-- Plasma owns the sole title bar and resize frame; tmux owns terminal tabs.
	config.enable_tab_bar = false
	config.enable_wayland = true
	-- Niri delivers keyboard events correctly, but WezTerm's WebGPU frontend
	-- stops processing them on this native Wayland/NVIDIA combination. OpenGL
	-- keeps the native Wayland path fully responsive.
	local current_desktop = (os.getenv("XDG_CURRENT_DESKTOP") or ""):lower()
	if current_desktop:find("niri", 1, true) then
		config.front_end = "OpenGL"
	end
	config.window_decorations = "TITLE|RESIZE"
elseif wezterm.target_triple:match("darwin") then
	local home = os.getenv("HOME") or "."
	config.default_prog = { "/bin/zsh", "-l" }
	config.default_cwd = home
end

return config
