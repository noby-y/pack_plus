--- Putting plugins on the runtimepath and running their user code.

local profile = require('pack_plus.profile')
local resolve = require('pack_plus.resolve')

local M = {}

--- @return string
function M.pack_dir()
	return vim.fs.joinpath(vim.fn.stdpath('data'), 'site', 'pack', 'core', 'opt')
end

--- @param plugin pack_plus.Plugin
--- @return string
function M.path(plugin)
	return plugin.dir or vim.fs.joinpath(M.pack_dir(), plugin.name)
end

--- Where `:packadd` would put it: after the user's own directories, before
--- `$VIMRUNTIME`.
--- @param path string
local function rtp_add(path)
	local list = vim.split(vim.o.runtimepath, ',', { plain = true })
	if vim.tbl_contains(list, path) then
		return
	end

	local index = #list + 1
	for i, entry in ipairs(list) do
		if entry == vim.env.VIMRUNTIME then
			index = i
			break
		end
	end
	table.insert(list, index, path)

	local after = vim.fs.joinpath(path, 'after')
	if vim.uv.fs_stat(after) then
		list[#list + 1] = after
	end

	vim.o.runtimepath = table.concat(list, ',')
end

--- @param path string
--- @param sub string
local function source_dir(path, sub)
	for _, file in ipairs(vim.fn.glob(path .. '/' .. sub .. '/**/*.{vim,lua}', false, true)) do
		vim.cmd.source({ file, magic = { file = false } })
	end
end

--- `src` is required by `vim.pack` and must be cloneable, so a `dir` plugin
--- cannot go through it at all. Put it on the runtimepath by hand.
--- @param plugin pack_plus.Plugin
--- @return boolean ok
local function add_local(plugin)
	if not vim.uv.fs_stat(plugin.dir) then
		vim.notify(
			('pack_plus: `%s` has no directory at %s'):format(plugin.name, plugin.dir),
			vim.log.levels.ERROR
		)
		return false
	end

	local t0 = vim.uv.hrtime()
	rtp_add(plugin.dir)

	-- During startup Neovim's own runtime pass sources these, same as for a
	-- `:packadd!`-ed plugin. Afterwards nobody else will.
	if vim.v.vim_did_enter == 1 then
		source_dir(plugin.dir, 'plugin')
		source_dir(plugin.dir, 'after/plugin')
	end
	profile.record(plugin.name, 'packadd', vim.uv.hrtime() - t0)

	return true
end

--- Mirrors `pack_add` (`vim/pack.lua:832`). Sourcing `plugin/` ourselves during
--- startup would only get it sourced twice, so during `init.lua` this is a
--- `:packadd!` and nothing more.
--- @param loaded table<string, boolean>
--- @return fun(data: { spec: vim.pack.Spec, path: string })
local function pack_loader(loaded)
	local did_init = vim.v.vim_did_init == 1

	return function(data)
		local name = data.spec.name
		local t0 = vim.uv.hrtime()

		vim.cmd.packadd({
			vim.fn.escape(name, ' '),
			bang = not did_init,
			magic = { file = false },
		})

		-- `:packadd` sources plain `plugin/` files only.
		if vim.v.vim_did_enter == 1 and did_init then
			source_dir(data.path, 'after/plugin')
		end

		profile.record(name, 'packadd', vim.uv.hrtime() - t0)
		loaded[name] = true
	end
end

--- @param plugins pack_plus.Plugin[]
--- @param opts { confirm: boolean }
--- @return table<string, boolean> loaded
function M.add(plugins, opts)
	local loaded = {} --- @type table<string, boolean>
	local specs = {} --- @type vim.pack.Spec[]

	for _, plugin in ipairs(plugins) do
		if plugin.dir then
			loaded[plugin.name] = add_local(plugin)
		elseif plugin.src then
			specs[#specs + 1] = {
				src = plugin.src,
				name = plugin.name,
				version = resolve.version(plugin.version),
			}
		end
	end

	if #specs > 0 then
		local ok, err = pcall(vim.pack.add, specs, {
			load = pack_loader(loaded),
			confirm = opts.confirm,
		})
		if not ok then
			vim.notify(tostring(err), vim.log.levels.ERROR)
		end
	end

	return loaded
end

--- Fields of a key spec that are not `vim.keymap.set` options.
local KEY_META = { mode = true, ft = true, lhs = true, rhs = true, id = true }

--- @param key table
--- @return table
local function key_opts(key)
	local opts = {}
	for k, v in pairs(key) do
		if type(k) ~= 'number' and not KEY_META[k] then
			opts[k] = v
		end
	end
	return opts
end

--- lazy's key spec, mapped the moment the plugin loads. An entry with no rhs
--- existed only to trigger a lazy load, so there is nothing left to map.
--- @param plugin pack_plus.Plugin
local function map_keys(plugin)
	for _, key in ipairs(plugin.keys or {}) do
		if type(key) == 'table' then
			local lhs, rhs = key[1] or key.lhs, key[2] or key.rhs
			local mode = key.mode or 'n'

			if lhs and rhs then
				if key.ft then
					local opts = key_opts(key)
					vim.api.nvim_create_autocmd('FileType', {
						pattern = key.ft,
						callback = function(ev)
							vim.keymap.set(
								mode,
								lhs,
								rhs,
								vim.tbl_extend('force', opts, { buffer = ev.buf })
							)
						end,
					})
				else
					vim.keymap.set(mode, lhs, rhs, key_opts(key))
				end
			end
		end
	end
end

--- @param plugin pack_plus.Plugin
--- @param path string
local function call_setup(plugin, path)
	-- No `opts` and no `post` means the plugin was never asked to configure
	-- itself, so it does not get a `setup()` call.
	if plugin.opts == nil and plugin.opts_fn == nil and plugin.post == nil then
		return
	end

	local opts = plugin.opts or {}

	-- A function `opts` is fully responsible for the plugin. Return value unused.
	if plugin.opts_fn then
		local ok, err = profile.track(plugin.name, 'setup', function()
			plugin.opts_fn(opts)
		end)
		if not ok then
			vim.notify(
				('pack_plus: `opts` failed for `%s`:\n%s'):format(plugin.name, err),
				vim.log.levels.ERROR
			)
		end
		return
	end

	local main = resolve.main(plugin.name, path)
	if not main then
		vim.notify(
			('pack_plus: no main module found for `%s`; give it a function `opts`'):format(
				plugin.name
			),
			vim.log.levels.WARN
		)
		return
	end

	local ok, err = profile.track(plugin.name, 'setup', function()
		local mod = require(main)
		if type(mod) ~= 'table' or type(mod.setup) ~= 'function' then
			error(("module '%s' has no setup()"):format(main))
		end
		mod.setup(opts)
	end)
	if not ok then
		vim.notify(
			('pack_plus: setup failed for `%s`:\n%s'):format(plugin.name, err),
			vim.log.levels.ERROR
		)
	end
end

--- Per plugin, in load order: setup, then `post`, then keys.
--- @param plugins pack_plus.Plugin[]
--- @param loaded table<string, boolean>
function M.configure(plugins, loaded)
	for _, plugin in ipairs(plugins) do
		if loaded[plugin.name] then
			call_setup(plugin, M.path(plugin))

			if plugin.post then
				local ok, err = profile.track(plugin.name, 'post', plugin.post)
				if not ok then
					vim.notify(
						('pack_plus: `post` failed for `%s`:\n%s'):format(plugin.name, err),
						vim.log.levels.ERROR
					)
				end
			end

			local ok, err = profile.track(plugin.name, 'keys', function()
				map_keys(plugin)
			end)
			if not ok then
				vim.notify(
					('pack_plus: `keys` failed for `%s`:\n%s'):format(plugin.name, err),
					vim.log.levels.ERROR
				)
			end
		end
	end
end

return M
