--- The four things `vim.pack` does not hand out.
---
--- - Changelogs. `get({ info = true })` returns `rev` and `rev_to` hashes only;
---   `infer_update_details` (`vim/pack.lua:784`) builds a real changelog but is
---   local and never exported.
--- - Local-change detection. Not exposed at all.
--- - A version target we can compute without blocking the UI.
--- - `pin`, which we emulate by leaving the plugin out of the fetch.
---
--- Everything here runs through `vim.system` callbacks, sequenced with
--- coroutines. Nothing in this file touches the Neovim API, so it is safe in
--- the fast event contexts those callbacks run in; `inspect` schedules its own
--- completion callback.

--- @class pack_plus.GitPlug
--- @field name string
--- @field path string
--- @field version string|vim.VersionRange|nil
--- @field pin boolean?

--- @class pack_plus.Commit
--- @field sha string
--- @field subject string
--- @field breaking boolean

--- @class pack_plus.GitStatus
--- @field name string
--- @field head string?
--- @field target string? Where `version` resolves to on the remote.
--- @field pending boolean
--- @field revert boolean? Target is behind HEAD.
--- @field pinned boolean?
--- @field dirty string[] `git status --porcelain` lines.
--- @field commits pack_plus.Commit[]
--- @field err string?

local M = {}

--- Plugins inspected in parallel. Each one runs up to five short git commands.
local CONCURRENCY = 8

--- @type table<string, string>?
local git_env

--- Built once, on the main loop: `vim.fn` is off limits inside the `vim.system`
--- callbacks that drive the rest of this file.
local function build_env()
	git_env = vim.fn.environ()
	git_env.GIT_DIR, git_env.GIT_WORK_TREE = nil, nil
end

--- @param cmd string[]
--- @param cwd string
--- @param cb fun(ok: boolean, stdout: string, stderr: string)
local function run(cmd, cwd, cb)
	-- `-c gc.auto=0` keeps "Auto packing the repository" off stderr. Clearing
	-- GIT_DIR / GIT_WORK_TREE keeps an outer git invocation from redirecting us.
	local argv = vim.list_extend({ 'git', '-c', 'gc.auto=0' }, cmd)

	vim.system(argv, { cwd = cwd, text = true, env = git_env, clear_env = true }, function(res)
		cb(res.code == 0, vim.trim(res.stdout or ''), vim.trim(res.stderr or ''))
	end)
end

--- @param cmd string[]
--- @param cwd string
--- @return boolean ok
--- @return string stdout
--- @return string stderr
local function await(cmd, cwd)
	local co = assert(coroutine.running(), 'await outside a coroutine')
	run(cmd, cwd, function(ok, stdout, stderr)
		coroutine.resume(co, ok, stdout, stderr)
	end)
	return coroutine.yield()
end

--- @param path string
--- @param rev string
--- @return string?
local function rev_parse(path, rev)
	local ok, out = await({ 'rev-parse', '--verify', '--quiet', rev .. '^{commit}' }, path)
	return (ok and out ~= '') and out or nil
end

--- Resolve what the plugin should be at, mirroring `resolve_version`
--- (`vim/pack.lua:648`) without its blocking install path.
--- @param plugin pack_plus.GitPlug
--- @return string? sha
--- @return string? err
local function resolve_target(plugin)
	local version = plugin.version

	if type(version) == 'table' then
		local ok, out = await({ 'tag', '--list' }, plugin.path)
		if not ok then
			return nil, 'cannot list tags'
		end

		local best, best_tag
		for _, tag in ipairs(vim.split(out, '\n', { trimempty = true })) do
			local parsed = vim.version.parse(tag)
			if parsed and version:has(parsed) and (not best or vim.version.gt(parsed, best)) then
				best, best_tag = parsed, tag
			end
		end
		if not best_tag then
			return nil, ('no tag matches %s'):format(tostring(version))
		end
		local sha = rev_parse(plugin.path, best_tag)
		return sha, sha and nil or ('no commit for tag %s'):format(best_tag)
	end

	if type(version) == 'string' then
		-- A branch has to be read from the remote ref, or we would compare
		-- against a local branch that nothing moves.
		local sha = rev_parse(plugin.path, 'origin/' .. version) or rev_parse(plugin.path, version)
		return sha, sha and nil or ('unknown version %s'):format(version)
	end

	local sha = rev_parse(plugin.path, 'origin/HEAD')
	if sha then
		return sha
	end

	-- `origin/HEAD` is missing on repos cloned without it. Ask the remote.
	local ok, out = await({ 'remote', 'show', 'origin' }, plugin.path)
	local branch = ok and out:match('HEAD branch:%s*(%S+)')
	if branch then
		sha = rev_parse(plugin.path, 'origin/' .. branch)
	end
	return sha, sha and nil or 'cannot resolve default branch'
