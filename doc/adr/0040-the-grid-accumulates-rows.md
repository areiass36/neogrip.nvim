# 0040. The grid accumulates rows and loads the next batch as the cursor nears the end

- Date: 2026-11-04T19:40:00Z
- Status: Accepted

## Context

ADR-0031 made a result a cursor the client continues, and took `offset` off the wire: forward paging is
the cursor, and "the rows already shown stay in the grid's own state, so going back a page is a redraw,
not a request". The page was never a server concept after that record — it is an artefact of how the
client *shows* the batches it was handed.

The client still showed them one at a time. `grid.goto_page` swapped `state.rows` for the new batch and
reset `state.row` to 1, then moved the window cursor to the first line of it. So reading a long result
cost a key press and a re-orientation every `limit` rows, and the two things a reader actually wants —
keep going, and stay where I am — were the two the grid would not do.

Three things about the existing code bear on what is possible here.

`layout.compute` derives each column's width from the header plus up to `width_sample` (1000) rows. A
wider value in a later batch therefore widens the column and shifts every byte span on every line already
drawn. That is why there is no correct incremental painter: the honest version of "append the new lines"
is "append them, and when a width moved, rewrite everything", which is the full rewrite plus a second
path that fires unpredictably.

`highlight.paint` opens by clearing its namespace over the whole buffer, the footer is marked at the last
line, and `state.spans`/`state.kinds` are keyed by absolute line number. The repaint is whole-buffer by
construction.

And `execute.page` had no re-entrancy guard, because nothing could call it faster than a key press.
`in_flight` is read only by `M.cancel`, and `result.done` is only updated when an answer lands, so a
trigger that fires on cursor motion would queue one continuation per motion.

## Decision

The grid accumulates rows, and the next batch is fetched when the cursor comes within `auto_load_rows`
rows of the last one loaded.

1. **`state.rows` holds every row loaded.** `state.pages` and `state.page` are replaced by
   `state.batches`, which records where each batch began and ended rather than copying the rows into a
   second list. Two views of the same rows is a correctness hazard, not just duplication: a reader has to
   know which list is authoritative, and `tests/live_requery.lua` mutates a row in place. There is no
   current page.

2. **The buffer is rewritten whole on every batch, with the work memoised on the width vector.** The
   per-row render is the only place the cost lives, so `render` caches the lines, spans and kinds it
   produced and reuses them for rows it has already drawn whenever the computed widths are unchanged; when
   any width moves, it rebuilds everything. `highlight.paint` takes a starting line so a batch repaints
   only what it added. One code path, and the stripe parity stays correct for free because rows accumulate
   and therefore never shift — which is a property of this decision, not a coincidence.

3. **The trigger is the grid's existing `CursorMoved`, debounced 120 ms.** A second autocommand would have
   to re-create the augroup, which is created with `clear = true` and would delete the cell-sync
   autocommand that is already on it. The threshold is clamped below `limit`: a threshold as large as the
   batch re-arms the instant a batch lands, so `auto_load_rows = 500` against `limit = 200` would walk the
   whole table; clamped, the worst case is exactly one batch of lookahead. Zero turns it off.

4. **Two guards live on the state and die with the result they describe**: one for a continuation in
   flight, one latch for "nothing more will be asked". The latch closes on a finished result, on an
   unnamed one, on an expired one, and on a batch that comes back empty while claiming there is more —
   the last of which cannot happen today and would otherwise be an infinite request loop.

5. **An expired cursor is reported, never recovered.** A continuation whose hash is gone answers
   `-32600`; the grid keeps the rows it has, says so once, and latches off. This is matched on the code
   rather than the message, because the message is a Java string literal and three words away sits
   `"a result is already open under"`, which is the opposite condition; `doc/protocol.md` pins the code as
   the contract and nothing on either side pins the text.

   Recovery was examined and rejected. There is no `offset` on the wire and the statement text is never
   rewritten (ADR-0031), so "skip the rows already shown" is not expressible as a request. The two
   available shapes were re-run and discard, which loses the cursor position and so throws away the entire
   point of the feature, and re-run and drain forward in the client, which makes the server re-produce and
   re-transfer every row already on screen — at ten thousand accumulated rows that is fifty round trips of
   discarded rows and a refill every thousand — and then splices two snapshots of a changing table across
   an unbounded gap.

6. **`page_next` loads and jumps to the new batch; `page_prev` jumps back a batch.** Both keep working,
   and `grid.goto_page(bufnr, index)` keeps its name and signature and becomes a cursor jump. Removing
   either would be a change to the public Lua API, and a batch is a defensible unit to jump by: it is what
   the server actually handed over.

7. **No wire change and no protocol bump.** Everything ADR-0031 decided about the transport is intact.

## Consequences

- `state.page` and `page_offset` are gone, and `state.pages` becomes `state.batches` with a different
  shape. `grid.state()` is reachable from a user's config, so this is recorded rather than silent.
- ADR-0031's consequence that "turning a page stops touching the server for five pages, and going back
  never touches it at all" is still true of the mechanism but no longer describes the interaction. That
  record is extended, not superseded: nothing it decided about the cursor changes.
- The grid holds every row it loaded twice, once as values and once as rendered lines. `auto_load_max_rows`
  is the only bound; past it the automatic path stops and the footer says so, while `page_next` still
  works. Without that cap the feature has an unbounded failure mode.
- "This page" in the export picker and in `:NGripKeep` becomes "the loaded rows". `export.page_to_csv` and
  `page_to_json` keep their now-inaccurate names because they are public API; renaming them with aliases
  is left for its own change, and is named here so it is not forgotten.
- An expired result is a dead end until the user runs the statement again. That is the cost ADR-0041 pays
  down by widening the idle window.
- `:NGripCancel` does not stop an automatic continuation. Its `in_flight` table is keyed by the query
  buffer and cancelling a continuation sends `cancel {hash}`, which destroys the cursor — so cancelling
  something the user did not ask for would cost them the result. The manual path is unchanged.
- The Mongo `documents` gap is left open: `result.documents` never arrives from the runner today, so
  `show_document` already answers "no document behind this row" for every document result, and
  accumulation makes that no different. `add_page` keeps the indices absolute so the day documents do
  arrive, accumulation is already correct.
- `actions.last_row` moves the window cursor and so fires the trigger, which means `G` walks to the end of
  a result one batch at a time. That falls out of the design rather than being wired, and is worth a test.
