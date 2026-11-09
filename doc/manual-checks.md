# Manual checks

What automation cannot cover. Run these by hand before a release, on each platform where they apply, and
record the date and result at the bottom.

## Downloads (per OS: macOS, Windows, Linux)

Automation covers the checksum logic against a local file; the real network path is manual.

1. Delete the plugin's data directory (`:echo stdpath("data")` + `/neogrip`).
2. Open a project with a DuckDB connection and run a statement.
3. Confirm the JDK download starts, the checksum passes, gripd compiles and the statement runs.
4. Repeat with a PostgreSQL connection to confirm a driver jar download.

## Secrets never reach a command line

1. Connect to a password-protected database.
2. Find gripd PID with `:NGripDoctor`.
3. Inspect the process command line (`ps -o command -p <pid>` on Unix,
   `Get-CimInstance Win32_Process -Filter "ProcessId=<pid>" | Select CommandLine` on Windows).
4. Confirm no password, user name or JDBC URL appears in it.

## Real kvstore integration

The test suite runs against a fake. Once per release, configure a real connection whose password lives in
kvstore.nvim and connect, confirming the key is read and a missing key produces the error message that
names `:KVStore <key>`.

## Windows child-process termination

1. On Windows, run a long statement and kill the Neovim process from Task Manager (no clean exit).
2. Confirm gripd java.exe disappears within a few seconds (stdin EOF path).

## Token authentication

1. Store a bearer token under a kvstore key and configure `auth.type = "token"` against a Trino or Azure
   SQL endpoint.
2. Confirm the connection opens and a statement runs.
3. Let the token expire and confirm the statement fails with the server's own error, and that storing a
   fresh value plus `:NGripDisconnect` recovers.

## Interactive authentication (when the Entra phase lands)

Entra ID interactive login opens a browser and cannot run in CI.

1. Connect to an Azure SQL database with `auth.type = "entra_interactive"`.
2. Confirm the status notifications appear, the browser opens, and the connection completes after MFA.
3. Confirm the documented limitation: the flow fails with a clear message in a headless session.

## Scrolling a result (every release, after any change under `grid`)

The grid loads the next batch when the cursor comes within `auto_load_rows` of the last row (ADR-0040),
and the trigger hangs off `CursorMoved`. **Neovim does not emit `CursorMoved` under `--headless -l`** -
measured: neither `nvim_win_set_cursor` nor `nvim_feedkeys` produces it there - so the suite fires the
event itself and proves everything except that the editor delivers it. That last link is this check, and
nothing automated can replace it.

1. Run a statement answering thousands of rows (`select generate_series(1, 5000) as n`).
2. Hold `j` from the first row. Confirm the rows keep coming with no key pressed for them, that the
   footer's count grows, and that the cursor is never thrown back to the top.
3. Keep going with `<C-d>` to the end. Confirm the footer stops saying `(more)`.
4. Watch the table while it loads: it must not shift sideways. The column widths are measured over the
   first `width_sample` rows and the row gutter has a four-digit floor, which is what keeps it still - a
   value wider than anything in the first thousand rows is the case that moves it.
5. Scroll a result on a connection where the statement is slow, and confirm the footer says
   `(more, loading...)` while a batch is on its way.
6. Set `auto_load_rows = 0` and confirm nothing loads by itself and `]p` still works.
7. Leave a result untouched for longer than `cursor_idle_seconds`, then scroll. Confirm the footer says
   `(expired)`, the rows already loaded are still there, and nothing was re-run.

## The explorer recipe (every release, after any change under `tree`)

The plugin defines no explorer (ADR-0037), so what used to be a feature to click through is now a
document to follow. Nothing automated can tell whether `doc/explorer-recipe.md` still describes the API
it is pasted next to: the suite drives `tree` directly and would stay green against a recipe that no
longer compiles.

1. In a scratch Neovim config, load the plugin and paste `doc/explorer-recipe.md`'s recipe into a
   `lua/` file. Confirm it loads with no error.
2. Walk a PostgreSQL connection from the server down to a column, one level at a time, and confirm every
   level answers and is labelled the way `tree.shape()` says.
3. Expand a table's rows, page once more, then collapse it. Confirm the rows arrive and that the second
   page continues the first.
4. Expand five tables' rows without collapsing any, and confirm all five still answer: nothing evicts an
   open result any more (ADR-0041).

   Steps 3 and 4 used to end by confirming with `:NGripDoctor` that no cursor was left open, which cannot
   be done: the doctor reports each connection's product and the round trip of one `select 1`, and no
   method on the wire says how many results gripd holds. That a collapsed listing hands its cursor back
   is covered by the live suites, which ask the server to continue a hash they released and expect
   `-32600`.
5. Ask for a long level with `limit` and walk it to the end. Confirm no set is missing or repeated, and
   that the last page reports `done`.
6. Re-introspect one namespace after an `alter table`, and confirm only that namespace changed: the other
   namespaces keep their swept timestamps and their columns.
7. Confirm no icon, no padding and no counted string appears in any node the recipe did not format
   itself.

## Result tabs and the running clock

A timer-driven redraw and a `'winbar'` that is actually drawn are exactly what a headless run cannot see:
the suites assert what the bar says, never that it moved or appeared.

1. Run a deliberately slow statement (`select pg_sleep(5)`, or a Trino aggregate over something large).
   Confirm the window appears immediately, before any answer, with the connection's name and a word rather
   than a number.
2. Confirm the number then appears and **moves**, roughly ten times a second, and that it starts near zero
   even if the connection had to be opened first — a first-use build of gripd can take tens of seconds and
   none of it belongs in that number.
3. Confirm the number it settles on is within a few milliseconds of the footer's. They are not expected to
   be equal, and either may be the larger (ADR-0042).
4. Scroll a result of more than 1001 rows to its end. Confirm the clock restarts at the refill and that the
   footer still counts the rows it holds while it does.
5. Run a selection of three statements. Confirm three tabs, one per statement, that the strip marks the one
   on screen, and that `]t` / `[t` move between them with the rows of each intact.
6. Run a statement with a syntax error. Confirm its tab stays, says why in the body, and that the bar marks
   it as failed rather than as a result with no rows.
7. Sort a column. Confirm no new tab appears and that the rows come back in the new order. Nothing on the
   client reports how many results the server holds, so the release of the replaced one is covered by
   `tests/unit_tabs.lua` instead; what is manual here is only that sorting reuses its tab.
8. Open twenty tabs against one connection, each with rows left unread so none of their results is
   finished, and watch the gripd process's memory (its PID is in `:NGripDoctor`). This is the cost
   ADR-0044 accepts: gripd runs with no explicit heap limit, and the failure at the far end reads as
   "gripd stopped answering; restarting it" with no mention of memory.
9. On a result read to its end, confirm whether the clock restarts on the last batch. On a driver that
   ignores `setMaxRows` — DuckDB does, and `Drivers.tolerate` swallows the refusal — the window never
   limits, so the cursor re-executes the whole statement once at the end to find out it is finished. The
   notice is honest (an execution really is running), but on a slow statement it reads as the clock
   restarting for no reason. Measured: 3999 rows came out of one execution with `maxRows` set to 1001.

## Results

| Date | Check | OS | Result |
| --- | --- | --- | --- |
