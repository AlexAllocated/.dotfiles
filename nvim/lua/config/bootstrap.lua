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

function M.update_mason_packages(timeout_ms, targets, registry_pin)
	timeout_ms = timeout_ms or 600000
	local ok, err = xpcall(function()
		local registry = require("mason-registry")
		local refreshed, refresh_ok = false, false
		registry.update(function(success)
			refresh_ok = success
			refreshed = true
		end)
		assert(
			vim.wait(timeout_ms, function()
				return refreshed
			end, 100),
			"Timed out updating the Mason registry"
		)
		assert(refresh_ok, "Mason registry update failed")
		if registry_pin then
			local actual = M.mason_registry_pin()
			assert(
				actual.version == registry_pin.version and actual.sha256 == registry_pin.sha256,
				"Mason registry differs from reviewed lock"
			)
		end
		assert(M.wait_for_mason(timeout_ms), "Pending Mason installations did not finish")

		local updates = 0
		local failures = {}
		local expected = {}
		local queue = {}
		local selected = {}
		if targets then
			for name in pairs(targets) do
				table.insert(selected, registry.get_package(name))
			end
		else
			selected = registry.get_installed_packages()
		end
		for _, package in ipairs(selected) do
			local installed = package:get_installed_version()
			-- Reviewed restores never discover a newer package version.
			local latest = targets and assert(targets[package.name]) or package:get_latest_version()
			expected[package] = latest
			if installed ~= latest then
				assert(package:is_installable({ version = latest }), "Cannot update Mason package " .. package.name)
				updates = updates + 1
				vim.api.nvim_echo({
					{
						("Updating Mason package %s: %s -> %s"):format(package.name, installed or "unknown", latest),
					},
				}, true, {})
				table.insert(queue, package)
			end
		end
		-- Retry only failed downloads, retaining the exact target versions. Mason
		-- closes the install handle and cleans up staging before its callback.
		for attempt = 1, 3 do
			local pending = #queue
			local retry = {}
			for _, package in ipairs(queue) do
				package:install({ version = expected[package] }, function(success, result)
					if not success then
						local message = tostring(result)
						local transient = false
						for _, code in ipairs({ "ETIMEDOUT", "ECONNRESET", "EAI_AGAIN", "ECONNREFUSED" }) do
							transient = transient or message:find(code, 1, true) ~= nil
						end
						if transient and attempt < 3 then
							table.insert(retry, package)
							vim.api.nvim_echo({
								{
									("Retrying Mason package %s after a network failure (attempt %d/3)"):format(
										package.name,
										attempt + 1
									),
								},
							}, true, {})
						else
							table.insert(failures, package.name .. ": " .. message)
						end
					end
					pending = pending - 1
				end)
			end
			assert(
				vim.wait(timeout_ms, function()
					return pending == 0
				end, 100),
				"Timed out updating Mason packages"
			)
			if #retry == 0 then
				break
			end
			queue = retry
		end
		assert(#failures == 0, "Mason updates failed: " .. table.concat(failures, "; "))
		for package, version in pairs(expected) do
			assert(
				package:is_installed() and package:get_installed_version() == version,
				("Mason package %s did not reach %s"):format(package.name, version)
			)
		end
		if updates == 0 then
			vim.api.nvim_echo({ { "Mason packages are up to date." } }, true, {})
		end
	end, debug.traceback)

	if not ok then
		vim.api.nvim_err_writeln(err)
		return false
	end
	return true
end

function M.repair_treesitter_query_links()
	local lazy_ok, lazy_config = pcall(require, "lazy.core.config")
	local plugin = lazy_ok and lazy_config.plugins["nvim-treesitter"] or nil
	if not plugin then
		vim.api.nvim_err_writeln("Could not locate nvim-treesitter while repairing query links")
		return false
	end

	local source_root = vim.fs.joinpath(plugin.dir, "runtime", "queries")
	local install_root = vim.fs.joinpath(vim.fn.stdpath("data"), "site", "queries")
	if not vim.uv.fs_stat(install_root) then
		return true
	end

	local repaired = {}
	for language, entry_type in vim.fs.dir(install_root) do
		local installed = vim.fs.joinpath(install_root, language)
		local source = vim.fs.joinpath(source_root, language)
		if entry_type == "link" and not vim.uv.fs_stat(installed) and vim.uv.fs_stat(source) then
			local removed, remove_error = vim.uv.fs_unlink(installed)
			if not removed then
				vim.api.nvim_err_writeln(
					("Could not remove stale Tree-sitter query link %s: %s"):format(
						installed,
						remove_error or "unknown error"
					)
				)
				return false
			end

			local linked, link_error = vim.uv.fs_symlink(source, installed, { dir = true })
			if not linked then
				vim.api.nvim_err_writeln(
					("Could not repair Tree-sitter query link %s: %s"):format(installed, link_error or "unknown error")
				)
				return false
			end
			table.insert(repaired, language)
		end
	end

	if #repaired > 0 then
		table.sort(repaired)
		vim.api.nvim_echo({ { ("Repaired Tree-sitter query links: %s"):format(table.concat(repaired, ", ")) } }, true, {})
	end
	return true
end

function M.mason_lock_path()
	local name = require("config.profile").managed_macos and "mason-lock.macos-managed.json" or "mason-lock.json"
	return (vim.env.DOTFILES_NVIM_AUTOMATION == "1" and vim.env.DOTFILES_NVIM_MASON_LOCKFILE)
		or vim.fs.joinpath(vim.env.DOTFILES_NVIM_CONFIG_ROOT or vim.fn.stdpath("config"), name)
end

function M.read_mason_lock()
	local path = M.mason_lock_path()
	assert(vim.fn.filereadable(path) == 1, "Missing Mason version lock: " .. path .. "; run dotctl prepare editor")
	local lock = vim.json.decode(table.concat(vim.fn.readfile(path), "\n"))
	assert(lock.schema_version == 1 and type(lock.packages) == "table", "Invalid Mason version lock")
	for name, version in pairs(lock.packages) do
		assert(type(name) == "string" and type(version) == "string" and version ~= "", "Invalid Mason package pin")
	end
	assert(
		type(lock.registry) == "table"
			and type(lock.registry.version) == "string"
			and type(lock.registry.sha256) == "string",
		"Missing Mason registry pin"
	)
	return lock.packages, lock.registry
end

function M.mason_registry_pin()
	for source in require("mason-registry").sources:iterate() do
		local registry = source:serialize()
		if registry.proto == "github" and registry.namespace == "mason-org" and registry.name == "mason-registry" then
			return { version = registry.version, sha256 = registry.checksums["registry.json"] }
		end
	end
	error("Could not locate the reviewed Mason registry")
end

function M.restore_mason_pins(timeout_ms)
	local ok, pins, registry_pin = pcall(M.read_mason_lock)
	if not ok then
		vim.api.nvim_err_writeln(pins)
		return false
	end
	return M.update_mason_packages(timeout_ms, pins, registry_pin)
end

function M.prepare_runtime()
	local ok, err = xpcall(function()
		assert(run_automation({ "Lazy! update" }), "Plugin update failed")
		local registry = require("mason-registry")
		local complete, success = false, false
		registry.update(function(result)
			success, complete = result, true
		end)
		assert(vim.wait(600000, function()
			return complete
		end, 100) and success, "Mason registry update failed")
		-- Keep every deliberately installed tool and include tools introduced by
		-- enabled LazyVim extras. No live runtime is consulted or modified here.
		local names = M.read_mason_lock()
		for _, name in ipairs(LazyVim.opts("mason.nvim").ensure_installed or {}) do
			names[name] = true
		end
		local mapping = require("mason-lspconfig.mappings").get_mason_map().lspconfig_to_package
		for server, opts in pairs(LazyVim.opts("nvim-lspconfig").servers or {}) do
			if
				mapping[server]
				and opts ~= false
				and (type(opts) ~= "table" or (opts.enabled ~= false and opts.mason ~= false))
			then
				names[mapping[server]] = true
			end
		end
		local targets = {}
		for name in pairs(names) do
			targets[name] = registry.get_package(name):get_latest_version()
		end
		assert(M.update_mason_packages(nil, targets), "Mason candidate installs failed")
		assert(M.repair_treesitter_query_links(), "Tree-sitter query repair failed")
		assert(run_automation({ "TSUpdateSync" }) and M.wait_for_mason(), "Editor runtime validation failed")
		-- Emit sorted, stable JSON so the review contains only version changes.
		local registry_pin = M.mason_registry_pin()
		local lines = {
			"{",
			'  "schema_version": 1,',
			'  "registry": {',
			'    "version": ' .. vim.json.encode(registry_pin.version) .. ",",
			'    "sha256": ' .. vim.json.encode(registry_pin.sha256),
			"  },",
			'  "packages": {',
		}
		local sorted = vim.tbl_keys(targets)
		table.sort(sorted)
		for index, name in ipairs(sorted) do
			lines[#lines + 1] = ("    %s: %s%s"):format(
				vim.json.encode(name),
				vim.json.encode(targets[name]),
				index < #sorted and "," or ""
			)
		end
		lines[#lines + 1] = "  }"
		lines[#lines + 1] = "}"
		local target = M.mason_lock_path()
		assert(vim.fn.writefile(lines, target .. ".next") == 0, "Could not save Mason candidate pins")
		assert(vim.uv.fs_rename(target .. ".next", target), "Could not replace Mason candidate pins")
	end, debug.traceback)
	if not ok then
		vim.api.nvim_err_writeln(err)
	end
	vim.cmd(ok and "qa" or "cquit")
end

function M.verify_plugin_pins()
	local ok, err = pcall(require("config.plugin_pins").verify)
	if not ok then
		vim.api.nvim_err_writeln(err)
	end
	return ok
end

function M.sync_runtime()
	local plugins_ok = run_automation({ "Lazy! restore" }) and M.verify_plugin_pins()
	local mason_ok = plugins_ok and M.restore_mason_pins()
	local query_links_ok = mason_ok and M.repair_treesitter_query_links()
	local treesitter_ok = query_links_ok and run_automation({ "TSUpdateSync" })
	vim.cmd(treesitter_ok and M.wait_for_mason() and "qa" or "cquit")
end

return M
