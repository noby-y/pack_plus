--- `build` dispatch, driven by `PackChanged`.

local M = {}

--- @type table<string, fun(info: { name: string, path: string })>
local builders = {}

local registered = false

--- Register the handler. This has to happen before the session's first
--- `vim.pack` call: that call runs `lock_sync` (`vim/pack.lua:906`), which
--- installs every plugin present in the lockfile but missing from disk and
--- fires `PackChanged` as it goes. A handler registered afterwards misses those
--- events, and first-time installs skip `build` without saying anything.
function M.init()
	if registered then
		return
	end
	registered = true

	vim.api.nvim_create_autocmd('PackChanged', {
		group = vim.api.nvim_create_augroup('PackPlusBuild', { clear = true }),
		callback = function(ev)
			local data = ev.data
			if data.kind ~= 'install' and data.kind ~= 'update' then
				return
			end

			local build = builders[data.spec.name]
			if not build then
				return
			end

			local ok, err = pcall(build, { name = data.spec.name, path = data.path })
			if not ok then
				vim.notify(
					('pack_plus: `build` failed for `%s`:\n%s'):format(data.spec.name, err),
					vim.log.levels.ERROR
				)
			end
		end,
	})
end

--- @param plugins pack_plus.Plugin[]
function M.register(plugins)
	for _, plugin in ipairs(plugins) do
		if type(plugin.build) == 'function' then
			builders[plugin.name] = plugin.build
		end
	end
end

return M
