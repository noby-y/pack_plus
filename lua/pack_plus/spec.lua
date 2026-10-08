--- Spec collection: normalize a user spec tree into a flat list of plugins
--- plus the dependency edges between them.

--- @class pack_plus.Plugin
--- @field name string Directory name, display name, basis for module derivation.
--- @field src string? Expanded clone source. Absent for `dir` plugins.
--- @field dir string? Local plugin directory, tilde-expanded.
--- @field opts table? Merged table `opts`.
--- @field opts_fn fun(opts: table)? Function `opts`; replaces the setup call.
--- @field post fun()? Runs after the plugin's setup.
--- @field build fun(info: { name: string, path: string })? Runs on install and update.
--- @field keys table[]? lazy's key spec.
--- @field version string|vim.VersionRange|nil
--- @field pin boolean?
--- @field priority integer
--- @field deps string[] Names that must load first.
--- @field implicit boolean? Came from a bare-string `dependencies` entry only.

--- @class pack_plus.Duplicate
--- @field name string
--- @field kept string
--- @field dropped string
--- @field fields string[]
--- @field opts_mode string?

--- @class pack_plus.Collected
--- @field order pack_plus.Plugin[] Declaration order.
--- @field by_name table<string, pack_plus.Plugin>
--- @field edges table<string, string[]> name -> names that must load first.
--- @field duplicates pack_plus.Duplicate[]
--- @field imported table<string, boolean> Modules already pulled in by `import`.

local M = {}

local GITHUB = 'https://github.com/'

--- A source is used as given when it carries a scheme (`https://`, `git://`,
--- `ssh://`) or is scp-like (`git@host:owner/repo`). A bare host gets `https://`
--- prepended, since git would otherwise read it as a local path. Everything
--- else is a GitHub `owner/repo`.
--- @param src string
--- @return string
function M.expand_src(src)
	if src:match('^%a[%w+.%-]*://') or src:match('^[%w._%-]+@[%w._%-]+:') then
		return src
	end
	if src:match('^[%w._%-]+%.[%w._%-]+/') then
		return 'https://' .. src
	end
	return GITHUB .. src
end

--- @param src string
--- @return string
function M.derive_name(src)
	local stripped = src:gsub('%.git$', ''):gsub('/+$', '')
	return stripped:match('[^/]+$') or stripped
end

--- @param dir string
--- @return string
local function expand_dir(dir)
	return (vim.fn.expand(dir):gsub('/+$', ''))
end

--- Whether a table's keys are exactly `1..n`. Copied from lazy.nvim
--- (`lazy/core/util.lua`, `Util.is_list`).
--- @param t table
--- @return boolean
local function is_list(t)
	local i = 0
	for _ in pairs(t) do
		i = i + 1
		if t[i] == nil then
			return false
		end
	end
	return true
end

--- Lazy's rule: a table holding anything but list entries, and at most one of
--- those, is a single spec. So `{ 'owner/repo', opts = {} }` is one spec while
--- `{ 'owner/repo', 'other/repo' }` is two, and the braces around a lone spec
--- stay optional. `src`/`dir` settle it outright, since such a spec need not
--- carry a list entry at all.
--- @param t any
--- @return boolean
local function is_spec(t)
	if type(t) ~= 'table' or t.import ~= nil then
		return false
	end
	if t.src ~= nil or t.dir ~= nil then
		return true
	end
	return #t <= 1 and not is_list(t)
end

--- @param raw table|string
--- @return pack_plus.Plugin
local function normalize(raw)
	if type(raw) == 'string' then
		raw = { raw }
	end

	local src = raw.src or raw[1]
	local dir = raw.dir and expand_dir(raw.dir) or nil
	if type(src) ~= 'string' and dir == nil then
		error('pack_plus: spec needs a source or a `dir`: ' .. vim.inspect(raw))
	end

	-- `name` is the module-derivation basis, so prefer the explicit one, then the
	-- source, and fall back to the directory only when there is no source.
	local name = raw.name or (src and M.derive_name(src)) or vim.fs.basename(dir)

	local opts, opts_fn
	if type(raw.opts) == 'function' then
		opts_fn = raw.opts
	else
		opts = raw.opts
	end

	return {
		name = name,
		src = src and M.expand_src(src) or nil,
		dir = dir,
		opts = opts,
		opts_fn = opts_fn,
		post = raw.post,
		build = raw.build,
		keys = raw.keys and vim.deepcopy(raw.keys) or nil,
		version = raw.version,
		pin = raw.pin,
		priority = raw.priority,
		deps = {},
	}
