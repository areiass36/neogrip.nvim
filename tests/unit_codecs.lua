-- The decoders, which is where a mistake quietly changes data.
local support = require("tests.support")
local check = support.check
local csv = require("neogrip.codec.csv")
local neogrip = require("neogrip")
local json = require("neogrip.codec.json")

support.describe("codec/json: column order")
check("as written", json.key_order('[{"b":1,"a":2,"zz":3}]'), { "b", "a", "zz" })
check("nested keys are not columns", json.key_order('[{"a":{"inner":1},"b":[{"deep":2}]}]'), { "a", "b" })
check("union across documents", json.key_order('[{"a":1},{"b":2}]'), { "a", "b" })
check("a colon inside a value", json.key_order('[{"url":"http://x:1","n":2}]'), { "url", "n" })
check("an escaped quote in a key", json.key_order('[{"a\\"b":1}]'), { 'a"b' })

support.describe("codec/json: integers a double cannot hold")
check("quoted", json.quote_big_integers('[{"big":9007199254740993}]'), '[{"big":"9007199254740993"}]')
check("small ones left alone", json.quote_big_integers('[{"n":123456}]'), '[{"n":123456}]')
check("floats left alone", json.quote_big_integers('[{"n":1.5,"m":1e10}]'), '[{"n":1.5,"m":1e10}]')
check(
	"digits inside a string left alone",
	json.quote_big_integers('[{"s":"99999999999999999999"}]'),
	'[{"s":"99999999999999999999"}]'
)
check(
	"value survives decoding",
	json.result_sets('[{"big":9007199254740993}]')[1].rows[1][1],
	"9007199254740993"
)

support.describe("codec/json: NULL is not the empty string")
local sets = json.result_sets('[{"a":1,"b":null,"c":""}]')
check("one result set", #sets, 1)
check("columns", sets[1].columns, { "a", "b", "c" })
check("null becomes the sentinel", sets[1].rows[1][2] == neogrip.NULL, true)
check("the empty string stays a string", sets[1].rows[1][3], "")

support.describe("codec/json: output shapes")
check("one array per line (usql)", #json.result_sets('[{"a":1}]\n[{"b":2}]\n'), 2)
check("an array across lines (duckdb)", #json.result_sets('[{"a":1},\n{"a":2}]')[1].rows, 2)
check("nothing at all", json.result_sets(""), {})

support.describe("codec/json: extended json from mongo")
local documents = json.documents(
	'[{"_id":{"$numberInt":"1"},"when":{"$date":{"$numberLong":"1704153600000"}},'
		.. '"total":{"$numberDecimal":"99.99"},"tags":["a","b"],"cust":{"name":"Ann"}}]'
)
check("fields in order", documents.columns, { "_id", "when", "total", "tags", "cust" })
check("int unwrapped", documents.rows[1][1], "1")
check("date readable", documents.rows[1][2], "2024-01-02T00:00:00Z")
check("decimal kept exact", documents.rows[1][3], "99.99")
check("array summarised", documents.rows[1][4], "[2]")
check("object summarised", documents.rows[1][5], "{…}")
check("the document is kept whole", documents.documents[1].cust.name, "Ann")

support.describe("codec/csv: RFC 4180")
check("plain", csv.decode("a,b\n1,2\n"), { { "a", "b" }, { "1", "2" } })
check("no trailing newline", csv.decode("a,b\n1,2"), { { "a", "b" }, { "1", "2" } })
check("comma inside a field", csv.decode('x\n"a,b"\n'), { { "x" }, { "a,b" } })
check("doubled quote", csv.decode('x\n"he said ""hi"""\n'), { { "x" }, { 'he said "hi"' } })
check("newline inside a field", csv.decode('x\n"li\nnha"\n'), { { "x" }, { "li\nnha" } })
check("crlf", csv.decode("a,b\r\n1,2\r\n"), { { "a", "b" }, { "1", "2" } })
check("empty fields", csv.decode("a,,b\n"), { { "a", "", "b" } })
check("quoted empty field", csv.decode('a,"",b\n'), { { "a", "", "b" } })
check("trailing empty field", csv.decode("a,b,\n"), { { "a", "b", "" } })
check("null marker", csv.decode("a,\\N,\n", { null_marker = "\\N" })[1][2] == neogrip.NULL, true)
check("a quoted marker is a string", csv.decode('a,"\\N",\n', { null_marker = "\\N" })[1][2], "\\N")

support.describe("codec/csv: fed in chunks")
local awkward = 'id,txt\n1,"a,b"\n2,"li\nnha"\n3,"he ""said"""\r\n4,plain\n'
local expected = {
	{ "id", "txt" },
	{ "1", "a,b" },
	{ "2", "li\nnha" },
	{ "3", 'he "said"' },
	{ "4", "plain" },
}
for _, size in ipairs({ 1, 2, 3, 5, 7, 13, 1000 }) do
	local parser = csv.new({})
	local rows = {}
	for index = 1, #awkward, size do
		vim.list_extend(rows, parser:feed(awkward:sub(index, index + size - 1)))
	end
	vim.list_extend(rows, parser:finish())
	check(("split every %d bytes"):format(size), rows, expected)
end

support.describe("codec/csv: writing")
check("plain", csv.encode_row({ "a", "b" }), "a,b")
check("comma quoted", csv.encode_row({ "a,b" }), '"a,b"')
check("quote doubled", csv.encode_row({ 'he "x"' }), '"he ""x"""')
check("newline quoted", csv.encode_row({ "a\nb" }), '"a\nb"')
check("null as the marker", csv.encode_row({ neogrip.NULL }, { null_marker = "\\N" }), "\\N")
check("leading space quoted", csv.encode_row({ " a" }), '" a"')
check(
	"round trip",
	csv.decode(
		csv.encode_row({ "a,b", 'q"q', "li\nnha", neogrip.NULL }, { null_marker = "\\N" }) .. "\n",
		{ null_marker = "\\N" }
	)[1],
	{ "a,b", 'q"q', "li\nnha", neogrip.NULL }
)

support.describe("codec/json: false is a value, not a missing field")
local falsey = json.documents('[{"a":false,"b":0,"c":"","d":null}]')
check("columns", falsey.columns, { "a", "b", "c", "d" })
check("false stays false", falsey.rows[1][1], false)
check("zero stays zero", falsey.rows[1][2], 0)
check("the empty string stays", falsey.rows[1][3], "")
check("and only null is NULL", falsey.rows[1][4] == neogrip.NULL, true)

local falsey_set = json.result_sets('[{"flag":false}]')
check("the same in a result set", falsey_set[1].rows[1][1], false)
