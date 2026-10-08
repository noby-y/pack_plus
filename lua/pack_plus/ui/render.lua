--- Dashboard lines, highlights, and the line -> item map the keymaps read.

local profile = require('pack_plus.profile')

local M = {}

local HL = {
	title = 'Title',
	dim = 'Comment',
	ok = 'DiagnosticOk',
	warn = 'DiagnosticWarn',
	err = 'DiagnosticError',
	info = 'DiagnosticInfo',
	sha = 'Special',
}

local NAME_WIDTH = 26

--- @class pack_plus.ui.Item
--- @field kind 'plugin'|'orphan'
--- @field name string

local Builder = {}
Builder.__index = Builder

local function builder()
	return setmetatable({ lines = {}, hl = {}, items = {} }, Builder)
end

--- @param segments ({ [1]: string, [2]: string? })[]
--- @param item pack_plus.ui.Item?
function Builder:line(segments, item)
	local text = ''
	local row = #self.lines

	for _, segment in ipairs(segments) do
		local chunk = segment[1]
		if segment[2] then
			self.hl[#self.hl + 1] = {
				row = row,
				col = #text,
				end_col = #text + #chunk,
				group = segment[2],
			}
		end
		text = text .. chunk
	end

	self.lines[row + 1] = text
	if item then
		self.items[row + 1] = item
	end
end

function Builder:blank()
	self:line({ { '' } })
end

