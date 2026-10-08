# pack_plus

A lazy.nvim-flavoured spec layer over Neovim's native `vim.pack`. No lazy
loading. Every plugin is a start plugin, ordered by its dependencies.

Needs Neovim 0.13.0-dev. `vim.pack` is marked experimental, so expect this to
break when it churns.

The point is to keep lazy's spec shape, which is genuinely nice to write,
without the loader. Nothing here defers anything. If your config does not
actually need lazy loading, and most do not, the whole event/ft/cmd machinery is
bookkeeping you maintain for no gain.

## Usage

```lua
require('pack_plus').setup({
	{ 'folke/snacks.nvim', priority = 1000, opts = { picker = {}, input = {} } },
	{
		'saghen/blink.cmp',
		version = '1.*',
		dependencies = { 'rafamadriz/friendly-snippets' },
		opts = { keymap = { preset = 'enter' } },
	},
	{ dir = '~/projects/my-plugin', name = 'my-plugin', opts = {} },
})
```

`setup` takes a spec, a list of specs, or lists of lists, at any depth. A
module name imports every spec under it, so a file-per-plugin `lua/plugins/`
works the way it does in lazy:

```lua
require('pack_plus').setup('plugins')
-- or, mixed with inline specs
require('pack_plus').setup({
	{ 'folke/snacks.nvim', priority = 1000, opts = {} },
	{ import = 'plugins' },
})
```

Bootstrap pack_plus itself the way you would any other plugin:

```lua
vim.pack.add({ 'https://github.com/noby-y/pack_plus' })
require('pack_plus').setup({ ... })
```

`:PackPlus` opens the dashboard.

`setup` takes a second table: `confirm` prompts before installing, `profile`
turns per-plugin timing on and defaults to `true`, and `lazy_stats` is below.

## Stats

`require('pack_plus').stats()` returns `count`, `loaded`, `startuptime`, and a
`times` map, shaped like `require('lazy').stats()`.

Matching the shape is not enough for a snacks dashboard, because its `startup`
section calls `require('lazy.stats')` outright
(`snacks/dashboard.lua:1095`) and errors without lazy installed. `lazy_stats`
preloads that module as a view onto `stats()`:

```lua
require('pack_plus').setup('plugins', { lazy_stats = true })
```

`{ section = 'startup' }` then works untouched, and reports the real numbers:
snacks defers the dashboard's own setup to `UIEnter` (`snacks/init.lua:161`),
while pack_plus registers the `UIEnter` handler that finalizes `startuptime`
before any plugin's `setup()` runs. The handler fires first, so the dashboard
reads a finished total.

Off by default: it shadows the real `lazy.stats` if lazy.nvim is ever on the
runtimepath, which should be something you asked for rather than something that
happened to you.

## Spec fields

| Field | Behaviour | Difference from lazy |
| --- | --- | --- |
| `[1]` / `src` | Plugin source. A bare `owner/repo` becomes `https://github.com/owner/repo`. A scheme or scp-like source is passed to git as written. A bare host gets `https://` prepended, since git would otherwise read it as a local path. | `url` is not a separate field |
| `dir` | Local plugin. Tilde-expanded. Never touches `vim.pack` or the lockfile. | same |
| `name` | Directory name, display name, and the basis for module derivation. | same |
| `dependencies` | Load-order edges. A bare string references another spec; a table is a spec. | nothing is lazy-loaded, so these only order things |
| `opts` | A table merges across duplicate specs and is passed to `require(main).setup(opts)`. A function is called as `opts(merged_opts)` and replaces the setup call entirely, taking full responsibility for the plugin. Return value ignored. | absorbs lazy's `config`, which does not exist here |
| `post` | Runs after the plugin's setup. | replaces lazy's `init`, which ran *before* load |
| `build` | Lua function, run on install and update. | no shell strings, string lists, or `:Cmd` |
| `keys` | lazy's key spec, mapped the moment the plugin loads. | no lazy-load triggers, so an entry with no rhs is dropped |
| `version` | Semver range (`'1.*'`, `'^1.2'`, `'*'`) or a plain branch, tag, or sha. | no separate `branch` / `tag` / `commit` |
| `pin` | Left out of updates. | same |
| `priority` | Load-order hint, default 50. Dependencies win. | same default, but it applies to every plugin |
| `import` | Module name. Replaces itself with the specs that module and its children return. | same, but it is the whole entry: `{ import = 'plugins' }` carries no other fields |