end

--- @param subject string
--- @return boolean
local function is_breaking(subject)
	return subject:match('^%w+%b()!:') ~= nil
		or subject:match('^%w+!:') ~= nil
		or subject:find('BREAKING CHANGE', 1, true) ~= nil
end

--- @param path string
--- @param range string
--- @return pack_plus.Commit[]
local function log(path, range)
	local ok, out = await({ 'log', '--no-show-signature', '--format=%h %s', range }, path)
	if not ok then
		return {}
	end

	local commits = {} --- @type pack_plus.Commit[]
	for _, line in ipairs(vim.split(out, '\n', { trimempty = true })) do
		local sha, subject = line:match('^(%S+) (.*)$')
		if sha then
			commits[#commits + 1] = { sha = sha, subject = subject, breaking = is_breaking(subject) }
		end
	end
	return commits
end

--- @param plugin pack_plus.GitPlug
--- @param offline boolean
--- @return pack_plus.GitStatus
local function inspect_one(plugin, offline)
	--- @type pack_plus.GitStatus
	local status = {
		name = plugin.name,
		pinned = plugin.pin == true,
		dirty = {},
		commits = {},
		pending = false,
	}

	if not vim.uv.fs_stat(vim.fs.joinpath(plugin.path, '.git')) then
		status.err = 'not a git repository'
		return status
	end

	-- Tracked modifications only. `git stash push` runs without `-u`, so
	-- untracked files survive an update untouched, and vim.pack writes
	-- `doc/tags` into most plugins itself (`vim/pack.lua:742`). Counting those
	-- would mark nearly every plugin dirty and block every update.
	local ok, out = await({ 'status', '--porcelain', '--untracked-files=no' }, plugin.path)
	if ok and out ~= '' then
		status.dirty = vim.split(out, '\n', { trimempty = true })
	end

	status.head = rev_parse(plugin.path, 'HEAD')

	if status.pinned then
		return status
	end

	if not offline then
		local fetched, _, err = await(
			{ 'fetch', '--quiet', '--tags', '--force', '--recurse-submodules=no', 'origin' },
			plugin.path
		)
		if not fetched then
			status.err = err ~= '' and err or 'fetch failed'
			return status
		end
	end

	local target, err = resolve_target(plugin)
	if not target then
		status.err = err
		return status
	end
	status.target = target

	if status.head == target then
		return status
	end

	status.pending = true
	status.commits = log(plugin.path, status.head .. '..' .. target)
	if #status.commits == 0 then
		-- Target is behind HEAD: a downgrade, which is what a narrowed `version`
		-- looks like.
		status.commits = log(plugin.path, target .. '..' .. status.head)
		status.revert = #status.commits > 0
	end

	return status
end

--- @param plugins pack_plus.GitPlug[]
--- @param opts { offline?: boolean }
--- @param on_done fun(results: table<string, pack_plus.GitStatus>)
function M.inspect(plugins, opts, on_done)
	local results = {} --- @type table<string, pack_plus.GitStatus>
	local next_index, running, finished = 1, 0, false

	local function done()
		if not finished then
			finished = true
			vim.schedule(function()
				on_done(results)
			end)
		end
	end

	local function pump()
		while running < CONCURRENCY and next_index <= #plugins do
			local plugin = plugins[next_index]
			next_index = next_index + 1
			running = running + 1

			local co = coroutine.create(function()
				local ok, res = xpcall(inspect_one, debug.traceback, plugin, opts.offline == true)
				results[plugin.name] = ok and res
					or { name = plugin.name, dirty = {}, commits = {}, pending = false, err = res }
				running = running - 1
				pump()
			end)
			local ok, err = coroutine.resume(co)
			if not ok then
				results[plugin.name] =
					{ name = plugin.name, dirty = {}, commits = {}, pending = false, err = err }
				running = running - 1
			end
		end

		if running == 0 and next_index > #plugins then
			done()
		end
	end

	if #plugins == 0 then
		return done()
	end
	build_env()
	pump()
end

return M
