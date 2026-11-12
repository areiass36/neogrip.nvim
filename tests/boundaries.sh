#!/usr/bin/env bash
# The dependency directions ADR-0032, ADR-0035 and ADR-0046 decided, checked instead of hoped for.
# A determined import or require still compiles; this is the guard that says so out loud.
set -uo pipefail

cd "$(dirname "$0")/.." || exit 1

status=0

fail() {
	status=1
	printf '!! %s\n' "$1"
	printf '   %s\n' "$2"
}

ok() {
	printf 'ok %s\n' "$1"
}

# ADR-0032: the libraries have no way to name this application.
hits=$(grep -rl 'import neogrip\.gripd\.' java/lib 2>/dev/null)
if [ -n "$hits" ]; then
	fail "java/lib names the program (ADR-0032)" "$hits"
else
	ok "java/lib names no part of gripd"
fi

# ADR-0035: the domain needs nothing open - no JDBC, no library of ours.
hits=$(grep -rlE 'import (neogrip\.(jsonrpc|dataformat|inject)|java\.sql)' java/app/neogrip/gripd/domain 2>/dev/null)
if [ -n "$hits" ]; then
	fail "gripd/domain imports java.sql or a library (ADR-0035)" "$hits"
else
	ok "gripd/domain imports neither java.sql nor a library"
fi

# ADR-0046 rule 1: the entry point is required by nobody.
hits=$(grep -rn 'require("neogrip")' lua 2>/dev/null)
if [ -n "$hits" ]; then
	fail "a module requires the entry point (ADR-0046)" "$hits"
else
	ok "no module requires the entry point"
fi

# ADR-0046 rule 2: sql/ is pure text and codec/ is pure data.
for leaf in sql codec; do
	hits=$(grep -rhoE "require\(\"neogrip\.[a-z._]+\"\)" "lua/neogrip/$leaf" 2>/dev/null |
		grep -v "require(\"neogrip\.$leaf\." | sort -u)
	if [ -n "$hits" ]; then
		fail "lua/neogrip/$leaf reaches outside itself (ADR-0046)" "$hits"
	else
		ok "lua/neogrip/$leaf requires nothing outside itself"
	fi
done

# ADR-0046 rule 3: nothing inward names the editor surfaces or the use cases.
OUTER='neogrip\.(grid|ui|lsp|execute|diagnostics|commands|doctor)\b'
for ring in sql codec gripd connections catalog; do
	hits=$(grep -rnE "require\(\"$OUTER" "lua/neogrip/$ring" 2>/dev/null)
	if [ -n "$hits" ]; then
		fail "lua/neogrip/$ring points outward (ADR-0046)" "$hits"
	else
		ok "lua/neogrip/$ring points at no outer module"
	fi
done

exit $status
