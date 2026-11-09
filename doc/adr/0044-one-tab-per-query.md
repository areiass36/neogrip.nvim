# 0044. The result window holds one tab per query

- Date: 2026-11-09T14:47:55Z
- Status: Accepted

## Context

The grid is a singleton. `M.buf` names the one result buffer, `grid.show` reuses it, and showing a
result overwrites the state of the one it held. So every query destroys its predecessor: a reader who
runs a second statement to check something cannot go back to the first, and the rows they were reading
are gone before the new ones arrive.

A SQL console answers this with tabs, one per query, which is what the user asked for. Neovim has no
such concept: a tabpage is a whole layout, not a tab inside a window. What produces the behaviour is one
buffer per result, all shown in one window, with a strip naming them — and ADR-0043 has just put a
winbar on that window, which is where the strip goes.

Two things about the current lifecycle bear on this. `grid.show` is reached only from inside the runner's
callback, so no window exists while a query runs. And `execute` releases the cursor of the result the
grid is about to replace, which `config.lua` documents as one of the only two automatic reclamations
left (ADR-0041 names four reclamation paths and requires this one to work).

## Decision

The result window holds an ordered list of tabs and an index of which is active. Switching tabs sets the
window's buffer; the window itself is created once and reused.

1. **A tab is opened when the request leaves, not when it answers.** This is what makes the window
   appear immediately, and it forces one thing: the client mints the result's name before calling the
   runner. The order is mint, open the tab, then run — not run and then open with the returned handle —
   because the callback can fire synchronously inside `runner.run` when the process is gone, and every
   suite that stubs the runner answers synchronously on purpose.

2. **A pending tab has no `GridState`.** Rendering one would draw a header with no columns, a rule and
   "no rows", which reads as "the query returned nothing" — a worse lie than an empty window. With no
   state, every action and both autocommand paths are already inert on a running tab, and the winbar is
   the whole message. The body holds no lines.

3. **A failed or cancelled query keeps its tab**, which says what happened. The window is
   already open by then, and making it vanish leaves the reader with nothing to look at and a renumbered
   strip. The error written into the buffer is the one the runner already translated, which is what keeps
   a secret out of it.

   A statement refused for being a write against a read-only connection gets no tab, because it is refused
   before any request leaves and there is nothing to show: that refusal stays a notification (ADR-0016).

4. **Buffer names carry a counter that is never reused.** A duplicate buffer name is an error, and a
   hidden tab the user has not deleted still holds its name.

5. **A new tab for a new query, the same tab for another view of it.** `:NGripRun`, `:NGripResults`,
   `:NGripCsv` and each statement of a multi-statement selection open one. Sorting a column reuses the
   tab it is sorting: it re-runs the statement and opens a new result on the server, but what the reader
   asked for is the same rows in another order, and a tab per sort click is noise.

6. **The grid releases the cursor it replaces, not `execute`.** Reusing a tab is the only case left
   where a result is replaced, and the grid is what knows it is happening. Moving the release into
   `set_result` keeps ADR-0041's four paths intact and keeps `config.lua`'s claim about the two automatic
   reclamations literally true. Deleting it instead would leak one open statement per sort for
   `cursorIdleSeconds`, which defaults to an hour.

7. **Navigation is three functions and no commands**: next, previous, and go to an index. They take no
   buffer, because which tab is active is a property of the grid rather than of a buffer. This follows
   `actions.close`, which has been a function with no command since ADR-0017, and the keymap recipe in
   the README is where keys are named.

8. **`M.buf` is removed rather than kept as an alias.** It is not documented — the help documents
   `neogrip.grid.actions` and never the grid module itself — and a writable pointer beside the list would
   be a second view of the truth, which is the hazard ADR-0040 rejected when it refused to keep rows in
   two lists.

9. **No cap on how many tabs.** See the consequences: this is a real cost, accepted deliberately.

### What this supersedes

ADR-0030 decided that a selection holding several statements runs them in sequence and that "only the
last one's rows are shown in the grid", with the earlier ones reporting their counts in a notification.
Each statement now gets its own tab, and the notification goes: a tab is strictly more informative than
a line of message text that scrolls away. Everything else in ADR-0030 stands — one statement per call,
in order, stopping at the first error.

ADR-0030's file is not edited and its status stays `Accepted`, following the precedent ADR-0041 set for a
partial supersession: the instructions require marking a superseded record and also forbid editing an
accepted one, which cannot both be honoured when only a clause is being replaced.

## Consequences

- Every live tab holds a cursor open on the server, so the release that used to happen on every new
  query now happens only on close and on sort. With no cap, `cursorIdleSeconds` becomes the only
  automatic bound, and the retained cost is N open statements plus N × ~1001 rows of driver buffer
  (ADR-0041), while on the editor side `auto_load_max_rows` becomes a per-tab limit over rows that
  ADR-0040 already holds twice. Gripd runs without an explicit heap limit, so the failure mode at the far
  end is an `OutOfMemoryError` the editor reports as "gripd stopped answering; restarting it", with no
  mention of memory. ADR-0041 already named passing `-Xmx` as the obvious follow-up; this record makes it
  more pressing and still does not decide it.
- The window opens before the plugin knows whether the statement produces a grid at all. An intercepted
  `BEGIN` answers that a transaction is open, an `UPDATE` answers a count, and an error answers nothing —
  all three now get a tab. That is inherent to showing the window before the answer and is written down
  here rather than discovered in use.
- Closing a pending tab cancels its request, so the tab list has to hold the handle. Dismissing a window
  the user is done with should not leave a statement running on the server.
- The bookkeeping that forgets a tab is reached twice for one close — directly, and again through
  `BufDelete` when the buffer is deleted — so it has to be idempotent.
- `:NGripResults`, `:NGripExport` and `:NGripKeep` act on the active tab. Addressing another one would
  mean an argument on each, which is a change to the command surface and is not made here; the tabs are
  navigable instead.
- The DuckDB requery counter and its `last` view stay global to the session. `r1`, `r2`, … and `last` is
  the documented semantics and stays coherent with any number of tabs.
