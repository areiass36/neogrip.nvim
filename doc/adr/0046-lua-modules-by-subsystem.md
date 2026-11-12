# 0046. The Lua tree is grouped by subsystem, with one dependency direction

- Date: 2026-11-12T12:49:54Z
- Status: Accepted

## Context

ADR-0032 and ADR-0035 gave the Java side two source roots, rings named after what they are and one
direction of dependency, checked by grep. The Lua side never had an equivalent record. It grew by
adding a file next to the last one, and the six directories it does have - `bootstrap`, `codec`,
`grid`, `rpc`, `schema`, `sql` - were each created when a second file needed a home, not from a rule.

Measured on the tree this record replaces - 44 files, 10,556 lines - 24 files sit directly under
`lua/neogrip/`, and they are not one kind of thing: the entry point, the options table, two use cases,
four adapters (`gripd`, `connections`, `resolve`, `secrets`), five editor surfaces (`buffer`,
`document`, `statusline`, `icons`, `commands`), four language services (`lsp`, `completion`,
`diagnostics`, `dialect`) and two catalog presenters (`tree`, `render`). A reader opening the
directory cannot tell which of those a name is.

Underneath the flatness are three wrong arrows:

- **The entry point is the plugin's utility hub.** 27 modules `require("neogrip")` to reach `notify`,
  `NULL`, `state_dir` or `data_dir`, while `init.lua`'s `setup` requires twelve subsystems. So
  `codec/json.lua` and `value.lua`, which touch no editor API and no process, depend transitively on
  the whole plugin. This is the shape ADR-0032 removed from Java, where `db/Database.java` imported
  `neogrip.app.Session`.
- **`execute` and `grid` form a cycle.** `execute.lua` requires `grid` at the top of the file and
  drives it through eleven calls; `grid/init.lua` and `grid/actions.lua` require `execute` from inside
  three functions, with a comment at the first of them naming the cycle it exists to avoid.
- **`sql/` is not SQL text.** `split.lua` holds the lexer of ADR-0015 and, in the same module, reads
  buffer lines, the cursor and the visual marks (eight `vim.api` calls); `identifier.lua` requires the
  catalog and the buffer-to-connection resolution; `statement.lua` requires the catalog. `codec/*`
  fails the same test only because it reaches the entry point for `NULL`.

Two smaller ones: `connections/resolve.lua` attaches the dialect layer and starts the LSP client -
editor work in the module that answers which connection a buffer runs against, duplicating the same
`pcall` dance that `buffer.lua` already does - and `errors.lua`, whose job is translating a driver
error, reads buffer lines in four places to decide where to underline.

Two names are wrong rather than misplaced. `grid/init.lua` is 1,099 lines and 45 functions over six
responsibilities - the state registry, the status and winbar text, the elapsed-time ticker, the
rendering, the cursor and auto-load, and the tab lifecycle with paging - and it is the largest file in
the repository, Lua or Java. And the catalog is called `schema` only on this side: the wire says
`Catalog` (`doc/protocol.md`), the Java packages say `catalog`, and `schema` is also a level of the
tree (ADR-0036), so the directory name collides with a value inside the model it holds.

Alternatives considered:

- Directories named after the ring (`domain/`, `adapter/`, `ui/` as layers): rejected for the reason
  ADR-0032 gave for packages named `lib.*` and `app.*` - a name that states the layer says nothing
  about what the thing is - and in Lua it is worse, because the directory is the module name and the
  ring would be spelled in all 293 `require` calls.
- A `lua/neogrip/lib/` mirroring `java/lib`: rejected for the same reason. Lua has one runtime path
  root; the source-root trick of ADR-0032 has no equivalent that does not end up in every caller.
- A `util.lua` to absorb what the entry point exports: rejected. That is the same grab bag under
  another name, and it would still be required by 27 modules for four unrelated reasons.
- Re-export shims at the old paths: rejected. A file whose only content is a name is what this
  repository's comment rule already refuses in prose form.
- Keeping the documented paths at the root and reorganising only the rest: rejected. The root would
  keep 14 files and no rule, which is the problem.

## Decision

The root holds only what is plugin-wide or public, and nothing that belongs to a subsystem:
`init.lua` (setup, ADR-0018), `commands.lua` (ADR-0024), `config.lua`, `execute.lua`,
`diagnostics.lua`, `doctor.lua`, `health.lua` (the path `:checkhealth` requires), `notify.lua` and
`paths.lua`.

Everything else lives in one of eight directories, each named for what it is and never for a ring:

