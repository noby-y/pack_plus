-- Dashboard action test. Expects the scratch data dir from init_smoke.lua to
-- already hold todo-comments.nvim, rewound and dirtied:
--
--   cd $XDG_DATA_HOME/nvim/site/pack/core/opt/todo-comments.nvim
--   git checkout -q HEAD~5 && echo x >> README.md
--
--   XDG_CONFIG_HOME=/tmp/pp/config XDG_DATA_HOME=/tmp/pp/data \
--     nvim --headless -u tests/ui_smoke.lua

vim.opt.runtimepath:prepend(vim.fn.getcwd())

require('pack_plus').setup({
	{ 'nvim-lua/plenary.nvim' },
	{ 'folke/todo-comments.nvim', dependencies = { 'nvim-lua/plenary.nvim' }, opts = {} },
})

local failures = 0

local function check(label, got, want)
	local ok = vim.deep_equal(got, want)
	if not ok then
		failures = failures + 1
	end
	io.write(
		('%s %s%s\n'):format(
			ok and 'ok  ' or 'FAIL',
			label,
			ok and '' or ('\n  got  %s\n  want %s'):format(vim.inspect(got), vim.inspect(want))
		)
	)
end

local function run()
	local ui = require('pack_plus.ui')
	local actions = require('pack_plus.ui.actions')

	local notes = {}
	local real_notify = vim.notify
	vim.notify = function(msg, level)
		notes[#notes + 1] = msg
	end

	-- Never prompt; always answer "do it".
	vim.fn.confirm = function()
		return 1
	end

	ui.open()
	check('scan finishes', vim.wait(60000, function()
		return not ui.state.scanning
	end, 100), true)

	local status = ui.state.status['todo-comments.nvim']
	check('update is pending', status.pending, true)
	check('changelog collected', #status.commits > 0, true)
	check('dirty worktree seen', #status.dirty > 0, true)

	--- @return integer?
	local function row_of(name)
		for lnum, item in pairs(ui.items) do
			if item.name == name then
				return lnum
			end
		end
	end

	local row = row_of('todo-comments.nvim')
	check('plugin has a row', row ~= nil, true)
	vim.api.nvim_win_set_cursor(ui.win, { row, 0 })

	-- `u` must refuse: vim.pack would stash the dirty file without a word.
	actions.stage(ui, false)
	check('u does not stage a dirty plugin', ui.state.staged['todo-comments.nvim'], nil)
	check(
		'u explains the block',
		notes[#notes]:find('uncommitted change', 1, true) ~= nil,
		true
	)
	check('u expands the row', ui.state.expanded['todo-comments.nvim'], true)

	local lines = vim.api.nvim_buf_get_lines(ui.buf, 0, -1, false)
	local shown = table.concat(lines, '\n')
	check('dirty file listed', shown:find('README.md', 1, true) ~= nil, true)
	check('commit subject listed', shown:find(status.commits[1].subject, 1, true) ~= nil, true)
	check('local changes flagged', shown:find('local changes', 1, true) ~= nil, true)

	-- C-u stages anyway and applies.
	local target = status.target
	actions.stage(ui, true)
	check('C-u applied the update', vim.wait(60000, function()
		return not ui.state.scanning
	end, 100), true)

	local after = vim.system(
		{ 'git', 'rev-parse', 'HEAD' },
		{ cwd = vim.fs.joinpath(require('pack_plus').state.pack_dir, 'todo-comments.nvim'), text = true }
	):wait()
	check('plugin is at the target revision', vim.trim(after.stdout), target)

	vim.notify = real_notify
	io.write(failures == 0 and 'all ok\n' or (failures .. ' failures\n'))
end

vim.api.nvim_create_autocmd('VimEnter', {
	once = true,
	callback = function()
		-- Never leave a headless Neovim sitting there on an error.
		local ok, err = xpcall(run, debug.traceback)
		if not ok then
			io.write('ERROR ' .. tostring(err) .. '\n')
		end
		vim.cmd((ok and failures == 0) and 'qa!' or 'cq!')
	end,
})
