local mullvad = "@mullvad@"
local mullvadGui = "@mullvadGui@"
local sleep = "@sleep@"

local tunnelState = "unknown"
local commandInFlight = false

local function normalizedState(output)
	local lower = string.lower(output or "")
	local state = string.match(lower, '"state"%s*:%s*"([%a_]+)"') or string.match(lower, '"type"%s*:%s*"([%a_]+)"')

	if state ~= nil then
		return state
	end
	if string.find(lower, "disconnecting", 1, true) then
		return "disconnecting"
	elseif string.find(lower, "disconnected", 1, true) then
		return "disconnected"
	elseif string.find(lower, "connecting", 1, true) then
		return "connecting"
	elseif string.find(lower, "connected", 1, true) then
		return "connected"
	elseif string.find(lower, "error", 1, true) or string.find(lower, "blocked", 1, true) then
		return "error"
	end

	return "unknown"
end

local function render()
	if commandInFlight or tunnelState == "connecting" or tunnelState == "disconnecting" then
		barWidget.setGlyph("shield-checkered")
		barWidget.setGlyphColor("secondary", "script")
		barWidget.setTooltip("Mullvad is changing tunnel state\nRight-click: open Mullvad")
	elseif tunnelState == "connected" then
		barWidget.setGlyph("shield-check")
		barWidget.setGlyphColor("primary", "script")
		barWidget.setTooltip("Mullvad VPN: connected (system-wide)\nLeft-click: disconnect\nRight-click: open Mullvad")
	elseif tunnelState == "disconnected" then
		barWidget.setGlyph("shield-off")
		barWidget.setGlyphColor("on_surface_variant", "script")
		barWidget.setTooltip("Mullvad VPN: disconnected\nLeft-click: connect\nRight-click: open Mullvad")
	elseif tunnelState == "error" then
		barWidget.setGlyph("shield-exclamation")
		barWidget.setGlyphColor("error", "script")
		barWidget.setTooltip(
			"Mullvad is blocking traffic or needs attention\nLeft-click: disconnect and restore normal routing\nRight-click: open Mullvad"
		)
	else
		barWidget.setGlyph("shield-question")
		barWidget.setGlyphColor("error", "script")
		barWidget.setTooltip("Mullvad status unavailable\nRight-click: open Mullvad")
	end
end

local function refreshStatus()
	if commandInFlight then
		return
	end

	commandInFlight = true
	local launched = noctalia.runAsync(mullvad .. " status --json", function(result)
		commandInFlight = false
		if result.exitCode == 0 then
			tunnelState = normalizedState(result.stdout)
		else
			tunnelState = "unknown"
		end
		render()
	end, 1500)

	if not launched then
		commandInFlight = false
		tunnelState = "unknown"
		render()
	end
end

function onClick()
	if commandInFlight or tunnelState == "connecting" or tunnelState == "disconnecting" then
		return
	end

	local shouldDisconnect = tunnelState == "connected" or tunnelState == "error"
	if tunnelState == "unknown" then
		noctalia.notifyError("Mullvad VPN", "The daemon is unavailable. Opening Mullvad so you can inspect it.")
		noctalia.runAsync(mullvadGui)
		return
	end

	commandInFlight = true
	render()
	local action = shouldDisconnect and "disconnect --wait" or "connect --wait"
	local launched = noctalia.runAsync(mullvad .. " " .. action, function(result)
		commandInFlight = false
		if result.exitCode ~= 0 then
			local detail = noctalia.string.trim(result.stderr)
			if detail == "" then
				detail = noctalia.string.trim(result.stdout)
			end
			if detail == "" then
				detail = "Mullvad could not change the tunnel state."
			end
			noctalia.notifyError("Mullvad VPN", detail)
			if not shouldDisconnect then
				noctalia.runAsync(mullvadGui)
			end
		end
		refreshStatus()
	end, 20000)

	if not launched then
		commandInFlight = false
		noctalia.notifyError("Mullvad VPN", "Could not run the Mullvad command.")
		refreshStatus()
	end
end

function onRightClick()
	noctalia.runAsync(mullvadGui)
end

local streamCommand = "while true; do " .. mullvad .. " status --json listen 2>/dev/null; " .. sleep .. " 2; done"
local streamStarted = noctalia.runStream(streamCommand, function(line)
	tunnelState = normalizedState(line)
	render()
end)

if not streamStarted then
	refreshStatus()
end
render()
