-- Splitting, classifying and paging statements.
local support = require("tests.support")
local check = support.check
local classify = require("neogrip.sql.classify")
local split = require("neogrip.sql.split")

local function texts(sql, dialect)
	return vim.tbl_map(function(statement)
		return statement.text
	end, split.statements(sql, dialect))
end

support.describe("sql/split")
check("two statements", texts("select 1;\nselect 2;\n"), { "select 1", "select 2" })
check("no trailing semicolon", texts("select 1"), { "select 1" })
check("semicolon in a string", texts("select 'a;b';\nselect 2;"), { "select 'a;b'", "select 2" })
check(
	"semicolon in a line comment",
	texts("select 1 -- ; nope\n;select 2;"),
	{ "select 1 -- ; nope", "select 2" }
)
check("nested block comment", texts("/* a /* b */ ; c */ select 1;"), { "/* a /* b */ ; c */ select 1" })
check(
	"dollar-quoted body",
	texts("create function f() returns int as $$ begin return 1; end $$ language plpgsql;\nselect 2;"),
	{ "create function f() returns int as $$ begin return 1; end $$ language plpgsql", "select 2" }
)
check(
	"tagged dollar quote",
	texts("select $tag$ a;b $tag$;select 2;"),
	{ "select $tag$ a;b $tag$", "select 2" }
)
check("doubled quote", texts("select 'it''s; here';select 2;"), { "select 'it''s; here'", "select 2" })
check(
	"bracketed identifier",
	texts("select [a;b] from [t];select 2;", "mssql"),
	{ "select [a;b] from [t]", "select 2" }
)
check("GO batches", texts("select 1\nGO\nselect 2\nGO\n", "mssql"), { "select 1", "select 2" })
check(
	"DELIMITER",
	texts("DELIMITER //\ncreate trigger t begin select 1; end //\nDELIMITER ;\nselect 2;", "mysql"),
	{ "create trigger t begin select 1; end", "select 2" }
)
check(
	"backticked identifier",
	texts("select `a;b` from t;select 2;", "mysql"),
	{ "select `a;b` from t", "select 2" }
)

local statements = split.statements("select 1;\n\nselect\n  2;\n")
check("line numbers", {
	statements[1].start_line,
	statements[1].end_line,
	statements[2].start_line,
	statements[2].end_line,
}, { 1, 1, 3, 4 })

support.describe("sql/classify")
check("select", classify.kind("SELECT 1"), "select")
check("cte reading", classify.kind("WITH x AS (SELECT 1) SELECT * FROM x"), "select")
check("cte writing", classify.kind("WITH x AS (SELECT 1) INSERT INTO t SELECT * FROM x"), "dml")
check("leading comment ignored", classify.kind("-- a comment\n/* another */ update t set a = 1"), "dml")
check("ddl", classify.kind("drop table t"), "ddl")
check("explain reads", classify.kind("explain select 1"), "select")
check("explain analyze writes", classify.kind("EXPLAIN ANALYZE delete from t"), "dml")
check("transaction", classify.kind("begin"), "tx")
check("unguarded delete", classify.unguarded_write("delete from t"), true)
check("guarded delete", classify.unguarded_write("delete from t where id = 1"), false)
check("insert is not unguarded", classify.unguarded_write("insert into t values (1)"), false)

support.describe("sql/classify: what can be wrapped in a subquery")
check("a plain select", classify.wrappable("select * from t", "postgres"), true)
check("one that already limits", classify.wrappable("select * from t limit 10", "postgres"), false)
check("for update", classify.wrappable("select * from t for update", "postgres"), false)
check("show", classify.wrappable("show tables", "mysql"), false)
check("pragma", classify.wrappable("pragma table_info('t')", "sqlite"), false)
check("an insert", classify.wrappable("insert into t values (1)", "postgres"), false)
check("mssql with order by", classify.wrappable("select * from t order by id", "mssql"), false)
check("mssql without order by", classify.wrappable("select * from t", "mssql"), true)

support.describe("sql/classify: wrappable is only used for the write guards now")
-- Paging stopped rewriting SQL when the client became JDBC: the driver caps
-- the rows with setMaxRows and the runner skips the offset, so nothing is
-- spliced into the statement and no dialect needs a LIMIT spelled out.
check("a select is still recognised", classify.kind("select * from t"), "select")
check("and a write still is", classify.kind("delete from t where id = 1"), "dml")

support.describe("sql/split: a backslash is only an escape in mysql")

-- A long bracket so the backslash below is one literal character, with no
-- escaping to reason about in the test itself.
local BS = [[\]]

check(
	"trino: a string ending in a backslash does not swallow the terminator",
	texts("select split_part(path, '" .. BS .. "', 1);\nselect 2;", "trino"),
	{ "select split_part(path, '" .. BS .. "', 1)", "select 2" }
)

check(
	"postgres reads it the same way",
	texts("select '" .. BS .. "' as sep;\nselect 2;", "postgres"),
	{ "select '" .. BS .. "' as sep", "select 2" }
)

check(
	"mysql keeps the escape, so that quote does not close the string",
	texts("select '" .. BS .. "' , 1;\nselect 2;", "mysql"),
	{ "select '" .. BS .. "' , 1;\nselect 2;" }
)

check(
	"no dialect at all is the standard reading, not mysql's",
	texts("select '" .. BS .. "';\nselect 2;"),
	{ "select '" .. BS .. "'", "select 2" }
)

check(
	"a doubled quote is still the escape everywhere",
	texts("select 'it''s; fine';\nselect 2;", "trino"),
	{ "select 'it''s; fine'", "select 2" }
)
