-- Run with: nvim -l tests/spec_spec.lua

vim.opt.runtimepath:prepend(vim.fn.fnamemodify('.', ':p'))

local spec = require('pack_plus.spec')
local resolve = require('pack_plus.resolve')

local failures = 0
local checks = 0

local function check(label, got, want)
	checks = checks + 1
	local ok = vim.deep_equal(got, want)
	if not ok then
		failures = failures + 1
		print(('FAIL %s\n  got  %s\n  want %s'):format(label, vim.inspect(got), vim.inspect(want)))
	end
end

-- Source expansion -----------------------------------------------------------

check('shorthand', spec.expand_src('folke/snacks.nvim'), 'https://github.com/folke/snacks.nvim')
check(
	'full url kept',
	spec.expand_src('https://forge.barrettruth.com/barrettruth/canola.nvim'),
	'https://forge.barrettruth.com/barrettruth/canola.nvim'
)
check('scp form kept', spec.expand_src('git@github.com:folke/snacks.nvim'), 'git@github.com:folke/snacks.nvim')
check(
	'bare host gets https',
	spec.expand_src('forge.barrettruth.com/barrettruth/canola.nvim'),
	'https://forge.barrettruth.com/barrettruth/canola.nvim'
)

check('name from url', spec.derive_name('https://forge.example.com/o/canola.nvim'), 'canola.nvim')
check('name drops .git', spec.derive_name('https://github.com/o/repo.git'), 'repo')

-- Version translation --------------------------------------------------------

check('range', tostring(resolve.version('1.*')), '1.0.0 - 2.0.0')
check('star', tostring(resolve.version('*')), '>=0.0.0')
check('branch stays a string', resolve.version('main'), 'main')
-- vim.version.range reads this sha as `5.0.0 - 6.0.0`, which is why the plain
-- string path exists.
check('sha stays a string', resolve.version('a5aa62e37b'), 'a5aa62e37b')
check('plain tag stays a string', resolve.version('v1.2.3'), 'v1.2.3')
check('caret range', tostring(resolve.version('^1.2')), '1.2.0 - 2.0.0')
check('nil', resolve.version(nil), nil)

-- Collection -----------------------------------------------------------------

local collected = spec.collect({
	{ 'a/one', opts = { x = 1 } },
	{
		{ 'a/two', dependencies = { 'a/one' } },
		{ 'a/three', priority = 1000 },
	},
})

