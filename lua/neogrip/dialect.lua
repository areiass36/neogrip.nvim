-- Highlighting that follows the chosen database.
--
-- Treesitter's sql parser covers ANSI and Postgres well, and T-SQL not at all:
-- it errors on [bracketed names], TOP, @variables, MERGE, DECLARE and GO. So a
-- SQL Server buffer turns treesitter off and uses the syntax file in
-- syntax/tsql.vim instead, while the other dialects keep treesitter and get an
-- extra layer of their own keywords on top.
--
-- That layer is drawn with extmarks at priority 110: treesitter highlights at
-- 100 (vim.hl.priorities.treesitter), semantic tokens at 125 and diagnostics at
-- 150, so 110 sits above the parser and below both. matchadd would be the other
-- option and is worse: its priority scale is separate and it is per window, so
-- it breaks as soon as the buffer is shown in a split.
local M = {}

local NAMESPACE = vim.api.nvim_create_namespace("neogrip_dialect")
local PRIORITY = 110

-- Only what the sql parser does not already know. Function names get
-- @function.builtin, type names @type.builtin, operators @operator.
local DIALECTS = {
	postgres = {
		functions = {
			"jsonb_agg",
			"jsonb_build_object",
			"jsonb_build_array",
			"jsonb_each",
			"jsonb_set",
			"json_agg",
			"json_build_object",
			"to_jsonb",
			"to_json",
			"jsonb_array_elements",
			"generate_series",
			"array_agg",
			"string_agg",
			"unnest",
			"coalesce",
			"nullif",
			"date_trunc",
			"age",
			"now",
			"encode",
			"decode",
			"gen_random_uuid",
			"format",
			"row_to_json",
			"regexp_replace",
			"regexp_matches",
			"split_part",
			"lateral",
		},
		types = {
			"jsonb",
			"json",
			"uuid",
			"timestamptz",
			"timestamp",
			"interval",
			"numeric",
			"serial",
			"bigserial",
			"text",
			"bytea",
			"inet",
			"cidr",
			"tsvector",
			"tsquery",
			"citext",
		},
		keywords = {
			"ilike",
			"returning",
			"conflict",
			"excluded",
			"materialized",
			"unlogged",
			"lateral",
			"distinct",
		},
	},
	mysql = {
		functions = {
			"group_concat",
			"json_extract",
			"json_object",
			"json_array",
			"json_unquote",
			"ifnull",
			"if",
			"date_format",
			"str_to_date",
			"unix_timestamp",
			"from_unixtime",
			"concat_ws",
			"find_in_set",
			"last_insert_id",
			"any_value",
		},
		types = { "tinyint", "mediumint", "datetime", "longtext", "mediumtext", "enum", "json", "blob" },
		keywords = { "duplicate", "straight_join", "ignore", "delayed", "engine", "charset", "collate" },
	},
	mariadb = {},
	sqlite = {
		functions = {
			"ifnull",
			"iif",
			"json_extract",
			"json_object",
			"group_concat",
			"strftime",
			"julianday",
			"random",
		},
		types = { "integer", "real", "blob", "numeric" },
		keywords = { "autoincrement", "rowid", "vacuum", "pragma", "without" },
	},
	duckdb = {
		functions = {
			"read_csv",
			"read_csv_auto",
			"read_parquet",
			"read_json",
			"read_json_auto",
			"list_value",
			"struct_pack",
			"unnest",
			"generate_series",
			"regexp_matches",
			"string_split",
			"epoch",
		},
		types = { "struct", "list", "map", "union", "hugeint", "utinyint", "varchar", "blob" },
		keywords = { "exclude", "replace", "qualify", "positional", "asof", "pivot", "unpivot", "using" },
	},
	trino = {
		functions = {
			"approx_distinct",
			"approx_percentile",
			"arbitrary",
			"array_agg",
			"array_join",
			"at_timezone",
			"cardinality",
			"contains",
			"date_add",
			"date_diff",
			"date_trunc",
			"element_at",
			"filter",
			"format_datetime",
			"from_iso8601_timestamp",
			"from_unixtime",
			"histogram",
			"json_extract",
			"json_extract_scalar",
			"listagg",
			"map_agg",
			"map_from_entries",
			"reduce",
			"regexp_extract",
			"regexp_like",
			"sequence",
			"slice",
			"split",
			"split_part",
			"transform",
			"try",
			"try_cast",
			"unnest",
			"with_timezone",
			"zip",
		},
		types = {
			"varchar",
			"varbinary",
			"bigint",
			"tinyint",
			"real",
			"decimal",
			"array",
			"map",
			"row",
			"json",
			"uuid",
			"ipaddress",
			"hyperloglog",
			"tdigest",
			"qdigest",
		},
		keywords = { "catalogs", "schemas", "ordinality", "tablesample", "bernoulli", "match_recognize" },
	},
	mssql = {},
	mongodb = {},
}

-- mariadb is mysql with another name on the tin.
DIALECTS.mariadb = DIALECTS.mysql

local function spec(driver)
	local dialect = DIALECTS[driver]
	if not dialect or not dialect.functions then
		return nil
	end
	local words = {}
	for _, word in ipairs(dialect.functions) do
		words[word] = "@function.builtin"
	end
	for _, word in ipairs(dialect.types) do
		words[word] = "@type.builtin"
	end
	for _, word in ipairs(dialect.keywords) do
		words[word] = "@keyword"
	end
	return words
end