end

--- @param deps any
--- @return (string|table)[]
local function dep_list(deps)
	if deps == nil then
		return {}
	end
	if type(deps) == 'string' or is_spec(deps) then
		return { deps }
	end
	return deps
end

--- First-wins fields. `opts`, `keys` and `deps` merge instead.
local FIELDS = { 'src', 'dir', 'post', 'build', 'version', 'pin', 'priority' }

--- @param acc pack_plus.Collected
--- @param plugin pack_plus.Plugin
--- @param implicit boolean Came from a bare-string `dependencies` entry.
local function absorb(acc, plugin, implicit)
	local existing = acc.by_name[plugin.name]
	if not existing then
		plugin.implicit = implicit
		acc.by_name[plugin.name] = plugin
		acc.order[#acc.order + 1] = plugin
		return plugin
	end

	-- A bare-string dependency is a reference, not a definition. It contributes
	-- an edge and nothing else.
	if implicit then
		return existing
	end

	-- An implicit stub is overwritten without comment: the explicit spec is what
	-- the user meant all along.
	if existing.implicit then
		existing.implicit = false
		for _, field in ipairs(FIELDS) do
			if plugin[field] ~= nil then
				existing[field] = plugin[field]
			end
		end
		existing.opts = plugin.opts
		existing.opts_fn = plugin.opts_fn
		existing.keys = plugin.keys
		return existing
	end

	local dup = {
		name = plugin.name,
		kept = existing.src or existing.dir,
		dropped = plugin.src or plugin.dir,
		fields = {},
	}

	for _, field in ipairs(FIELDS) do
		if existing[field] == nil then
			existing[field] = plugin[field]
		elseif plugin[field] ~= nil and existing[field] ~= plugin[field] then
			dup.fields[#dup.fields + 1] = field
		end
	end

	-- Tables merge, first spec wins on a shared key.
	if plugin.opts then
		existing.opts = existing.opts and vim.tbl_deep_extend('keep', existing.opts, plugin.opts)
			or plugin.opts
	end

	-- One spec says "call setup with this table", the other says "I handle
	-- loading myself". First-wins picks one and the other vanishes, so this
	-- collision gets named explicitly rather than listed as a field.
	if plugin.opts_fn then
		if existing.opts_fn then
			dup.fields[#dup.fields + 1] = 'opts'
		elseif existing.opts then
			dup.opts_mode = 'dropped a function `opts`; the table `opts` was seen first'
		else
			existing.opts_fn = plugin.opts_fn
		end
	elseif plugin.opts and existing.opts_fn then
		dup.opts_mode = 'kept a function `opts`; a table `opts` was merged into its argument'
	end

	if plugin.keys then
		existing.keys = vim.list_extend(existing.keys or {}, plugin.keys)
	end

	if #dup.fields > 0 or dup.opts_mode then
		acc.duplicates[#acc.duplicates + 1] = dup
	end

	return existing
end

--- @param acc pack_plus.Collected
--- @param from string Loads first.
--- @param to string Loads second.
local function edge(acc, from, to)
	if from == to then
		return
	end
	local list = acc.edges[to] or {}
	if not vim.tbl_contains(list, from) then
		list[#list + 1] = from
		acc.edges[to] = list
	end
end

--- @param acc pack_plus.Collected
--- @param raw table|string
--- @param implicit boolean
local function add(acc, raw, implicit)
	local plugin = absorb(acc, normalize(raw), implicit)
	if implicit then
		return plugin
	end

	for _, dep in ipairs(dep_list(type(raw) == 'table' and raw.dependencies or nil)) do
		local child = add(acc, dep, type(dep) == 'string')
		edge(acc, child.name, plugin.name)
	end

	return plugin
end

--- Lua modules an `import` expands to, mirroring lazy's `Util.lsmod`: a
--- directory's `init.lua` is the module itself, its other `.lua` files are
--- submodules, and a subdirectory contributes only through its own `init.lua`.
--- Sorted, because runtimepath glob order is not stable.
--- @param mod string
--- @return string[]
local function module_names(mod)
	local rel = 'lua/' .. mod:gsub('%.', '/')
	local names, seen = {}, {}

	for _, root in ipairs(vim.api.nvim_get_runtime_file(rel, true)) do
		for entry, kind in vim.fs.dir(root) do
			local name
			if entry == 'init.lua' then
				name = mod
			elseif kind ~= 'directory' and entry:sub(-4) == '.lua' then
				name = mod .. '.' .. entry:sub(1, -5)
			elseif kind == 'directory' and vim.uv.fs_stat(root .. '/' .. entry .. '/init.lua') then
				name = mod .. '.' .. entry
			end
			if name and not seen[name] then
				seen[name] = true
				names[#names + 1] = name
			end
		end
	end

	-- A plain `lua/plugins.lua` with no directory beside it.
	if #names == 0 and #vim.api.nvim_get_runtime_file(rel .. '.lua', true) > 0 then
		names[1] = mod
	end

	table.sort(names)
	return names
end

local walk

--- @param mod any
--- @param acc pack_plus.Collected
local function import(mod, acc)
	if type(mod) ~= 'string' then
		vim.notify(
			('pack_plus: `import` wants a module name, got %s'):format(vim.inspect(mod)),
			vim.log.levels.ERROR
		)
		return
	end

	local names = module_names(mod)
	if #names == 0 then
		-- Staying quiet here drops every plugin in the module the user meant.
		vim.notify(
			('pack_plus: `import = %q` matched no module on the runtimepath'):format(mod),
			vim.log.levels.ERROR
		)
		return
	end

	for _, name in ipairs(names) do
		if not acc.imported[name] then
			-- Marked before the require, so a module that imports its own parent
			-- stops here instead of recursing.
			acc.imported[name] = true
			local ok, result = pcall(require, name)
			if not ok then
				vim.notify(('pack_plus: `%s` failed to load\n%s'):format(name, result), vim.log.levels.ERROR)
			elseif type(result) == 'table' then
				walk(result, acc)
			else
				vim.notify(('pack_plus: `%s` returned no specs'):format(name), vim.log.levels.WARN)
			end
		end
	end
end

--- @param node any
--- @param acc pack_plus.Collected
function walk(node, acc)
	if type(node) == 'string' or is_spec(node) then
		add(acc, node, false)
	elseif type(node) == 'table' and node.import ~= nil then
		import(node.import, acc)
	elseif type(node) == 'table' then
		for _, child in ipairs(node) do
			walk(child, acc)
		end
	end
end

--- @param input any A spec, a list of them nested to any depth, or a module
--- name to import.
--- @return pack_plus.Collected
function M.collect(input)
	--- @type pack_plus.Collected
	local acc = { order = {}, by_name = {}, edges = {}, duplicates = {}, imported = {} }

	-- A top-level string with no `/` is an import, as in lazy's
	-- `setup('plugins')`. Every source form carries a `/`, so the two cannot be
	-- confused. Only at the top level: inside `dependencies` a slashless string
	-- is a reference to another spec by name.
	if type(input) == 'string' and not input:find('/', 1, true) then
		import(input, acc)
	else
		walk(input, acc)
	end

	for _, plugin in ipairs(acc.order) do
		plugin.priority = plugin.priority or 50
		plugin.deps = acc.edges[plugin.name] or {}
	end

	return acc
end

--- @param duplicates pack_plus.Duplicate[]
function M.warn(duplicates)
	for _, dup in ipairs(duplicates) do
		local lines = {
			('pack_plus: `%s` is specified more than once'):format(dup.name),
			('  kept    %s'):format(dup.kept),
			('  ignored %s'):format(dup.dropped),
		}
		if #dup.fields > 0 then
			lines[#lines + 1] = ('  conflicting fields: %s'):format(table.concat(dup.fields, ', '))
		end
		if dup.opts_mode then
			lines[#lines + 1] = '  ' .. dup.opts_mode
		end
		vim.notify(
			table.concat(lines, '\n'),
			dup.opts_mode and vim.log.levels.ERROR or vim.log.levels.WARN
		)
	end
end

return M
