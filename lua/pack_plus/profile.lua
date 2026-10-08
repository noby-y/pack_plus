--- Per-plugin timing.
---
--- A plugin's cost arrives in two pieces. `vim.pack.add` runs during `init.lua`
--- with `load = false`, so `:packadd!` only puts the plugin on the runtimepath;
--- its `plugin/` files are sourced later, in Neovim's own post-`init.lua`
--- runtime pass. Taking over `load` to source them early makes Neovim source
--- them a second time in that pass, which is why `vim.pack.add` defaults to
--- `load = vim.v.vim_did_init == 1` (`vim/pack.lua:848`).
---
--- So: time the calls we make ourselves, attribute the runtime pass with
--- `SourcePre` / `SourcePost`, and report the sum.

--- @class pack_plus.Timing
--- @field packadd number Milliseconds spent getting onto the runtimepath.
--- @field setup number
--- @field post number
--- @field keys number
--- @field source number `plugin/` files, from the post-`init.lua` runtime pass.

local M = {}

local uv = vim.uv

--- Start of the measured window. Set when this module is first required, which
--- for a config that calls `pack_plus.setup()` is a few lines into `init.lua`.
--- Neovim's own pre-init cost is not visible from inside the process.
M.start = uv.hrtime()

--- @type table<string, pack_plus.Timing>
M.times = {}

--- @type number? Milliseconds from `M.start` to `UIEnter`.
M.startuptime = nil

--- @param name string
--- @return pack_plus.Timing
local function entry(name)
	local t = M.times[name]
	if not t then
		t = { packadd = 0, setup = 0, post = 0, keys = 0, source = 0 }
		M.times[name] = t
	end
	return t
end

--- @param name string
--- @param phase 'packadd'|'setup'|'post'|'keys'|'source'
--- @param ns integer
function M.record(name, phase, ns)
	local t = entry(name)
	t[phase] = t[phase] + ns / 1e6
end

--- Run `fn`, recording how long it took against `name`.
--- @param name string
--- @param phase 'packadd'|'setup'|'post'|'keys'
--- @param fn function
--- @return boolean ok
--- @return any result_or_error
function M.track(name, phase, fn)
	local t0 = uv.hrtime()
	local ok, res = xpcall(fn, function(err)
		return debug.traceback(tostring(err), 2)
	end)
	M.record(name, phase, uv.hrtime() - t0)
	return ok, res
end

--- @param name string
--- @return number milliseconds
function M.total(name)
	local t = M.times[name]
	if not t then
		return 0
	end
	return t.packadd + t.setup + t.post + t.keys + t.source
end

--- Watch the post-`init.lua` runtime pass. `SourcePre` / `SourcePost` fire for
--- `.lua` as well as `.vim`, with full paths, and nest. Only the outermost
--- frame is counted: a file sourced from inside another is part of that file's
--- cost, and adding both would double it.
--- @param plugins pack_plus.Plugin[]
--- @param paths table<string, string> name -> path on disk
function M.watch(plugins, paths)
	local prefixes = {} --- @type { path: string, name: string }[]
	for _, plugin in ipairs(plugins) do
		local path = paths[plugin.name]
		if path then
			prefixes[#prefixes + 1] = { path = path .. '/', name = plugin.name }
		end
	end

	local group = vim.api.nvim_create_augroup('PackPlusProfile', { clear = true })
	local stack = {} --- @type { name: string?, t0: integer }[]

	vim.api.nvim_create_autocmd('SourcePre', {
		group = group,
		callback = function(ev)
			local name
			for _, p in ipairs(prefixes) do
				if ev.file:sub(1, #p.path) == p.path then
					name = p.name
					break
				end
			end
			stack[#stack + 1] = { name = name, t0 = uv.hrtime() }
		end,
	})

	vim.api.nvim_create_autocmd('SourcePost', {
		group = group,
		callback = function()
			local frame = table.remove(stack)
			if frame and frame.name and #stack == 0 then
				M.record(frame.name, 'source', uv.hrtime() - frame.t0)
			end
		end,
	})

	vim.api.nvim_create_autocmd('UIEnter', {
		group = group,
		once = true,
		callback = function()
			M.startuptime = (uv.hrtime() - M.start) / 1e6
			vim.api.nvim_clear_autocmds({ group = group })
		end,
	})
end

--- Shaped like `require('lazy').stats()` so a snacks dashboard footer can read
--- either one.
--- @return { count: integer, loaded: integer, startuptime: number, times: table<string, number> }
function M.stats()
	local state = require('pack_plus').state
	local loaded = 0
	for _, plugin in ipairs(state.plugins) do
		if state.loaded[plugin.name] then
			loaded = loaded + 1
		end
	end

	local times = {} --- @type table<string, number>
	for name in pairs(M.times) do
		times[name] = M.total(name)
	end

	return {
		count = #state.plugins,
		loaded = loaded,
		startuptime = M.startuptime or (uv.hrtime() - M.start) / 1e6,
		times = times,
	}
end

return M
