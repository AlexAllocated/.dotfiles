local M = {}

local function read(path)
	local file = assert(io.open(path, "rb"), "Missing reviewed plugin lock: " .. path)
	local contents = file:read("*a")
	file:close()
	return contents
end

local function git(directory, ...)
	local output = vim.fn.system({ "git", "-C", directory, ... })
	assert(vim.v.shell_error == 0, "Plugin Git operation failed: " .. output)
	return vim.trim(output)
end

function M.bootstrap(directory, commit, repository)
	assert(type(commit) == "string" and #commit == 40 and commit:match("^%x+$"), "Invalid lazy.nvim pin")
	local missing = not vim.uv.fs_stat(directory)
	if missing then
		local output = vim.fn.system({
			"git",
			"clone",
			"--filter=blob:none",
			"--no-checkout",
			repository or "https://github.com/folke/lazy.nvim.git",
			directory,
		})
		assert(vim.v.shell_error == 0, "Failed to clone reviewed lazy.nvim: " .. output)
	end
	if missing or git(directory, "rev-parse", "HEAD") ~= commit then
		assert(
			missing or vim.env.DOTFILES_NVIM_AUTOMATION == "1",
			"Installed lazy.nvim differs from the accepted pin; apply the reviewed editor revision"
		)
		vim.fn.system({ "git", "-C", directory, "cat-file", "-e", commit .. "^{commit}" })
		if vim.v.shell_error ~= 0 then
			git(directory, "fetch", "origin", commit)
		end
		git(directory, "checkout", "--detach", commit)
	end
	assert(git(directory, "rev-parse", "HEAD") == commit, "lazy.nvim bootstrap did not reach its reviewed pin")
end

function M.protect(path)
	local original = read(path)
	local pins = vim.json.decode(original)
	local lock = require("lazy.manage.lock")
	-- Lazy installs imported specs in several rounds. Its normal lock writer
	-- drops pins for specs not loaded yet and records any existing newer HEADs.
	-- Hold the original pins in memory before the first round can run.
	lock.lock = vim.deepcopy(pins)
	lock._loaded = true
	lock.update = function()
		assert(read(path) == original, "Reviewed plugin lock changed during restore")
	end
	lock.get = function(plugin)
		return assert(lock.lock[plugin.name], "No reviewed plugin pin for " .. plugin.name .. "; prepare editor first")
	end
	M.reviewed = { path = path, contents = original, pins = pins }
end

function M.verify()
	local reviewed = assert(M.reviewed, "Reviewed plugin pins were not protected before startup")
	assert(read(reviewed.path) == reviewed.contents, "Reviewed plugin lock changed during restore")
	local config = require("lazy.core.config")
	local manifest = { schema_version = 1, lock_sha256 = vim.fn.sha256(reviewed.contents), plugins = {}, inactive = {} }
	for name, plugin in pairs(config.plugins) do
		if not plugin._.is_local then
			local pin = assert(reviewed.pins[name], "No reviewed plugin pin for " .. name)
			assert(plugin._.installed, "Reviewed plugin is not installed: " .. name)
			assert(git(plugin.dir, "rev-parse", "HEAD") == pin.commit, "Plugin differs from reviewed commit: " .. name)
			manifest.plugins[name] = pin.commit
		end
	end
	for name in pairs(reviewed.pins) do
		if not manifest.plugins[name] then
			table.insert(manifest.inactive, name)
		end
	end
	table.sort(manifest.inactive)
	local data = vim.fn.stdpath("data")
	vim.fn.mkdir(data, "p")
	assert(
		vim.fn.writefile({ vim.json.encode(manifest) }, vim.fs.joinpath(data, "dotfiles-plugin-pins.json")) == 0,
		"Could not record validated plugin commits"
	)
	return true
end

return M
