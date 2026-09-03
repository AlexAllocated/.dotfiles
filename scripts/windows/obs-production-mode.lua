obs = obslua

local launcher_path = ""
local production_active = false

local function log(level, message)
	obs.script_log(level, "OBS production frame policy: " .. message)
end

local function quote_windows_argument(value)
	return '"' .. string.gsub(value, '"', '""') .. '"'
end

local function apply_mode(mode)
	if launcher_path == nil or launcher_path == "" then
		log(obs.LOG_ERROR, "the hidden frame-limiter launcher path is empty")
		return false
	end

	local command = "wscript.exe //B //NoLogo " .. quote_windows_argument(launcher_path) .. " " .. mode
	local result, reason, code = os.execute(command)
	local succeeded = result == true or result == 0
	if succeeded then
		log(obs.LOG_INFO, "applied " .. mode .. " mode")
	else
		log(obs.LOG_ERROR, "failed to apply " .. mode .. " mode (" .. tostring(reason) .. ", " .. tostring(code) .. ")")
	end
	return succeeded
end

local function set_production_active(active)
	if production_active == active then
		return
	end
	production_active = active
	if active then
		apply_mode("Production")
	else
		apply_mode("RestoreProduction")
	end
end

local function frontend_event(event)
	if event == obs.OBS_FRONTEND_EVENT_EXIT or event == obs.OBS_FRONTEND_EVENT_SCRIPTING_SHUTDOWN then
		set_production_active(false)
	end
end

function script_description()
	return [[
Keeps GPU headroom available for OBS without a wrapper or polling service.
Opening OBS lowers the NVIDIA frame cap before games launch; closing OBS
restores the preceding local or Moonlight/VDD cap.
]]
end

function script_defaults(settings)
	local local_app_data = os.getenv("LOCALAPPDATA") or ""
	obs.obs_data_set_default_string(
		settings,
		"launcher_path",
		local_app_data .. "\\dotfiles\\obs-production-frame-limit.vbs"
	)
end

function script_properties()
	local properties = obs.obs_properties_create()
	obs.obs_properties_add_path(
		properties,
		"launcher_path",
		"Hidden frame-limiter launcher",
		obs.OBS_PATH_FILE,
		"VBScript (*.vbs)",
		nil
	)
	return properties
end

function script_update(settings)
	launcher_path = obs.obs_data_get_string(settings, "launcher_path")
end

function script_load(settings)
	script_update(settings)
	obs.obs_frontend_add_event_callback(frontend_event)
	set_production_active(true)
end

function script_unload()
	obs.obs_frontend_remove_event_callback(frontend_event)
	set_production_active(false)
end