- `sql/` - the lexer and the statement classification. Pure text.
- `codec/` - CSV, JSON and the value model, which owns the `NULL` sentinel. Pure data.
- `gripd/` - the daemon and the wire: the process, the protocol constants, the JSON-RPC client, the
  JDBC URL and its redaction, the error translation, the request queue, and `bootstrap/` for the
  pinned JDK and driver jars.
- `connections/` - the connection file, which connection a buffer runs against, and the secrets.
- `catalog/` - the swept catalog, its store on disk, the tree of ADR-0036, the rendered definition and
  the statement text built from metadata. The directory is renamed from `schema` to the word the wire
  and the Java side already use.
- `lsp/` - the in-process server of ADR-0022, the completion source and the identifier resolution.
- `grid/` - the result window, decomposed by responsibility: the state registry, the rendering, the
  status line, the winbar strip, the tabs, the cursor and auto-load, plus the existing layout,
  highlighting, actions, export and requery. `init.lua` is the facade the rest of the plugin calls.
- `ui/` - the editor surfaces that are not the result window: the SQL buffer, the `neogrip://`
  document, the statement under the cursor or in the selection, the dialect syntax layer, the
  statusline component and the icons.

Three rules, checked by grep in CI the way ADR-0032's boundary is:

1. No module requires `neogrip`. The entry point is required by nobody.
2. No module under `sql/` or `codec/` requires anything outside its own directory.
3. No module under `sql/`, `codec/`, `gripd/`, `connections/` or `catalog/` requires `grid/`, `ui/`,
   `lsp/`, `execute`, `diagnostics`, `commands` or `doctor`.

To make those true rather than aspirational, four arrows are turned:

- `notify` and the two directories leave `init.lua` for `notify.lua` and `paths.lua`; `NULL` moves to
  `codec/value.lua`, beside the only logic that interprets it.
- The grid stops naming `execute`. A result carries a source - `load_more`, `page` and `sort` - which
  `execute` installs when it opens the tab, so the window asks its source for more rows instead of
  reaching back into the use case. One arrow, outward from the use case to the view, remains.
- `sql/split.lua` keeps the lexer; reading the buffer, the cursor and the visual marks becomes
  `ui/statement.lua`.
- `errors.locate` takes a function that returns a line instead of a buffer number, so the module that
  translates a driver error no longer reads the editor.
- `connections/resolve.lua` announces a binding with a `User NeogripConnectionBound` autocmd; `ui/`
  subscribes and attaches the dialect layer and the LSP client, which also removes the second copy of
  that `pcall` dance.

The public Lua API moves with the tree: `neogrip.tree`, `neogrip.render`, `neogrip.icons`,
`neogrip.statusline` and `neogrip.buffer` become `neogrip.catalog.tree`, `neogrip.catalog.ddl`,
`neogrip.ui.icons`, `neogrip.ui.statusline` and `neogrip.ui.buffer`. `require("neogrip")`,
`require("neogrip.gripd")`, `require("neogrip.connections")`, `require("neogrip.lsp")` and
`require("neogrip.grid.actions")` keep their spelling, because each of those is now a directory's
`init.lua`. The documented recipes in `README.md`, `doc/neogrip.txt` and `doc/explorer-recipe.md` are
updated in the same commit as the move, and no alias is left behind.

## Consequences

- The root listing becomes readable as a rule rather than a pile: nine files, each either a public
  surface or a fact about the whole plugin.
- The rules that CI checks are the ones that are true, as ADR-0035 required of the Java side. The one
  arrow that stays is `execute` to `grid`, and it is now one-way.
- `git blame` breaks across 53 files for the second time in three days, after the comment sweep. The
  moves are recorded with `git mv` so `--follow` still reaches through them.
- 293 `require` sites change, 161 in `lua/` and 132 in `tests/`, along with about sixty file paths
  quoted in `doc/internals.md` and the CI cache key that hashes `bootstrap/jdbc.lua`.
- The user's own configuration must be updated: five documented module paths change, and there are no
  aliases. The plugin has no tag and no release, so the author's configuration is the only consumer.
- `sql/` is left with two files. That is the honest size of what in this plugin is pure SQL text; the
  directory earns its place by being the thing rule 2 can be checked against.
- `grid/` grows from six files to twelve. The window is the plugin's largest surface and the only one
  with its own state machine, so the count is where the complexity actually is.
- A determined `require` still compiles, exactly as a determined `import` still does on the Java side.
  The grep in CI is the guard, and it is only as good as the step that runs it.
