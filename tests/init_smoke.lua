-- End-to-end: install a handful of small plugins into a scratch XDG_DATA_HOME
-- and check what pack_plus did with them. See tests/run.sh.

vim.opt.runtimepath:prepend(vim.fn.getcwd())

local built = {}

require('pack_plus').setup({
	{ 'nvim-lua/plenary.nvim' },
	{
		'echasnovski/mini.icons',
		opts = {},
		post = function()
			require('mini.icons').mock_nvim_web_devicons()
		end,
	},
	{
		'rafamadriz/friendly-snippets',
		priority = 10,
	},
	{
		'folke/todo-comments.nvim',
		dependencies = { 'nvim-lua/plenary.nvim' },
		priority = 100,
		opts = { signs = false },
		keys = {
			{ '<leader>zz', '<cmd>TodoTrouble<cr>', desc = 'smoke test key' },
			{ '<leader>zq', desc = 'no rhs, must be dropped' },
		},
		build = function(info)
			built[#built + 1] = info.name
		end,
	},
	{
		'fei6409/log-highlight.nvim',
		version = '*',
		opts = {},
	},
	{
		dir = vim.fn.getcwd() .. '/tests/fixtures/localplug',
		name = 'localplug',
		opts = { greeting = 'hello' },
	},
}, { lazy_stats = true })

local pack_plus = require('pack_plus')
local profile = require('pack_plus.profile')

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

local function report()
	io.write('--- load order ---\n')
	local order = {}
	for i, plugin in ipairs(pack_plus.state.plugins) do
		order[#order + 1] = plugin.name
		io.write(
			('%d %-28s priority=%-5d loaded=%-6s deps=%s\n'):format(
				i,
				plugin.name,
				plugin.priority,
				tostring(pack_plus.state.loaded[plugin.name] or false),
				table.concat(plugin.deps, ',')
			)
		)
	end

	io.write('--- timings ---\n')
	for _, plugin in ipairs(pack_plus.state.plugins) do
		local t = profile.times[plugin.name] or {}
		io.write(
			('%-28s total=%6.2fms packadd=%5.2f setup=%5.2f post=%5.2f keys=%5.2f source=%5.2f\n'):format(
				plugin.name,
				profile.total(plugin.name),
				t.packadd or 0,
				t.setup or 0,
				t.post or 0,
				t.keys or 0,
				t.source or 0
			)
		)
	end

	io.write('--- checks ---\n')
	check('dependency loads before dependent, priority orders the rest', order, {
		'plenary.nvim',
		'todo-comments.nvim',
		'mini.icons',
		'log-highlight.nvim',
		'localplug',
		'friendly-snippets',
	})
	check('everything loaded', #vim.tbl_keys(pack_plus.state.loaded), 6)
	check('setup ran', package.loaded['mini.icons'] ~= nil, true)
	check('post ran', package.preload['nvim-web-devicons'] ~= nil, true)
	check('opts reached setup', require('todo-comments.config')._options.signs, false)
	check('local plugin setup ran', vim.g.localplug_greeting, 'hello')
	check('local plugin on the runtimepath', vim.o.runtimepath:find('fixtures/localplug', 1, true) ~= nil, true)
	check('local plugin/ sourced', vim.g.localplug_sourced, true)
	check('local after/plugin sourced', vim.g.localplug_after_sourced, true)
	check('key mapped', vim.fn.maparg('<leader>zz', 'n') ~= '', true)
	check('key with no rhs dropped', vim.fn.maparg('<leader>zq', 'n'), '')
	check('timings add up', profile.total('mini.icons') > 0, true)
	check('source pass attributed', profile.times['plenary.nvim'].source > 0, true)

	-- What snacks' `startup` section requires, with `lazy_stats = true`.
	local lazy_stats = require('lazy.stats').stats()
	check('lazy.stats shim counts plugins', { lazy_stats.loaded, lazy_stats.count }, { 6, 6 })
	check('lazy.stats shim has a startup time', lazy_stats.startuptime > 0, true)

	-- Only true on a first run into an empty scratch directory.
	if #built > 0 then
		check('build ran on install', built, { 'todo-comments.nvim' })
	else
		io.write('--   build not checked: plugins were already installed\n')
	end

	io.write('--- dashboard ---\n')
	local ui = require('pack_plus.ui')
	ui.open()
	vim.wait(60000, function()
		return not ui.state.scanning
	end, 100)
	local lines = vim.api.nvim_buf_get_lines(ui.buf, 0, -1, false)
	for i, line in ipairs(lines) do
		io.write(('%3d|%s\n'):format(i, line))
	end
	check('dashboard lists every plugin', #vim.tbl_keys(ui.items) >= 6, true)

	io.write(failures == 0 and 'all ok\n' or (failures .. ' failures\n'))
end

vim.api.nvim_create_autocmd('VimEnter', {
	once = true,
	callback = function()
		-- Never leave a headless Neovim sitting there on an error.
		local ok, err = xpcall(report, debug.traceback)
		if not ok then
			io.write('ERROR ' .. tostring(err) .. '\n')
		end
		vim.cmd((ok and failures == 0) and 'qa!' or 'cq!')
	end,
})
