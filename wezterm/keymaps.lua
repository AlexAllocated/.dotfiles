local wezterm = require("wezterm")
local config = require("config")
local clipboard = require("clipboard")

config.keys = {
	-- Keep plain Ctrl+V available to terminal applications such as Codex,
	-- which uses it for image paste. Ctrl+Shift+V owns text paste.
	{ key = "v", mods = "CTRL|SHIFT", action = clipboard.paste },

	-- Show Debug Overlay
	{ key = "D", mods = "CTRL|SHIFT|ALT", action = wezterm.action.ShowDebugOverlay },

	-- Move Tabs
	{ key = "{", mods = "CTRL|SHIFT", action = wezterm.action.MoveTabRelative(-1) },
	{ key = "}", mods = "CTRL|SHIFT", action = wezterm.action.MoveTabRelative(1) },

	-- Split panes
	{ key = "|", mods = "CTRL|SHIFT", action = wezterm.action.SplitHorizontal({ domain = "CurrentPaneDomain" }) },
	{ key = "_", mods = "CTRL|SHIFT", action = wezterm.action.SplitVertical({ domain = "CurrentPaneDomain" }) },

	-- Navigate panes
	{
		key = "H",
		mods = "CTRL|SHIFT",
		action = wezterm.action_callback(function(window, pane)
			local tab = window:mux_window():active_tab()
			if tab:get_pane_direction("Left") ~= nil then
				window:perform_action(wezterm.action.ActivatePaneDirection("Left"), pane)
			else
				window:perform_action(wezterm.action.ActivateTabRelative(-1), pane)
			end
		end),
	},
	{ key = "J", mods = "CTRL|SHIFT", action = wezterm.action.ActivatePaneDirection("Down") },
	{ key = "K", mods = "CTRL|SHIFT", action = wezterm.action.ActivatePaneDirection("Up") },
	{
		key = "L",
		mods = "CTRL|SHIFT",
		action = wezterm.action_callback(function(window, pane)
			local tab = window:mux_window():active_tab()
			if tab:get_pane_direction("Right") ~= nil then
				window:perform_action(wezterm.action.ActivatePaneDirection("Right"), pane)
			else
				window:perform_action(wezterm.action.ActivateTabRelative(1), pane)
			end
		end),
	},

	-- Resize panes
	{ key = "LeftArrow", mods = "CTRL|SHIFT", action = wezterm.action.AdjustPaneSize({ "Left", 1 }) },
	{ key = "DownArrow", mods = "CTRL|SHIFT", action = wezterm.action.AdjustPaneSize({ "Down", 1 }) },
	{ key = "UpArrow", mods = "CTRL|SHIFT", action = wezterm.action.AdjustPaneSize({ "Up", 1 }) },
	{ key = "RightArrow", mods = "CTRL|SHIFT", action = wezterm.action.AdjustPaneSize({ "Right", 1 }) },

	-- Rotate panes
	{ key = ">", mods = "CTRL|SHIFT", action = wezterm.action.RotatePanes("CounterClockwise") },
	{ key = "<", mods = "CTRL|SHIFT", action = wezterm.action.RotatePanes("Clockwise") },
}
