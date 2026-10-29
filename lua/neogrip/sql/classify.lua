-- What kind of statement is this?
--
-- The answer decides three things: whether the result can be wrapped in a
-- LIMIT, how it can be validated without running it (a server validates DML and
-- DDL by different means), and whether a read-only connection must refuse it.
local M = {}

local KIND_BY_VERB = {
	select = "select",
	with = "select",
	table = "select",
	values = "select",
	show = "select",
	describe = "select",
	desc = "select",
	explain = "select",
	pragma = "select",
	insert = "dml",
	update = "dml",
	delete = "dml",
	merge = "dml",
	replace = "dml",
	upsert = "dml",
	truncate = "ddl",
	create = "ddl",
	alter = "ddl",
	drop = "ddl",
	comment = "ddl",
	grant = "ddl",
	revoke = "ddl",
	vacuum = "ddl",
	analyze = "ddl",
	reindex = "ddl",
	refresh = "ddl",
	attach = "ddl",
	detach = "ddl",
	call = "call",
	exec = "call",
	execute = "call",
	begin = "tx",
	commit = "tx",
	rollback = "tx",
	start = "tx",
	savepoint = "tx",
	set = "session",
	use = "session",
	copy = "other",
}

--- Strip leading comments and whitespace so the first word is the verb.
function M.strip_leading_comments(sql)
	local text = sql
	while true do
		local before = text
		text = text:gsub("^%s+", "")
		text = text:gsub("^%-%-[^\n]*\n?", "")
		if text:sub(1, 2) == "/*" then
			local depth, index, length = 1, 3, #text
			while index <= length and depth > 0 do
				local pair = text:sub(index, index + 1)
				if pair == "/*" then
					depth, index = depth + 1, index + 2
				elseif pair == "*/" then
					depth, index = depth - 1, index + 2
				else
					index = index + 1
				end
			end
			text = text:sub(index)
		end
		if text == before then
			return text
		end
	end
end

--- @return string "select"|"dml"|"ddl"|"call"|"tx"|"session"|"other"
function M.kind(sql)
	local text = M.strip_leading_comments(sql or "")
	local verb = text:match("^([%a_]+)")
	if not verb then
		return "other"
	end
	verb = verb:lower()

	-- A CTE can end in INSERT/UPDATE/DELETE, which writes despite starting
	-- with WITH. Checking for the keyword after the closing parenthesis is
	-- brittle, so look for the verb at the top level of the text instead.
	if verb == "with" then
		local lowered = text:lower()
		if
			lowered:match("%)%s*insert%s")
			or lowered:match("%)%s*update%s")
			or lowered:match("%)%s*delete%s")
		then
			return "dml"
		end
		return "select"
	end

	-- "EXPLAIN ANALYZE" runs the statement for real: it is not a read.
	if verb == "explain" and text:lower():match("^explain%s+analy[sz]e") then
		return "dml"
	end

	return KIND_BY_VERB[verb] or "other"
end

--- True when the statement already limits its own rows, so wrapping it would
--- change what the author asked for.
function M.has_limit(sql, dialect)
	local lowered = (sql or ""):lower()
	if dialect == "mssql" then
		return lowered:match("^%s*select%s+top%s") ~= nil or lowered:match("offset%s+%d+%s+rows") ~= nil
	end
	return lowered:match("limit%s+%d") ~= nil or lowered:match("fetch%s+first") ~= nil
end

--- Statements that cannot be wrapped in a subquery without changing meaning.
function M.wrappable(sql, dialect)
	local lowered = (sql or ""):lower()
	if M.kind(sql) ~= "select" then
		return false
	end
	if M.has_limit(sql, dialect) then
		return false
	end
	-- FOR UPDATE / FOR SHARE must stay at the top level.
	if lowered:match("for%s+update") or lowered:match("for%s+share") or lowered:match("for%s+no%s+key") then
		return false
	end
	-- SHOW / DESCRIBE / PRAGMA are not subqueryable anywhere.
	local verb = (M.strip_leading_comments(sql):match("^([%a_]+)") or ""):lower()
	if verb == "show" or verb == "describe" or verb == "desc" or verb == "pragma" or verb == "explain" then
		return false
	end
	if dialect == "mssql" then
		-- A subquery with ORDER BY and no TOP is invalid T-SQL.
		return not lowered:match("order%s+by")
	end
	return true
end

--- A write with no WHERE: worth a louder confirmation than the usual one.
function M.unguarded_write(sql)
	local kind = M.kind(sql)
	if kind ~= "dml" then
		return false
	end
	local lowered = (sql or ""):lower()
	if lowered:match("^%s*insert") then
		return false
	end
	return not lowered:match("%swhere%s")
end

return M