check('three plugins', #collected.order, 3)
check('edge recorded', collected.by_name['two'].deps, { 'one' })
check('opts kept', collected.by_name['one'].opts, { x = 1 })
check('default priority', collected.by_name['one'].priority, 50)

local sorted = resolve.sort(collected)
local names = vim.tbl_map(function(p)
	return p.name
end, sorted)
check('priority first, dependency before dependent', names, { 'three', 'one', 'two' })

-- A bare-string dependency is a reference: it must not win on `src`.
local refs = spec.collect({
	{ dir = '/tmp/x', name = 'oil-filechooser', dependencies = { 'barrettruth/canola.nvim' } },
	{ 'https://forge.example.com/barrettruth/canola.nvim', opts = {} },
})
check(
	'explicit src wins over a reference',
	refs.by_name['canola.nvim'].src,
	'https://forge.example.com/barrettruth/canola.nvim'
)
check('reference leaves no duplicate warning', #refs.duplicates, 0)
check('reference still makes an edge', refs.by_name['oil-filechooser'].deps, { 'canola.nvim' })

-- Two real specs for one name: first wins, and the collision is recorded.
local dups = spec.collect({
	{ 'a/thing', opts = { a = 1, shared = 'first' }, version = '1.*' },
	{ 'b/thing', opts = { b = 2, shared = 'second' }, version = '2.*' },
})
check('merged opts, first wins per key', dups.by_name['thing'].opts, { a = 1, b = 2, shared = 'first' })
check('first src wins', dups.by_name['thing'].src, 'https://github.com/a/thing')
check('version conflict recorded', dups.duplicates[1].fields, { 'src', 'version' })

-- Table opts against function opts: the loud one.
local modes = spec.collect({
	{ 'a/thing', opts = { a = 1 } },
	{ 'a/thing', opts = function() end },
})
check('function dropped', modes.by_name['thing'].opts_fn, nil)
check(
	'collision named',
	modes.duplicates[1].opts_mode,
	'dropped a function `opts`; the table `opts` was seen first'
)

local modes2 = spec.collect({
	{ 'a/thing', opts = function() end },
	{ 'a/thing', opts = { a = 1 } },
})
check('function kept', type(modes2.by_name['thing'].opts_fn), 'function')
check('table merged for its argument', modes2.by_name['thing'].opts, { a = 1 })

-- Keys concatenate; an entry with no rhs survives collection and is dropped at
-- map time.
local keyed = spec.collect({
	{ 'a/thing', keys = { { '<leader>a', ':A<cr>' } } },
	{ 'a/thing', keys = { { '<leader>b', ':B<cr>' } } },
})
check('keys concatenated', #keyed.by_name['thing'].keys, 2)

-- A cycle must not hang or drop a plugin.
local cyclic = spec.collect({
	{ 'a/one', dependencies = { 'a/two' } },
	{ 'a/two', dependencies = { 'a/one' } },
})
check('cycle keeps both', #resolve.sort(cyclic), 2)

-- Nested dependency tables are lifted to top level.
local nested = spec.collect({
	{
		'a/parent',
		dependencies = {
			{ 'a/child', opts = { c = 1 } },
		},
	},
})
check('child lifted', nested.by_name['child'].opts, { c = 1 })
check('child before parent', resolve.sort(nested)[1].name, 'child')

-- Import ---------------------------------------------------------------------

-- Narrowed to the fixture, or a real `~/.config/nvim/lua/plugins` on the
-- runtimepath joins the import.
local saved_rtp = vim.o.runtimepath
vim.opt.runtimepath = {
	vim.fn.fnamemodify('tests/fixtures/importcfg', ':p'),
	vim.fn.fnamemodify('.', ':p'),
	vim.env.VIMRUNTIME,
}

local function sorted_names(collected)
	local names = vim.tbl_keys(collected.by_name)
	table.sort(names)
	return names
end

-- `init.lua` is the module, sibling files are submodules, and a subdirectory
-- comes in through its own `init.lua` and nothing else.
check('import of a directory', sorted_names(spec.collect({ { import = 'plugins' } })), {
	'from-file',
	'from-init',
	'from-subdir',
})

check('top-level string imports', sorted_names(spec.collect('plugins')), {
	'from-file',
	'from-init',
	'from-subdir',
})

-- A slashed string is still a spec, not a module name.
check('top-level string with a slash is a spec', sorted_names(spec.collect('a/thing')), { 'thing' })

-- The same import in two files must not produce duplicate specs.
local twice = spec.collect({ { import = 'plugins' }, { import = 'plugins' } })
check('import is idempotent', #twice.order, 3)
check('import leaves no duplicate warning', #twice.duplicates, 0)

-- Imports mix with inline specs, and a per-file bare spec keeps its opts.
local mixed = spec.collect({
	{ 'a/inline', priority = 1000 },
	{ import = 'plugins' },
})
check('inline alongside import', #mixed.order, 4)
check('bare spec in a file keeps opts', mixed.by_name['from-file'].opts, { x = 1 })

local notified = {}
local real_notify = vim.notify
vim.notify = function(msg, level)
	notified[#notified + 1] = { msg = msg, level = level }
end
local missing = spec.collect({ { import = 'nope.not.here' } })
vim.notify = real_notify
check('missing module collects nothing', #missing.order, 0)
check('missing module is an error', notified[1] and notified[1].level, vim.log.levels.ERROR)

vim.o.runtimepath = saved_rtp

print(('%d checks, %d failures'):format(checks, failures))
os.exit(failures == 0 and 0 or 1)