Every other lazy field (`lazy`, `event`, `ft`, `cmd`, `init`, `config`, `main`,
`enabled`, `cond`, `dev`, `optional`, `specs`, `module`, `submodules`,
`opts_extend`) is ignored without comment.

A plugin with no `opts` and no `post` never gets a `setup()` call.

### Imports

Module resolution copies lazy's `Util.lsmod`, so a directory laid out for lazy
imports unchanged:

- `lua/plugins/init.lua` is the module itself.
- Its sibling `.lua` files are submodules.
- A subdirectory comes in through its own `init.lua` and nothing else, so
  `lua/plugins/lsp/helper.lua` is reached only if `lua/plugins/lsp/init.lua`
  imports or requires it.
- A plain `lua/plugins.lua` with no directory beside it also works.

Files are required in sorted order, since runtimepath glob order is not stable.
Order barely matters anyway: `priority` and `dependencies` do the real sorting,
and duplicate specs merge by name no matter which file they came from. Each
module is required once, so the same `{ import = 'plugins' }` in two files costs
nothing and produces no duplicate warnings.

A module that fails to load, or returns something that is not a table,
contributes nothing and says so. So does an `import` matching no module on the
runtimepath: staying quiet there would drop every plugin in the directory you
meant to import.

A bare string is a module name only at the top level of `setup`. Inside
`dependencies` it references another spec by name. The two cannot be confused,
since every plugin source carries a `/` and no module name does.

## Load order

Priority descending, then a stable topological sort over the dependency edges.
Priority is only the pre-sort, so it can never move a plugin ahead of something
it depends on. Cycles break at the first-seen order rather than erroring.

Duplicate specs merge by derived name, first spec wins per field. Each collision
is reported through `vim.notify` and listed in the dashboard. One gets a louder
warning than the rest: a table `opts` in one spec against a function `opts` in
another. First-wins there decides whether `setup()` is called at all, so the
message names both sources.

### Module derivation

Which module gets `setup()` called on it, copied from lazy.nvim
(`lazy/core/loader.lua:399`), because the obvious version gets several plugins
wrong:

1. `mini.*` other than `mini.nvim` returns the name as given.
2. Normalize the name (lowercase, drop a leading `n?vim-`, a trailing `.n?vim`,
   then every non-letter) and match it against the top-level modules in the
   plugin's `lua/`. An exact match wins.
3. Otherwise, if the plugin has exactly one top-level module, use that.

Step 3 is what turns `canola.nvim` into `oil` and `qalculate.nvim` into `qalc`.
Step 2 separates `nvim-dap-view` (module `dap-view`) from
`nvim-highlight-colors`, which keeps its prefix.

### Versions

`vim.pack` wants either a branch, tag, or sha string, or a
`vim.version.range()` object. pack_plus translates a string to a range only when
it carries a range operator or wildcard. `vim.version.range` is lenient enough
to read the sha `a5aa62e37b` as the range `5.0.0 - 6.0.0`, which would quietly
pin you to a tag you never asked for, so anything without `*`, `^`, `~`, `<`,
`>`, `=`, or ` - ` goes through as the plain string it is.

## Timing

A plugin's cost arrives in two pieces, and you have to add them up.

`:packadd {name}` without `!` sources the plugin's `plugin/` files twice during
startup, once immediately and once in Neovim's normal post-`init.lua` runtime
pass. That is why `vim.pack.add` defaults to `load = vim.v.vim_did_init == 1`
(`vim/pack.lua:848`), and it means pack_plus cannot take over loading to time
plugins directly, even though `load` accepts a function.

So it does this instead:

- Times the `setup`, `opts`, `post`, and `keys` calls directly, since it makes
  them.
- Attributes the post-`init.lua` `plugin/` pass with `SourcePre` / `SourcePost`,
  matching `ev.file` against each plugin's path. Those fire for `.lua` as well
  as `.vim`, nested, with full paths, so only the outermost frame is counted.
- Reports the sum.

