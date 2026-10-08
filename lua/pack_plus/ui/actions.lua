--- Dashboard keymaps: u, U, C-u, x, i, c.

local resolve = require('pack_plus.resolve')

local M = {}

--- @param msg string
--- @param level integer?
local function notify(msg, level)
	vim.notify('pack_plus: ' .. msg, level or vim.log.levels.INFO)
end

--- @param staged table<string, boolean>
--- @return string[]
local function staged_names(staged)
	local names = vim.tbl_keys(staged)
	table.sort(names)
	return names
end

--- Staged updates apply on confirmation. Declining leaves them staged, so you
--- can add more rows and confirm once.
---
--- Deliberately not `vim.pack.update(names, { force = false })`: that opens
--- vim.pack's own confirmation buffer in a separate tabpage.
--- @param ui table
local function apply(ui)
	local names = staged_names(ui.state.staged)
	if #names == 0 then
		return
	end

	local prompt = ('Update %d plugin%s?\n%s'):format(
		#names,
		#names == 1 and '' or 's',
		table.concat(names, '\n')
	)
	if vim.fn.confirm(prompt, '&Update\n&Not yet', 2) ~= 1 then
		return
	end

	ui.close()
	local ok, err = pcall(vim.pack.update, names, { force = true })
	if not ok then
		notify(tostring(err), vim.log.levels.ERROR)
	end
	ui.open()
end

--- @param ui table
--- @param name string
--- @param force boolean
--- @param quiet boolean
--- @return boolean staged
local function stage_one(ui, name, force, quiet)
	local status = ui.state.status[name]

	if not status then
		if not quiet then
			notify('no update information yet for ' .. name)
		end
		return false
	end

	if status.pinned then
		if not quiet then
			notify(name .. ' is pinned; drop `pin` to update it')
		end
		return false
	end

	if not status.pending then
		if not quiet then
			notify(name .. ' is already at its target revision')
		end
		return false
	end

	-- `vim.pack`'s `checkout` (`vim/pack.lua:713`) runs `git stash push`
	-- unconditionally before every update, with no prompt and no notification.
	-- By the time `update()` is called the work is already in a stash the user
	-- does not know exists, so the block has to happen here.
	if #status.dirty > 0 and not force then
		if not quiet then
			notify(
				('%s has %d uncommitted change%s. C-u stages it anyway and lets vim.pack stash them.'):format(
					name,
					#status.dirty,
					#status.dirty == 1 and '' or 's'
				),
				vim.log.levels.WARN
			)
			ui.state.expanded[name] = true
		end
		return false
	end

	ui.state.staged[name] = true
	return true
end

--- @param ui table
--- @param force boolean
function M.stage(ui, force)
	local item = ui.item()
	if not item or item.kind ~= 'plugin' then
		return
	end

	if stage_one(ui, item.name, force, false) then
		ui.render()
		apply(ui)
	else
		ui.render()
	end
end

--- @param ui table
--- @param force boolean
function M.stage_all(ui, force)
	local count = 0
	for _, plugin in ipairs(ui.state.plugins) do
		if stage_one(ui, plugin.name, force, true) then
			count = count + 1
		end
	end

	if count == 0 then
		notify('nothing to update')
		return
	end

	ui.render()
	apply(ui)
end

--- @param ui table
function M.delete(ui)
	local item = ui.item()
	if not item then
		return
	end

	local plugin = ui.state.by_name[item.name]
	if plugin and plugin.dir then
		notify(item.name .. ' is a local plugin; pack_plus never touches its directory')
		return
	end

	if vim.fn.confirm(('Delete %s from disk?'):format(item.name), '&Delete\n&Cancel', 2) ~= 1 then
		return
	end

	local ok, err = pcall(vim.pack.del, { item.name }, { force = true })
	if not ok then
		notify(tostring(err), vim.log.levels.ERROR)
		return
	end

	if plugin then
		notify(
			('%s is gone from disk. `i` puts it back, but its `plugin/` files cannot be re-sourced and a `setup()` that already ran cannot run again: use `:restart`.'):format(
				item.name
			)
		)
	end
	ui.refresh()
end

--- @param ui table
function M.install(ui)
	local specs = {} --- @type vim.pack.Spec[]
	for _, plugin in ipairs(ui.state.plugins) do
		if not plugin.dir and vim.tbl_contains(ui.state.missing, plugin.name) then
			specs[#specs + 1] = {
				src = plugin.src,
				name = plugin.name,
				version = resolve.version(plugin.version),
			}
		end
	end

	if #specs == 0 then
		notify('nothing is missing from disk')
		return
	end

	local ok, err = pcall(vim.pack.add, specs, { load = false, confirm = false })
	if not ok then
		notify(tostring(err), vim.log.levels.ERROR)
		return
	end

	notify(('installed %d plugin%s; `:restart` to load them'):format(
		#specs,
		#specs == 1 and '' or 's'
	))
	ui.refresh()
end

--- @param ui table
function M.clean(ui)
	local orphans = ui.state.orphans
	if #orphans == 0 then
		notify('nothing on disk that the config does not load')
		return
	end

	local prompt = ('Delete %d plugin%s the config does not load?\n%s'):format(
		#orphans,
		#orphans == 1 and '' or 's',
		table.concat(orphans, '\n')
	)
	if vim.fn.confirm(prompt, '&Delete\n&Cancel', 2) ~= 1 then
		return
	end

	-- `dir` plugins never reach the lockfile, so they are not in this list.
	local ok, err = pcall(vim.pack.del, orphans, { force = false })
	if not ok then
		notify(tostring(err), vim.log.levels.ERROR)
		return
	end
	ui.refresh()
end

return M
