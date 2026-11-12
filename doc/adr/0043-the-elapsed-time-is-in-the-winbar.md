# 0043. Transient result-window chrome lives in the winbar

- Date: 2026-11-09T14:47:10Z
- Status: Superseded by 0045

## Context

ADR-0042 gives the client the instant execution begins, which leaves the question of where a number that
changes ten times a second is drawn.

The elapsed time lives in the footer today, and the footer is a line of the result buffer. Writing to it
means flipping `modifiable`, rewriting a line, and repainting: `highlight.paint` clears its namespace
over the whole buffer, `state.spans` and `state.kinds` are keyed by absolute line number, and the footer
is marked at the last line. ADR-0040 calls that repaint whole-buffer by construction and records the
cost — a full render measured 23 ms at 200 rows, 1091 ms at 10 000 and 1983 ms at 20 000. Paying any
fraction of that per tick, on the buffer the reader is scrolling, is not a tradeoff worth examining.

The plugin has no window chrome of any kind today. The one precedent for a dynamic window option is the
row-number gutter, a `'statuscolumn'` set to `%!v:lua.require'neogrip.grid'.row_label()`.

## Decision

The result window carries a window-local `'winbar'`, and it is a plain string reassigned whenever
anything in it changes.

1. **A string, not a `%!` expression.** Copying the `'statuscolumn'` idiom looks natural and has two
   unverified mechanics underneath it. `g:statusline_winid` is documented for `'statusline'` and
   `'winbar'` only says to see `'statusline'` for the format; `row_label` survives the ambiguity because
   it falls back to the current buffer, which for an unfocused result window would be the wrong one. And
   an expression has to be told to re-evaluate: `:redrawstatus` reaches only the current window, which
   the result window usually is not, while `:redrawstatus!` would make every other plugin's statusline
   re-evaluate ten times a second. Assigning the option already marks the window for redraw, so a
   literal string has no redraw call to get right and no window-identity question to answer.

2. **`winbar_text(bufnr)` is pure.** It takes a buffer and returns a string, so the unit suite asserts
   it with no window at all, which is how `row_number_for` is already tested. Every `%` it interpolates
   from a connection name or a statement is doubled, because the result is parsed as statusline format.

3. **Set with `scope = "local"`.** `'winbar'` is global-local; a global value would draw a bar on every
   window in the editor.

4. **One repeating timer for the module, not one per tab.** It is armed when the number of results in
   `executing` goes from zero to one and **stopped and closed** when it returns to zero, and also on
   `BufDelete`, on close, and on `VimLeavePre`. Two existing timers are the reason this is spelled out:
   the grid's autoload debounce is stopped but never closed, and the runner's watchdog is never stopped
   at all and survives as a no-op for `timeout_ms + 10000` after every request. Neither is a precedent
   to copy.

5. **A word before the execution begins, a number after.** Until `progress` arrives the winbar names the
   phase the client itself knows — `connecting`, `queued`, `sent` — and shows no number. This is what
   makes "the elapsed time is the execution time" exact rather than approximately true: there is no
   moment at which a number on screen is counting a queue wait or a driver download. Once `executing`
   lands the text becomes `%d ms`, the same unit and format the footer uses, so the running number and
   the final one read alike.

### Why not the message area, and why not virtual text

The message area was rejected because the number has to persist and be glanceable, and a notification
that repeats ten times a second would bury everything else the plugin says. Virtual text was rejected
because it is an extmark in the buffer: it needs a line to attach to, which a pending result does not
have, and it puts the clock back inside the namespace whose whole-buffer clear is the thing being
avoided.

## Consequences

- The result window loses one line of text height to the bar. Whether `nvim_win_set_height` is given
  text height or total height decides whether the split's height constant has to grow by one.
- Four highlight groups join the twenty already documented: the tab strip's normal, active, running and
  error faces. They follow the existing convention of `default = true` and resolved rather than linked
  colours, so a user's own `nvim_set_hl` wins.
- The running number cannot be asserted against the footer's, per ADR-0042. The unit suite asserts the
  shape — a word before, a `%d ms` after — and the manual checklist is what confirms it actually moves,
  since a timer-driven redraw is invisible to a headless run.
- A redraw ten times a second costs one option assignment on one window while a query is in flight. No
  buffer write, no `modifiable` flip, no extmark, no `render`.
