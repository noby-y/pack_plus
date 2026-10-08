-- Reached only if `plugins.lsp` imports it; a plain import of `plugins` must
-- not walk into a subdirectory's other files.
return {
	{ 'a/not-imported' },
}