--- Is this position inside a string or a comment? Highlighting a keyword there
--- would be wrong.
---
--- Treesitter knows the answer, but only once it has parsed the buffer; before
--- that it reports no captures at all and every string would be highlighted. So
--- a small lexer is the fallback, and also the answer for a buffer treesitter
--- is not attached to.
local function lexical_in_string_or_comment(line, col)
	local index = 1
	local quote = nil
	while index <= col do
		local char = line:sub(index, index)
		if quote then
			if char == quote then
				if line:sub(index + 1, index + 1) == quote then
					index = index + 1
				else
					quote = nil
				end
			end
		elseif char == "'" or char == '"' or char == "`" then
			quote = char
		elseif char == "-" and line:sub(index + 1, index + 1) == "-" then
			return true
		elseif char == "/" and line:sub(index + 1, index + 1) == "*" then
			return true
		end
		index = index + 1
	end
	return quote ~= nil
end

local function in_string_or_comment(bufnr, row, col)
	if vim.treesitter.highlighter.active[bufnr] then
		local ok, captures = pcall(vim.treesitter.get_captures_at_pos, bufnr, row, col)
		if ok and #captures > 0 then
			for _, capture in ipairs(captures) do
				local name = capture.capture
				if name:match("^string") or name:match("^comment") then
					return true
				end
			end
			return false
		end
	end
	local line = vim.api.nvim_buf_get_lines(bufnr, row, row + 1, false)[1] or ""
	return lexical_in_string_or_comment(line, col)
end

local attached = {}
local pending = {}
local tsql = {}

--- Hand a buffer to syntax/tsql.vim.
---
--- Scheduled, and repeated on the Syntax event: setting 'syntax' from inside
--- the FileType handler that opened the file does not stick, because the
--- runtime's own syntax autocommand runs afterwards and sets it back to the
--- filetype.
local function apply_tsql(bufnr)
	tsql[bufnr] = true
	vim.schedule(function()
		if not vim.api.nvim_buf_is_valid(bufnr) or not tsql[bufnr] then
			return
		end
		pcall(vim.treesitter.stop, bufnr)
		if vim.bo[bufnr].syntax ~= "tsql" then
			vim.bo[bufnr].syntax = "tsql"
		end
	end)
end

local function draw(bufnr)
	local words = attached[bufnr]
	if not words or not vim.api.nvim_buf_is_valid(bufnr) then
		return
	end

	vim.api.nvim_buf_clear_namespace(bufnr, NAMESPACE, 0, -1)
	local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
	for row, text in ipairs(lines) do
		local index = 1
		while true do
			local from, to, word = text:find("([%a_][%w_]*)", index)
			if not from then
				break
			end
			local group = words[word:lower()]
			if group and not in_string_or_comment(bufnr, row - 1, from - 1) then
				pcall(vim.api.nvim_buf_set_extmark, bufnr, NAMESPACE, row - 1, from - 1, {
					end_col = to,
					hl_group = group,
					priority = PRIORITY,
				})
			end
			index = to + 1
		end
	end
end

--- Redraw once the buffer stops changing. Marks are set outside the redraw
--- cycle on purpose: deciding whether a word sits inside a string asks
--- treesitter to parse, which is not something to do from a decoration
--- provider.
local function schedule_draw(bufnr)
	if pending[bufnr] then
		pending[bufnr]:stop()
	end
	pending[bufnr] = vim.defer_fn(function()
		pending[bufnr] = nil
		draw(bufnr)
	end, 120)
end

--- @param driver string
function M.attach(bufnr, driver)
	vim.b[bufnr].neogrip_dialect = driver

	if driver == "mssql" then
		-- Treesitter would mark most of a real T-SQL file as an error; the
		-- syntax file understands it.
		attached[bufnr] = nil
		vim.api.nvim_buf_clear_namespace(bufnr, NAMESPACE, 0, -1)
		apply_tsql(bufnr)
		return
	end

	if driver == "mongodb" then
		vim.bo[bufnr].filetype = "mongodb"
		attached[bufnr] = nil
		return
	end

	if tsql[bufnr] then
		-- Hand the buffer back to its filetype and to treesitter.
		tsql[bufnr] = nil
		vim.bo[bufnr].syntax = vim.bo[bufnr].filetype
		pcall(vim.treesitter.start, bufnr)
	end
	attached[bufnr] = spec(driver)
	schedule_draw(bufnr)
end

function M.detach(bufnr)
	attached[bufnr] = nil
	tsql[bufnr] = nil
	vim.api.nvim_buf_clear_namespace(bufnr, NAMESPACE, 0, -1)
end

function M.setup()
	local group = vim.api.nvim_create_augroup("NeogripDialect", { clear = true })
	vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI", "InsertLeave", "BufWinEnter" }, {
		group = group,
		callback = function(args)
			if attached[args.buf] then
				schedule_draw(args.buf)
			end
		end,
	})
	-- :syntax on, a colorscheme change or reopening the file all reset 'syntax'.
	vim.api.nvim_create_autocmd({ "Syntax", "BufWinEnter" }, {
		group = group,
		callback = function(args)
			if tsql[args.buf] and vim.bo[args.buf].syntax ~= "tsql" then
				apply_tsql(args.buf)
			end
		end,
	})
end

M.in_string_or_comment = in_string_or_comment

--- For the tests: draw synchronously and report the marks.
function M.draw_now(bufnr)
	draw(bufnr)
	return vim.api.nvim_buf_get_extmarks(bufnr, NAMESPACE, 0, -1, { details = true })
end

return M
