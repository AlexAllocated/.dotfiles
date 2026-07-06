local M = {}

function M.wait_for_mason(timeout_ms)
	timeout_ms = timeout_ms or 600000

	local ok, registry = pcall(require, "mason-registry")
	if not ok then
		return
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
		vim.cmd("cq")
	end
end

return M
