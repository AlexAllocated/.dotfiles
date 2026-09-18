local tasks, packages, errors, commands, registry_ok, registry_hangs
local registry = {}

vim = {
	api = {
		nvim_err_writeln = function(message)
			table.insert(errors, message)
		end,
		nvim_echo = function() end,
	},
	wait = function(_, predicate)
		for _ = 1, 20 do
			if predicate() then
				return true
			end
			local task = table.remove(tasks, 1)
			if task then
				task()
			end
		end
		return false
	end,
	cmd = function(command)
		table.insert(commands, command)
	end,
}

registry.update = function(callback)
	if not registry_hangs then
		table.insert(tasks, function()
			callback(registry_ok)
		end)
	end
end
registry.get_all_packages = function()
	return packages
end
registry.get_installed_packages = function()
	assert(#tasks == 0, "read package versions before registry refresh completed")
	return packages
end
package.loaded["mason-registry"] = registry
local bootstrap = dofile("nvim/lua/config/bootstrap.lua")

local function reset()
	tasks, packages, errors, commands = {}, {}, {}, {}
	registry_ok, registry_hangs = true, false
end

local function add_package(outcome)
	local pkg = { name = "test-tool", version = "1", latest = "2", installing = false, installs = 0 }
	function pkg:get_installed_version()
		return self.version
	end
	function pkg:get_latest_version()
		return self.latest
	end
	function pkg:is_installed()
		return self.version ~= nil
	end
	function pkg:is_installing()
		return self.installing
	end
	function pkg:is_uninstalling()
		return false
	end
	function pkg:is_installable()
		return outcome ~= "unsupported"
	end
	function pkg:install(opts, callback)
		self.installs = self.installs + 1
		self.installing = true
		if outcome == "timeout" then
			return
		end
		table.insert(tasks, function()
			self.installing = false
			if outcome == "success" then
				self.version = opts.version
			end
			callback(outcome ~= "failure", "test install result")
		end)
	end
	table.insert(packages, pkg)
	return pkg
end

reset()
local successful = add_package("success")
assert(bootstrap.update_mason_packages(1))
assert(successful.version == "2" and successful.installs == 1)
assert(bootstrap.update_mason_packages(1))
assert(successful.installs == 1)
assert(#errors == 0)

for _, outcome in ipairs({ "failure", "wrong-version", "timeout", "unsupported" }) do
	reset()
	add_package(outcome)
	assert(not bootstrap.update_mason_packages(1), outcome .. " was accepted")
	assert(#errors > 0)
end

for _, failure in ipairs({ "registry-failure", "registry-timeout" }) do
	reset()
	local pkg = add_package("success")
	registry_ok = false
	registry_hangs = failure == "registry-timeout"
	assert(not bootstrap.update_mason_packages(1))
	assert(pkg.installs == 0)
end

reset()
local busy = add_package("success")
busy.installing = true
assert(not bootstrap.update_mason_packages(1))
assert(busy.installs == 0)

for _, outcome in ipairs({ "success", "failure" }) do
	reset()
	add_package(outcome)
	bootstrap.repair_treesitter_query_links = function()
		return true
	end
	bootstrap.sync_runtime()
	assert(commands[#commands] == (outcome == "success" and "qa" or "cquit"))
end

print("Neovim bootstrap tests passed")