Total startup runs from the moment `pack_plus.profile` is first required to
`UIEnter`, which is as close to lazy's number as you can get from inside the
process. Neovim's own pre-init cost is invisible from in here and is not
counted.

If you want to measure the manager's own overhead, interleave runs with it on
and off and compare the minima. Sequential batches of `--startuptime` drift by
about 10ms on my machine, which is enough to invent overhead that is not there.

## Dashboard

`:PackPlus`. Floating, full screen. The first paint needs only
`vim.pack.get(nil, { info = false })`, a lockfile read plus one directory scan,
so it opens instantly. Update information arrives after, from an async `git`
pass.

It shows loaded and not-loaded plugins with per-plugin times and the startup
total, pending updates that expand to commit subjects with breaking changes
highlighted, local-change warnings, plugins on disk the config does not load,
and any duplicate specs found during the merge.

| Key | Action |
| --- | --- |
| `u` | stage the update under the cursor |
| `U` | stage every update |
| `C-u` | stage anyway, overriding the local-changes block |
| `x` | delete under the cursor, after a confirm prompt |
| `i` | install specs missing from disk |
| `c` | delete every plugin on disk the config does not load |
| `<cr>` | expand the row |
| `q` | close |

Staged updates apply on confirmation. Declining leaves them staged, so you can
add more rows and confirm once.

That path deliberately avoids `vim.pack.update(names, { force = false })`, which
opens vim.pack's own confirmation buffer in a separate tabpage, and
`get({ info = true, offline = false })`, which fetches every repo and blocks the
UI until the slowest one answers. Instead `git.lua` does an async `git fetch` and
rev comparison, then hands the confirmed subset to
`vim.pack.update(subset, { force = true })`.

`i` after `x` puts the plugin back on disk but cannot re-source its `plugin/`
files or re-run a `setup()` that already ran, so it tells you to `:restart`.

### Local changes block the update

A plugin with a dirty worktree cannot be staged by `u` or `U`. The check is
`git status --porcelain --untracked-files=no`, run in the same async pass that
computes pending updates, so it costs nothing extra. Blocked rows expand to the
dirty file list instead of the changelog.

Untracked files are ignored on purpose. `git stash push` runs without `-u`, so
they survive an update untouched, and vim.pack writes `doc/tags` into most
plugins itself (`vim/pack.lua:742`). Counting those would mark nearly every
plugin dirty and block every update forever.

This has to be enforced here. It cannot be delegated, because `vim.pack`'s
`checkout` (`vim/pack.lua:713`) runs `git stash push` before every update with
no prompt and no notification. By the time `update()` is called the work is
already sitting in a stash the user does not know exists.

`C-u` is the escape hatch. Blocking with no override would make a plugin
permanently unupdatable after one stray edit. It stages the plugin and accepts
that vim.pack will stash.

## What vim.pack does not provide

Four gaps `git.lua` covers:

- Changelogs. `get({ info = true })` returns `rev` and `rev_to` hashes only.
  `infer_update_details` (`vim/pack.lua:784`) builds a real changelog but is
  local and never exported, so this runs `git log rev..rev_to` itself.
- Local-change detection. Not exposed at all.
- `dir`. `src` is required and must be git-cloneable, so local plugins cannot go
  through `vim.pack`. They go straight onto the runtimepath.
- `pin`. No equivalent, emulated by leaving the plugin out of the fetch and out
  of the `names` list passed to `update()`.

## Tests

```
./tests/run.sh
```

`tests/spec_spec.lua` covers collection, imports, merging, version translation,
and sort order with no network and no downloads. Run it alone with
`nvim -l tests/spec_spec.lua`.

The three smoke tests install real plugins into `/tmp/pack_plus_test`, override
`PACK_PLUS_SCRATCH` to put them elsewhere. `init_smoke.lua` checks load order,
setup, `post`, `build`, keys, and the timing split. `ui_smoke.lua` checks the
dashboard and the update path, including the local-changes block and the `C-u`
override. `delete_smoke.lua` checks `x`, `i`, and `c`.

`ui_smoke.lua` really does update a plugin, and really does let vim.pack stash
the `README.md` edit that `run.sh` made to trigger the block. Run
`git stash list` in that plugin afterwards to see the problem `C-u` exists to
warn about.
