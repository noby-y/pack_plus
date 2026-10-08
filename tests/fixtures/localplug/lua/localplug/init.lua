local M = {}

function M.setup(opts)
	vim.g.localplug_greeting = opts.greeting
end

return M
