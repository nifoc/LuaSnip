-- loads snippets from directory structured almost like snipmate-collection:
-- - files all named <ft>.lua
-- - each returns table containing keys (optional) "snippets" and
--   "autosnippets", value for each a list of snippets.
--
-- cache:
-- - lazy_load_paths: {
-- 	{
-- 		add_opts = {...},
-- 		ft1 = {filename1, filename2},
-- 		ft2 = {filename1},
-- 		...
-- 	}, {
-- 		add_opts = {...},
-- 		ft1 = {filename1},
-- 		...
-- 	}
-- }
--
-- each call to load generates a new entry in that list. We cannot just merge
-- all files for some ft since add_opts might be different (they might be from
-- different lazy_load-calls).

local cache = require("luasnip.loaders._caches").lua
local path_mod = require("luasnip.util.path")
local loader_util = require("luasnip.loaders.util")
local util = require("luasnip.util.util")
local ls = require("luasnip")

local M = {}

local function load_files(ft, files, add_opts)
	for _, file in ipairs(files) do
		local func_string = path_mod.read_file(file)
		-- bring snippet-constructors into global scope for that function.
		func_string = 'require("luasnip").setup_snip_env() ' .. func_string
		local file_snippets, file_autosnippets = loadstring(func_string)()

		-- make sure these aren't nil.
		file_snippets = file_snippets or {}
		file_autosnippets = file_autosnippets or {}

		-- keep track of snippet-source.
		cache.path_snippets[file] = {
			snippets = file_snippets,
			autosnippets = file_autosnippets,
			add_opts = add_opts,
			ft = ft,
		}

		-- use lua autocommands here as soon as they're stable.
		-- stylua: ignore
		vim.cmd(string.format(
			[[
				augroup luasnip_watch_%s
				autocmd!
				autocmd BufWritePost %s lua require("luasnip.loaders.from_lua").reload_file("%s")
			]],
			-- augroup name may not contain spaces.
			file:gsub(" ", "_"),
			-- escape for autocmd-pattern.
			file:gsub(" ", "\\ "),
			file
		))

		ls.add_snippets(
			ft,
			file_snippets,
			vim.tbl_extend("keep", {
				type = "snippets",
				key = "__snippets_" .. file,
				-- prevent refresh here, will be done outside loop.
				refresh_notify = false,
			}, add_opts)
		)
		ls.add_snippets(
			ft,
			file_autosnippets,
			vim.tbl_extend("keep", {
				type = "autosnippets",
				key = "__autosnippets_" .. file,
				-- prevent refresh here, will be done outside loop.
				refresh_notify = false,
			}, add_opts)
		)
	end

	ls.refresh_notify(ft)
end

function M._load_lazy_loaded()
	local fts = util.get_snippet_filetypes()
	for _, ft in ipairs(fts) do
		if not cache.lazy_loaded_ft[ft] then
			for _, load_call_paths in ipairs(cache.lazy_load_paths) do
				cache.lazy_loaded_ft[ft] = true
				load_files(
					ft,
					load_call_paths[ft] or {},
					load_call_paths.add_opts
				)
			end
		end
	end
end

function M.load(opts)
	opts = opts or {}

	local collections = loader_util.get_load_paths_snipmate_like(
		opts,
		"luasnippets",
		"lua"
	)
	for _, collection in ipairs(collections) do
		local load_paths = collection.load_paths

		-- also add files from collection to cache (collection of all loaded
		-- files by filetype, useful for editing files for some filetype).
		loader_util.extend_ft_paths(cache.ft_paths, load_paths)

		for ft, files in pairs(load_paths) do
			load_files(ft, files, opts.add_opts or {})
		end
	end
end

function M.lazy_load(opts)
	opts = opts or {}
	local add_opts = opts.add_opts or {}

	local collections = loader_util.get_load_paths_snipmate_like(
		opts,
		"luasnippets",
		"lua"
	)
	for _, collection in ipairs(collections) do
		local load_paths = collection.load_paths

		loader_util.extend_ft_paths(cache.ft_paths, load_paths)

		for ft, files in pairs(load_paths) do
			if cache.lazy_loaded_ft[ft] then
				-- instantly load snippets if they were already loaded...
				load_files(ft, files, add_opts)

				-- don't load these files again.
				load_paths[ft] = nil
			end
		end

		load_paths.add_opts = add_opts
		table.insert(cache.lazy_load_paths, load_paths)
	end
	-- call once for current filetype. Necessary for lazy_loading snippets in
	-- empty, initial buffer, and will not cause issues like duplicate
	-- snippets.
	M._load_lazy_loaded()
end

function M.reload_file(filename)
	local file_cache = cache.path_snippets[filename]
	-- only clear and load(!!! snippets may not actually be loaded, lazy_load)
	-- if the snippets were really loaded.
	if file_cache then
		local add_opts = file_cache.add_opts
		local ft = file_cache.ft

		load_files(ft, { filename }, add_opts)
		ls.clean_invalidated({ inv_limit = 100 })
	end
end

function M.edit_snippet_files()
	loader_util.edit_snippet_files(cache.ft_paths)
end

-- register during startup (not really startup, as soon as this file is
-- required) so it'll work even if lazy_load is only called after the events
-- for some buffers already fired.
vim.cmd([[
augroup _luasnip_lua_lazy_load
	autocmd!
	au BufWinEnter,FileType * lua require('luasnip.loaders.from_lua')._load_lazy_loaded()
	au User LuasnipCleanup lua require('luasnip.loaders._caches').lua:clean()
augroup END
]])

return M
