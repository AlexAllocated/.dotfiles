local M = {}

local function run_automation(steps)
	local ok, err = xpcall(function()
		for _, step in ipairs(steps) do
			vim.cmd(step)
		end
	end, debug.traceback)

	if not ok then
		vim.api.nvim_err_writeln(err)
		return false
	end
	return true
end

function M.update_plugin_pins()
	vim.cmd(run_automation({ "Lazy! update" }) and "qa" or "cquit")
end

function M.wait_for_mason(timeout_ms)
	timeout_ms = timeout_ms or 600000

	local ok, registry = pcall(require, "mason-registry")
	if not ok then
		return true
	end

	local complete = vim.wait(timeout_ms, function()
		local packages_ok, packages = pcall(registry.get_all_packages)
		if not packages_ok then
			return false
		end

		for _, package in ipairs(packages) do
			if package:is_installing() or package:is_uninstalling() then
				return false
			end
		end

		return true
	end, 1000)

	if not complete then
		vim.api.nvim_err_writeln("Timed out waiting for Mason package installs")
		return false
	end
	return true
end

function M.sync_runtime()
	local commands_ok = run_automation({ "Lazy! restore", "MasonUpdate", "TSUpdateSync" })
	vim.cmd(commands_ok and M.wait_for_mason() and "qa" or "cquit")
end

return M
