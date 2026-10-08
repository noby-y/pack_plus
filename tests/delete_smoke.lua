-- `x` then `i` then `c`, against the scratch data dir from init_smoke.lua.
--
--   XDG_CONFIG_HOME=/tmp/pp/config XDG_DATA_HOME=/tmp/pp/data \
--     nvim --headless -u tests/delete_smoke.lua

vim.opt.runtimepath:prepend(vim.fn.getcwd())

require('pack_plus').setup({
	{ 'nvim-lua/plenary.nvim' },
	{ 'fei6409/log-highlight.nvim', opts = {} },
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
	local pack_dir = require('pack_plus').state.pack_dir

	vim.notify = function() end
	vim.fn.confirm = function()
		return 1
	end

	ui.open()
	vim.wait(60000, function()
		return not ui.state.scanning
	end, 100)

	local function row_of(name)
		for lnum, item in pairs(ui.items) do
			if item.name == name then
				return lnum
			end
		end
	end

	local target = vim.fs.joinpath(pack_dir, 'log-highlight.nvim')
	check('plugin is on disk', vim.uv.fs_stat(target) ~= nil, true)

	vim.api.nvim_win_set_cursor(ui.win, { row_of('log-highlight.nvim'), 0 })
	actions.delete(ui)
	check('x removed the directory', vim.uv.fs_stat(target), nil)
	check('dashboard calls it missing', vim.tbl_contains(ui.state.missing, 'log-highlight.nvim'), true)
	check(
		'row says so',
		table.concat(vim.api.nvim_buf_get_lines(ui.buf, 0, -1, false), '\n'):find(
			'missing from disk',
			1,
			true
		) ~= nil,
		true
	)

	actions.install(ui)
	check('i put it back', vim.uv.fs_stat(target) ~= nil, true)
	check('no longer missing', ui.state.missing, {})

	-- An orphan: on disk, no spec claims it.
	check(
		'orphans found',
		#ui.state.orphans > 0 and vim.tbl_contains(ui.state.orphans, 'mini.icons'),
		true
	)
	actions.clean(ui)
	check('c removed the orphans', ui.state.orphans, {})
	check(
		'c left the config alone',
		vim.uv.fs_stat(vim.fs.joinpath(pack_dir, 'plenary.nvim')) ~= nil,
		true
	)

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