--- @param name string
--- @return string
local function name_cell(name)
	if #name >= NAME_WIDTH then
		return name .. ' '
	end
	return name .. string.rep(' ', NAME_WIDTH - #name)
end

--- @param ms number
--- @return string
local function ms(value)
	return ('%.2fms'):format(value)
end

--- @param sha string?
--- @return string
local function short(sha)
	return sha and sha:sub(1, 7) or '???????'
end

--- @param state pack_plus.ui.State
--- @param b table
--- @param name string
local function expansion(state, b, name)
	if not state.expanded[name] then
		return
	end

	local status = state.status[name]
	if not status then
		return
	end

	if #status.dirty > 0 then
		for _, line in ipairs(status.dirty) do
			b:line({ { '      ' }, { line, HL.warn } })
		end
	end

	for _, commit in ipairs(status.commits) do
		b:line({
			{ '      ' },
			{ commit.sha, HL.sha },
			{ ' ' },
			{ commit.subject, commit.breaking and HL.err or nil },
		})
	end
end

--- @param state pack_plus.ui.State
--- @param b table
--- @param plugin pack_plus.Plugin
local function update_row(state, b, plugin)
	local status = state.status[plugin.name]
	local staged = state.staged[plugin.name]
	local blocked = #status.dirty > 0 and not staged

	local marker = staged and ' > ' or '   '
	local count = #status.commits
	local detail = ('%s -> %s  %d commit%s'):format(
		short(status.head),
		short(status.target),
		count,
		count == 1 and '' or 's'
	)
	if status.revert then
		detail = detail .. ', reverting'
	end

	b:line({
		{ marker, HL.ok },
		{ name_cell(plugin.name), blocked and HL.warn or HL.info },
		{ detail, HL.dim },
		{ blocked and '  local changes' or '', HL.err },
	}, { kind = 'plugin', name = plugin.name })

	expansion(state, b, plugin.name)
end

--- @param state pack_plus.ui.State
--- @return { lines: string[], hl: table[], items: table<integer, pack_plus.ui.Item> }
function M.build(state)
	local b = builder()
	local stats = profile.stats()

	b:line({ { ' pack_plus', HL.title } })
	b:blank()

	local startup = stats.startuptime and ms(stats.startuptime) or 'not measured'
	b:line({
		{ ' ' },
		{ ('%d plugins, %d loaded'):format(stats.count, stats.loaded), HL.info },
		{ ('   startup %s'):format(startup), HL.dim },
	})
	b:line({
		{
			' u update   U update all   C-u force   x delete   i install   c clean   <cr> expand   q close',
			HL.dim,
		},
	})

	if state.scanning then
		b:blank()
		b:line({ { ' checking for updates...', HL.dim } })
	end

	local pending, blocked, loaded, not_loaded = {}, {}, {}, {}
	for _, plugin in ipairs(state.plugins) do
		local status = state.status[plugin.name]
		if status and status.pending and #status.dirty > 0 then
			blocked[#blocked + 1] = plugin
		elseif status and status.pending then
			pending[#pending + 1] = plugin
		end

		if state.loaded[plugin.name] then
			loaded[#loaded + 1] = plugin
		else
			not_loaded[#not_loaded + 1] = plugin
		end
	end

	if #pending > 0 then
		b:blank()
		b:line({ { (' Updates (%d)'):format(#pending), HL.title } })
		for _, plugin in ipairs(pending) do
			update_row(state, b, plugin)
		end
	end

	if #blocked > 0 then
		b:blank()
		b:line({ { (' Blocked by local changes (%d)'):format(#blocked), HL.title } })
		for _, plugin in ipairs(blocked) do
			update_row(state, b, plugin)
		end
	end

	table.sort(loaded, function(a, b2)
		return profile.total(a.name) > profile.total(b2.name)
	end)

	b:blank()
	b:line({ { (' Loaded (%d)'):format(#loaded), HL.title } })
	for _, plugin in ipairs(loaded) do
		local status = state.status[plugin.name]
		local note = ''
		local note_hl = HL.dim
		if vim.tbl_contains(state.missing, plugin.name) then
			-- Deleted with `x` this session: still loaded, no longer on disk.
			note = '  missing from disk, `i` reinstalls'
			note_hl = HL.err
		elseif plugin.dir then
			note = '  local'
		elseif status and status.err then
			note = '  ' .. status.err:gsub('%s+', ' ')
			note_hl = HL.err
		elseif status and #status.dirty > 0 and not status.pending then
			-- No update to block, but the dirty worktree is still news: the next
			-- update will have vim.pack stash it.
			note = ('  %d local change%s'):format(#status.dirty, #status.dirty == 1 and '' or 's')
			note_hl = HL.warn
		elseif plugin.pin then
			note = '  pinned'
		end

		b:line({
			{ '   ' },
			{ name_cell(plugin.name) },
			{ ('%8s'):format(ms(profile.total(plugin.name))), HL.dim },
			{ note, note_hl },
		}, { kind = 'plugin', name = plugin.name })
		expansion(state, b, plugin.name)
	end

	if #not_loaded > 0 then
		b:blank()
		b:line({ { (' Not loaded (%d)'):format(#not_loaded), HL.title } })
		for _, plugin in ipairs(not_loaded) do
			b:line({
				{ '   ' },
				{ name_cell(plugin.name), HL.dim },
				{ vim.tbl_contains(state.missing, plugin.name) and 'missing from disk' or '', HL.warn },
			}, { kind = 'plugin', name = plugin.name })
		end
	end

	if #state.orphans > 0 then
		b:blank()
		b:line({ { (' On disk, not in the config (%d)'):format(#state.orphans), HL.title } })
		for _, name in ipairs(state.orphans) do
			b:line({ { '   ' }, { name_cell(name), HL.dim } }, { kind = 'orphan', name = name })
		end
	end

	if #state.duplicates > 0 then
		b:blank()
		b:line({ { (' Duplicate specs (%d)'):format(#state.duplicates), HL.title } })
		for _, dup in ipairs(state.duplicates) do
			b:line({ { '   ' }, { name_cell(dup.name), HL.warn }, { 'kept ' .. dup.kept, HL.dim } })
			b:line({ { '   ' }, { name_cell(''), HL.dim }, { 'ignored ' .. dup.dropped, HL.dim } })
			if #dup.fields > 0 then
				b:line({
					{ '   ' },
					{ name_cell('') },
					{ 'conflicting: ' .. table.concat(dup.fields, ', '), HL.err },
				})
			end
			if dup.opts_mode then
				b:line({ { '   ' }, { name_cell('') }, { dup.opts_mode, HL.err } })
			end
		end
	end

	b:blank()
	return { lines = b.lines, hl = b.hl, items = b.items }
end

return M
