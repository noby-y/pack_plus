--- pack_plus: a lazy.nvim-flavoured spec layer over Neovim's `vim.pack`.
---
--- No lazy loading. Every plugin is a start plugin, ordered by its
--- dependencies. See README.md for the supported spec fields.

local M = {}

--- @class pack_plus.State
--- @field plugins pack_plus.Plugin[] In load order.
--- @field by_name table<string, pack_plus.Plugin>
--- @field loaded table<string, boolean>
--- @field duplicates pack_plus.Duplicate[]
--- @field pack_dir string

--- @type pack_plus.State
M.state = {
	plugins = {},
	by_name = {},
	loaded = {},
	duplicates = {},
	pack_dir = '',
}

local did_setup = false

--- @param spec any A spec, a list of specs nested to any depth, or a module
--- name to import.
--- @param opts? { confirm?: boolean, profile?: boolean, lazy_stats?: boolean }
function M.setup(spec, opts)
	if did_setup then
		vim.notify('pack_plus: setup() called twice; ignoring', vim.log.levels.WARN)
		return
	end
	did_setup = true

	opts = vim.tbl_extend('force', { confirm = false, profile = true, lazy_stats = false }, opts or {})

	-- Matching lazy's stats shape is not enough for snacks' `startup` section:
	-- it calls `require('lazy.stats')` outright (snacks/dashboard.lua:1095). A
	-- preloaded module satisfies that require. Opt-in, since it shadows the real
	-- `lazy.stats` if lazy.nvim is ever on the runtimepath.
	if opts.lazy_stats then
		package.loaded['lazy.stats'] = { stats = M.stats }
	end

	local profile = require('pack_plus.profile')
	local build = require('pack_plus.build')
	local collect = require('pack_plus.spec')
	local resolve = require('pack_plus.resolve')
	local load = require('pack_plus.load')

	-- Before anything touches `vim.pack`. The first call of the session installs
	-- whatever the lockfile lists but disk is missing, firing `PackChanged` as it
	-- goes, and a handler registered later misses those events.
	build.init()

	local collected = collect.collect(spec)
	collect.warn(collected.duplicates)

	local plugins = resolve.sort(collected)
	build.register(plugins)

	local paths = {} --- @type table<string, string>
	for _, plugin in ipairs(plugins) do
		paths[plugin.name] = load.path(plugin)
	end

	M.state = {
		plugins = plugins,
		by_name = collected.by_name,
		loaded = {},
		duplicates = collected.duplicates,
		pack_dir = load.pack_dir(),
	}

	if opts.profile then
		profile.watch(plugins, paths)
	end

	M.state.loaded = load.add(plugins, { confirm = opts.confirm })
	load.configure(plugins, M.state.loaded)

	vim.api.nvim_create_user_command('PackPlus', function()
		require('pack_plus.ui').open()
	end, { desc = 'pack_plus dashboard' })
end

--- Open the dashboard.
function M.show()
	require('pack_plus.ui').open()
end

--- Timing and counts, shaped like `require('lazy').stats()`.
function M.stats()
	return require('pack_plus.profile').stats()
end

return M
