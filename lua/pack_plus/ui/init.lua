--- The dashboard: window, render loop, keymaps.
---
--- Opening is instant because the first paint needs only
--- `vim.pack.get(nil, { info = false })`, a lockfile read plus one directory
--- scan. Update information arrives later, from `git.lua`.

local git = require('pack_plus.git')
local load = require('pack_plus.load')
local render = require('pack_plus.ui.render')
local resolve = require('pack_plus.resolve')

local M = {}

local ns = vim.api.nvim_create_namespace('pack_plus')

--- @class pack_plus.ui.State
--- @field plugins pack_plus.Plugin[]
--- @field by_name table<string, pack_plus.Plugin>
--- @field loaded table<string, boolean>
--- @field duplicates pack_plus.Duplicate[]
--- @field status table<string, pack_plus.GitStatus>
--- @field staged table<string, boolean>
--- @field expanded table<string, boolean>
--- @field missing string[] In the config, absent from disk.
--- @field orphans string[] On disk, absent from the config.
--- @field scanning boolean

--- @type pack_plus.ui.State?
M.state = nil

--- @type table<integer, pack_plus.ui.Item>
M.items = {}

M.buf = nil --- @type integer?
M.win = nil --- @type integer?

--- @param plugins pack_plus.Plugin[]
--- @return string[] missing
--- @return string[] orphans
local function disk_scan(plugins)
	local on_disk = {} --- @type table<string, string>
	local ok, data = pcall(vim.pack.get, nil, { info = false })
	if ok then
		for _, entry in ipairs(data) do
			on_disk[entry.spec.name] = entry.path
		end
	end

	local in_config = {} --- @type table<string, boolean>
	local missing = {} --- @type string[]
	for _, plugin in ipairs(plugins) do
		in_config[plugin.name] = true
		if not plugin.dir then
			local path = on_disk[plugin.name]
			if not (path and vim.uv.fs_stat(path)) then
				missing[#missing + 1] = plugin.name
			end
		end
	end

	local orphans = {} --- @type string[]
	for name in pairs(on_disk) do
		if not in_config[name] then
			orphans[#orphans + 1] = name
		end
	end
	table.sort(orphans)

	return missing, orphans
end

--- @return pack_plus.ui.State
local function fresh_state()
	local pack_plus = require('pack_plus')
	local plugins = pack_plus.state.plugins
	local missing, orphans = disk_scan(plugins)

	return {
		plugins = plugins,
		by_name = pack_plus.state.by_name,
		loaded = pack_plus.state.loaded,
		duplicates = pack_plus.state.duplicates,
		status = M.state and M.state.status or {},
		staged = {},
		expanded = M.state and M.state.expanded or {},
		missing = missing,
		orphans = orphans,
		scanning = false,
	}
end

function M.render()
	if not (M.buf and vim.api.nvim_buf_is_valid(M.buf)) then
		return
	end

	local out = render.build(M.state)
	local cursor = M.win
		and vim.api.nvim_win_is_valid(M.win)
		and vim.api.nvim_win_get_cursor(M.win)
		or { 1, 0 }

	vim.bo[M.buf].modifiable = true
	vim.api.nvim_buf_set_lines(M.buf, 0, -1, false, out.lines)
	vim.bo[M.buf].modifiable = false

	vim.api.nvim_buf_clear_namespace(M.buf, ns, 0, -1)
	for _, hl in ipairs(out.hl) do
		vim.api.nvim_buf_set_extmark(M.buf, ns, hl.row, hl.col, {
			end_col = hl.end_col,
			hl_group = hl.group,
		})
	end

	M.items = out.items
	if M.win and vim.api.nvim_win_is_valid(M.win) then
		vim.api.nvim_win_set_cursor(M.win, { math.min(cursor[1], #out.lines), cursor[2] })
	end
end

--- @return pack_plus.ui.Item?
function M.item()
	if not (M.win and vim.api.nvim_win_is_valid(M.win)) then
		return nil
	end
	return M.items[vim.api.nvim_win_get_cursor(M.win)[1]]
end

--- Fetch and compare in the background. `vim.pack.get({ info = true,
--- offline = false })` would do the fetching, but it blocks the UI until every
--- repo answers.
function M.scan()
	local plugs = {} --- @type pack_plus.GitPlug[]
	for _, plugin in ipairs(M.state.plugins) do
		if not plugin.dir and not vim.tbl_contains(M.state.missing, plugin.name) then
			plugs[#plugs + 1] = {
				name = plugin.name,
				path = load.path(plugin),
				version = resolve.version(plugin.version),
				pin = plugin.pin,
			}
		end
	end

	M.state.scanning = true
	M.render()

	git.inspect(plugs, { offline = false }, function(results)
		if not M.state then
			return
		end
		M.state.status = results
		M.state.scanning = false
		M.render()
	end)
end

--- Reread disk, then fetch again.
function M.refresh()
	local expanded = M.state and M.state.expanded or {}
	M.state = fresh_state()
	M.state.expanded = expanded
	M.render()
	M.scan()
end

function M.close()
	if M.win and vim.api.nvim_win_is_valid(M.win) then
		vim.api.nvim_win_close(M.win, true)
	end
	M.win, M.buf = nil, nil
end

local function set_keymaps()
	local actions = require('pack_plus.ui.actions')
	local map = function(lhs, fn, desc)
		vim.keymap.set('n', lhs, fn, { buffer = M.buf, nowait = true, desc = desc })
	end

	map('q', M.close, 'close')
	map('<esc>', M.close, 'close')

	map('<cr>', function()
		local item = M.item()
		if item then
			M.state.expanded[item.name] = not M.state.expanded[item.name] or nil
			M.render()
		end
	end, 'toggle details')

	map('u', function()
		actions.stage(M, false)
	end, 'stage the update under the cursor')
	map('U', function()
		actions.stage_all(M, false)
	end, 'stage all updates')
	map('<C-u>', function()
		actions.stage(M, true)
	end, 'stage anyway, overriding the local-changes block')
	map('x', function()
		actions.delete(M)
	end, 'delete under the cursor')
	map('i', function()
		actions.install(M)
	end, 'install specs missing from disk')
	map('c', function()
		actions.clean(M)
	end, 'delete plugins the config does not load')
end

function M.open()
	if M.win and vim.api.nvim_win_is_valid(M.win) then
		vim.api.nvim_set_current_win(M.win)
		return
	end

	local expanded = M.state and M.state.expanded or {}
	M.state = fresh_state()
	M.state.expanded = expanded

	M.buf = vim.api.nvim_create_buf(false, true)
	M.win = vim.api.nvim_open_win(M.buf, true, {
		relative = 'editor',
		row = 0,
		col = 0,
		width = vim.o.columns,
		height = math.max(vim.o.lines - vim.o.cmdheight - 1, 1),
		style = 'minimal',
		zindex = 60,
	})

	vim.bo[M.buf].filetype = 'pack_plus'
	vim.bo[M.buf].bufhidden = 'wipe'
	vim.wo[M.win].wrap = false
	vim.wo[M.win].cursorline = true

	vim.api.nvim_create_autocmd('BufWipeout', {
		buffer = M.buf,
		once = true,
		callback = function()
			M.win, M.buf = nil, nil
		end,
	})

	set_keymaps()
	M.render()
	M.scan()
end

return M
