local wezterm = require("wezterm")
local config = require("config")
local act = wezterm.action

config.mouse_bindings = {
	-- Keep one wheel step predictable instead of scaling it by the raw
	-- high-resolution wheel delta reported by the mouse.
	{
		event = { Down = { streak = 1, button = { WheelUp = 1 } } },
		mods = "NONE",
		action = act.ScrollByLine(-5),
		alt_screen = false,
	},
	{
		event = { Down = { streak = 1, button = { WheelDown = 1 } } },
		mods = "NONE",
		action = act.ScrollByLine(5),
		alt_screen = false,
	},
	-- Copy and paste with right click depending on selection.
	{
		event = { Down = { streak = 1, button = "Right" } },
		mods = "NONE",
		action = wezterm.action_callback(function(window, pane)
			local has_selection = window:get_selection_text_for_pane(pane) ~= ""
			if has_selection then
				window:perform_action(wezterm.action.CopyTo("ClipboardAndPrimarySelection"), pane)
				window:perform_action(wezterm.action.ClearSelection, pane)
			else
				window:perform_action(wezterm.action({ PasteFrom = "Clipboard" }), pane)
			end
		end),
	},
}
