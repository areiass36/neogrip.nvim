# 0045. The tab strip is the result window's winbar, and carries only the strip

- Date: 2026-11-10T14:40:00Z
- Status: Accepted

## Context

ADR-0043's winbar failed in use, twice over. It repeated the footer line a few rows above the footer —
the distance argument that justified saying it twice only holds in a result long enough to scroll, and
in a ten-line window the same line printed twice is noise. And its tab strip was unreadable: unspaced
numbers with a `▸` glued to the active one, labels too short to tell two queries apart.

The redesign is constrained by two requirements from use. The SQL and the result stay visible at the
same time, which rules out a native tabpage per query: a tabpage is a whole screen layout, and looking
at a result would take the SQL off the screen. And the strip belongs on the window that renders the
result: a bar at the top of the screen — the native `'tabline'`, or a buffer line fed by making result
buffers listed — was evaluated and rejected, because a global bar is far from the window it describes,
is always present once configured, and mixes result tabs with file buffers.

Of the surfaces a window owns natively, the statusline belongs to the user — statusline plugins own
it, and with a global statusline there is only one for the whole editor — which leaves `'winbar'`,
whose failure above was content, never location. The mechanics ADR-0043 got right are kept: a literal string assigned per window with
`scope = "local"`, never a `%!` expression, because assigning the option already marks the window for
redraw.

Removing the duplicated text from the winbar evicts the live clock, and ADR-0043's cost argument
against drawing it in the buffer still stands for a full render: ADR-0040 measured 23 ms at 200 rows
and ~2 s at 20 000, which cannot be paid ten times a second. But the clock only ever runs over two
shapes of buffer — a pending tab, whose body is empty, and a result whose refill is executing, where
only the footer line changes. Neither needs a render; both are a one-line write.

## Decision

The result window's `'winbar'` carries the tab strip — only the strip, nothing the footer says — and
the strip is dressed as the native tab bar.

1. **One cell per tab: its position and its statement, in the tabline's own faces.** Plain cells in
   `TabLine`, the one on screen in `TabLineSel` — always, as the native bar marks the current
   tabpage — and the rest of the bar in `TabLineFill`, so with any colourscheme the strip reads as
   Vim's tab bar and not as a widget of the plugin's own. A running or failed cell keeps the tabline
   background under a telling foreground. The five `NGripGridTab*` groups are links and derivations
   over those faces, `default = true`, so a user override wins. The cell label is the statement's
   text collapsed and truncated to 18 characters — tab-sized, like a file name in the native bar.

2. **The strip is always present while a tab exists, from the moment the first query is sent.** A
   strip of one still names what the window is showing, and a bar that comes and goes moves the rows
   under the reader. The duplication ADR-0043 died of cannot recur because the winbar never says
   anything the footer says.

3. **Buffer names carry the statement: `neogrip://<n>/<label>`.** The label is the statement
   collapsed to one line and truncated to 32 characters, with `/` and `\` replaced so the tail after
   the last separator is the whole label; the counter keeps the name unique (two runs of one
   statement are two tabs) and is never reused, as ADR-0044 already required. The strip and `:ls`
   therefore agree on what a tab is. The buffers stay unlisted: the strip is what names them, so the
   buffer list and the `:bnext` cycle gain nothing from holding them.

4. **The clock leaves the winbar.** A pending tab's body is a single status line — connection, phase,
   and the running time once the server says execution began (ADR-0042) — written in place of the
   empty body ADR-0044 prescribed. A refill over rows already drawn rewrites only the footer line,
   one `nvim_buf_set_lines` over one line and a line-scoped repaint of its marks per tick, so
   ADR-0040's measured render cost is untouched. The ten-times-a-second tick never touches the
   winbar; the strip is repainted only when it changes — a tab opened, closed, switched, failed, or
   beginning to execute.

   This amends ADR-0044's clause that a pending tab's body holds no lines. What that clause guarded
   against — a rendered header with no columns reading as "the query returned nothing" — is not
   revived by a line that says `running · 312 ms`. Following the partial-supersession precedent
   ADR-0041 set, ADR-0044 is not edited and its status stays `Accepted`.

5. **`status_text(bufnr)` and `strip_text(bufnr)` are pure**, taking a buffer and returning a string
   — for a finished result, `status_text` is byte-for-byte the footer line — so the suites assert
   both with no window at all, the way `row_number_for` is already asserted.

6. **A failed or cancelled tab** keeps the lifecycle ADR-0044 gave it; its body carries the
   translated error, the notification already posted carries the same message, and its cell in the
   strip is tinted. Everything else in ADR-0043 that was sound is restated here and kept: the
   server-side start of the clock, a word before `executing` and a number after, and one module-wide
   timer stopped and closed when the last clock stops.

## Consequences

- The result window loses one line of height to the bar whenever it is open.
- Labels in the strip are statusline format, so `%` coming from a statement is doubled before it is
  interpolated. Several 18-character cells can still overflow a narrow window; the winbar truncates
  on the right. Accepted: the alternative is labels too short to tell statements apart, which is
  what sank the numbers-only strip.
- The suites stop asserting the old statusline-format winbar string; they assert `status_text`, the
  strip through `strip_text`, and the status line written into a pending body. A timer-driven redraw
  that is actually seen moving is what a headless run cannot confirm, so the manual checklist keeps
  that part.
- A user who wants no strip clears `'winbar'` from a FileType autocommand on `neogrip-grid`; the
  help carries the recipe.
