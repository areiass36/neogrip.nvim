# 0037. The plugin does not define an explorer

- Date: 2026-11-03T20:25:10Z
- Status: Accepted

## Context

ADR-0017 decided the plugin defines no keymaps: every action is a documented Lua function or command, and
the README carries a recipe. The explorer was the one place that decision stopped short. It shipped a
picker - `vim.ui.select`, a telescope finder, a previewer, hint columns padded to forty characters, and
`<C-y>`/`<C-s>`/`<C-o>` described in its comments - so the plugin was choosing how a schema looks, which
is the editor user's choice to make and not an author's.

ADR-0036 turned the navigation model into data, which leaves nothing the built-in explorer does that a
client cannot. Keeping it would mean two paths to the same information in one repository, and the one with
the UI attached would be the one that drifts.

Alternatives considered: rewriting the explorer on top of the new API and keeping it opt-in (rejected by
the author - the point is that the plugin should not have one, and an opt-in UI is still a UI the plugin
maintains); demoting it to an example loaded from `doc/` as live code (rejected: an example that runs is a
feature with a different name).

## Decision

- `lua/neogrip/explorer/` is removed, and with it `:NGripExplore`.
- What the plugin offers in its place is `lua/neogrip/tree.lua` - the navigation model of ADR-0036 - plus
  the text tools that were buried in the explorer's actions: `qualified_name(ref)`, `statement(ref, kind)`
  for select/insert/update/delete, `details(ref)` and `ddl(ref)`. They produce strings and records; they
  open nothing.
- `doc/explorer-recipe.md` carries a worked example of about a hundred lines, in the same spirit as the
  keymap recipe of ADR-0017: it runs if pasted, and it is documentation rather than code the plugin ships.
- One renderer survives as an optional helper, `lua/neogrip/render.lua`: the detail formatter that was
  `explorer/detail.render`. It is already used outside the explorer by `document.lua` and by the LSP
  hover, so it was never explorer UI in the first place.
- `lua/neogrip/icons.lua` stays as a table a client may read or override, and nothing in the plugin's own
  path uses it.

## Consequences

- A user who types `:NGripExplore` today loses it. The recipe is the migration, and it is the only one
  offered.
- The plugin's public surface becomes smaller and much easier to keep honest: a function returning records
  cannot drift from a UI it no longer has.
- Four test suites go - `unit_explorer`, `unit_detail`, `unit_preview`, `live_explorer` - replaced by
  `unit_tree` and `live_tree`, which test the model rather than a picker.
- `commands.lua`, `document.lua`, `doc/neogrip.txt` and `README.md` all change in the same commit, because
  the command list and the recipe are part of the contract with the user.
- The plugin can no longer be judged by how its explorer looks, which cuts both ways: nothing to criticise,
  and nothing to show. The recipe is what has to carry the first impression.
