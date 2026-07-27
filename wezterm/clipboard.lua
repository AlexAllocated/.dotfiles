local wezterm = require("wezterm")

local M = {}

M.paste = wezterm.action_callback(function(window, pane)
	if not wezterm.target_triple:match("linux") then
		window:perform_action(wezterm.action.PasteFrom("Clipboard"), pane)
		return
	end

	local success, contents, stderr = wezterm.run_child_process({ "dotfiles-clipboard-paste" })
	if success then
		pane:send_paste(contents)
		return
	end

	wezterm.log_error("Wayland clipboard paste failed: " .. stderr)
	window:toast_notification("WezTerm", "Could not read the Wayland clipboard", nil, 4000)
end)

return M
