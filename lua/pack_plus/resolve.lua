--- Main-module derivation, version translation, load order.

local M = {}

--- Copied from lazy.nvim (`lazy/core/util.lua:68`).
--- @param name string
--- @return string
local function normname(name)
	local norm = name:lower():gsub('^n?vim%-', ''):gsub('%.n?vim$', ''):gsub('[%.%-]lua', '')
	return (norm:gsub('[^a-z]+', ''))
end

--- Top-level `require`able modules under `<path>/lua`.
--- @param path string
--- @return string[]
local function top_modules(path)
	local lua = vim.fs.joinpath(path, 'lua')
	if not vim.uv.fs_stat(lua) then
		return {}
	end

	local mods = {} --- @type string[]
	for entry, entry_type in vim.fs.dir(lua) do
		if entry_type == 'link' then
			local stat = vim.uv.fs_stat(vim.fs.joinpath(lua, entry))
			entry_type = stat and stat.type or entry_type
		end

		if entry_type == 'file' then
			local mod = entry:match('^(.+)%.lua$')
			if mod and mod ~= 'init' then
				mods[#mods + 1] = mod
			end
		elseif entry_type == 'directory' then
			if vim.uv.fs_stat(vim.fs.joinpath(lua, entry, 'init.lua')) then
				mods[#mods + 1] = entry
			end
		end
	end

	return mods
end

--- The module whose `setup()` gets called. Follows lazy.nvim
--- (`lazy/core/loader.lua:399`): exact normalized-name match first, then the
--- plugin's only module if it has exactly one.
--- @param name string
--- @param path string
--- @return string?
function M.main(name, path)
	if name ~= 'mini.nvim' and name:match('^mini%..*$') then
		return name
	end

	local target = normname(name)
	local mods = top_modules(path)
	for _, mod in ipairs(mods) do
		if normname(mod) == target then
			return mod
		end
	end

	return #mods == 1 and mods[1] or nil
end

--- `vim.version.range` is lenient enough to read a commit sha as a range:
--- `a5aa62e37b` comes back as `5.0.0 - 6.0.0`. So translate only strings that
--- carry a range operator or wildcard, and hand everything else to `vim.pack`
--- as the branch, tag or sha it is.
--- @param version string|vim.VersionRange|nil
--- @return string|vim.VersionRange|nil
function M.version(version)
	if type(version) ~= 'string' then
		return version
	end
	if not version:find('[%*%^~<>=]') and not version:find(' %- ') then
		return version
	end

	local ok, range = pcall(vim.version.range, version)
	if ok and range then
		return range
	end
	return version
end

--- Priority descending, then a stable topological sort over the dependency
--- edges. Priority is only the pre-sort, so it can never move a plugin ahead of
--- something it depends on. Cycles break at the first-seen order.
--- @param collected pack_plus.Collected
--- @return pack_plus.Plugin[]
function M.sort(collected)
	local rank = {} --- @type table<string, integer>
	for i, plugin in ipairs(collected.order) do
		rank[plugin.name] = i
	end

	local pre = vim.list_slice(collected.order, 1, #collected.order)
	table.sort(pre, function(a, b)
		if a.priority ~= b.priority then
			return a.priority > b.priority
		end
		return rank[a.name] < rank[b.name]
	end)

	local by_name = collected.by_name
	local out = {} --- @type pack_plus.Plugin[]
	local state = {} --- @type table<string, 'doing'|'done'>

	local function visit(plugin)
		if state[plugin.name] then
			return
		end
		state[plugin.name] = 'doing'

		local deps = vim.list_slice(plugin.deps, 1, #plugin.deps)
		table.sort(deps, function(a, b)
			local pa, pb = by_name[a], by_name[b]
			if pa and pb and pa.priority ~= pb.priority then
				return pa.priority > pb.priority
			end
			return (rank[a] or math.huge) < (rank[b] or math.huge)
		end)

		for _, dep in ipairs(deps) do
			if by_name[dep] and state[dep] ~= 'doing' then
				visit(by_name[dep])
			end
		end

		state[plugin.name] = 'done'
		out[#out + 1] = plugin
	end

	for _, plugin in ipairs(pre) do
		visit(plugin)
	end

	return out
end

return M
