# A schema explorer, in about a hundred lines

The plugin does not ship an explorer (ADR-0037). It answers the catalog as data
— six levels, labelled per engine — and you draw it however you like.

This file is a worked example, not code the plugin loads. Paste it into your
config, change what you disagree with, throw away the rest. Everything it uses
is documented under `:help neogrip-tree`.

## What the tree gives you

```lua
local tree = require("neogrip.catalog.tree")

tree.shape(connection)        --> the walk this connection has, with labels
tree.children(node, opts, cb) --> the next level; nil node = your connections
tree.qualified_name(ref)      --> the name as SQL, quoted for this engine
tree.statement(ref, kind, cb) --> select | insert | update | delete, as text
tree.counts(ref, cb)          --> approximate row counts for a namespace
tree.sweep(ref, opts, cb)     --> sweep the instance, or one namespace of it
```

A node is `{ id, level, kind, name, ref, expandable, source, facts }`. Nothing
in it is formatted for a human: `facts.columns` is a number, not `"12
columns"`, and no icon is chosen for you. `kind` for a set is `table`, `view`
or `collection` and nothing else, so a switch over three values is a complete
renderer.

## The recipe: a tree in a scratch buffer

Expand with `<CR>`, open a SELECT with `s`, copy the qualified name with `y`.

```lua
local tree = require("neogrip.catalog.tree")
local icons = require("neogrip.ui.icons") -- or your own, or none

local state = { lines = {}, nodes = {}, open = {}, bufnr = nil }

local KIND_ICON = {
  table = icons.table,
  view = icons.branch,
  collection = icons.table,
  column = " ",
  field = " ",
  row = " ",
  document = " ",
}

--- One line per visible node, indented by depth.
local function label(node, depth)
  local marker = node.expandable and (state.open[node.id] and "▾ " or "▸ ") or "  "
  local decoration = KIND_ICON[node.kind] or "•"
  local suffix = ""
  if node.facts.columns then
    suffix = (" (%d)"):format(node.facts.columns)
  elseif node.facts.type then
    suffix = (" %s"):format(node.facts.type)
  end
  return ("%s%s%s %s%s"):format(("  "):rep(depth), marker, decoration, node.name, suffix)
end

local function redraw()
  vim.bo[state.bufnr].modifiable = true
  vim.api.nvim_buf_set_lines(state.bufnr, 0, -1, false, state.lines)
  vim.bo[state.bufnr].modifiable = false
end

--- Append a level under `parent`, then draw.
local function insert_children(parent, depth, at)
  tree.children(parent, {}, function(nodes, err)
    if err then
      -- An error is a node too: a namespace you cannot read should say so,
      -- not vanish.
      table.insert(state.lines, at, ("%s!! %s"):format(("  "):rep(depth), tostring(err.message or err)))
      return redraw()
    end
    for offset, node in ipairs(nodes) do
      table.insert(state.lines, at + offset - 1, label(node, depth))
      table.insert(state.nodes, at + offset - 1, { node = node, depth = depth })
    end
    redraw()
  end)
end

local function toggle()
  local row = vim.api.nvim_win_get_cursor(0)[1]
  local entry = state.nodes[row]
  if not entry or not entry.node.expandable then
    return
  end
  if state.open[entry.node.id] then
    -- Collapsing: drop every deeper line below this one. For rows, cancel the
    -- handle instead - that closes the cursor on the server.
    state.open[entry.node.id] = nil
    local cut = row + 1
    while state.nodes[cut] and state.nodes[cut].depth > entry.depth do
      table.remove(state.lines, cut)
      table.remove(state.nodes, cut)
    end
    state.lines[row] = label(entry.node, entry.depth)
    return redraw()
  end
  state.open[entry.node.id] = true
  state.lines[row] = label(entry.node, entry.depth)
  insert_children(entry.node, entry.depth + 1, row + 1)
end

local function open_select()
  local entry = state.nodes[vim.api.nvim_win_get_cursor(0)[1]]
  if not entry or entry.node.level ~= "set" then
    return
  end
  tree.statement(entry.node.ref, "select", function(text, err)
    if err then
      return vim.notify(tostring(err), vim.log.levels.WARN)
    end
    local connection = require("neogrip.connections").get(entry.node.ref.server)
    require("neogrip.ui.buffer").new_query(connection, text)
  end)
end

local function yank_name()
  local entry = state.nodes[vim.api.nvim_win_get_cursor(0)[1]]
  local name = entry and tree.qualified_name(entry.node.ref)
  if name then
    vim.fn.setreg('"', name)
    vim.notify(name)
  end
end

function OpenNeogripTree()
  state = { lines = {}, nodes = {}, open = {}, bufnr = vim.api.nvim_create_buf(false, true) }
  vim.bo[state.bufnr].filetype = "neogrip.catalog.tree"
  vim.api.nvim_set_current_buf(state.bufnr)
  vim.keymap.set("n", "<CR>", toggle, { buffer = state.bufnr })
  vim.keymap.set("n", "s", open_select, { buffer = state.bufnr })
  vim.keymap.set("n", "y", yank_name, { buffer = state.bufnr })
  insert_children(nil, 0, 1)
end

vim.api.nvim_create_user_command("MyDbTree", OpenNeogripTree, {})
```

## Variations

**A fuzzy finder instead of a tree.** Sweep once and use `tree.find`, which
answers flat:

```lua
tree.sweep({ server = id }, {}, function()
  tree.find({ server = id }, "", function(nodes)
    vim.ui.select(nodes, {
      format_item = function(node)
        return tree.qualified_name(node.ref) or node.name
      end,
    }, function(choice) ... end)
  end)
end)
```

**Row counts, late.** The tree never waits for them. Ask per namespace after
the sets are drawn, and fill the lines in as they arrive:

```lua
tree.counts(namespace_ref, function(counts)
  for name, estimate in pairs(counts or {}) do ... end
end)
```
Engines that keep no cheap estimate — SQLite, DuckDB, Trino, MongoDB — answer
nothing rather than counting rows, so show no number there.

**Walking into a database.** `shape()` marks the `instance` level with
`reconnects = true` where using another database means opening a new connection
to it — PostgreSQL and SQL Server cannot select across databases. The plugin
does not do that for you; register a connection with that `database` and walk
from its server node:

```lua
for _, entry in ipairs(tree.shape(connection).levels) do
  if entry.level == "instance" and entry.reconnects then
    -- picking a child here means re-registering the connection with
    -- database = node.name, then expanding the new server node
  end
end
```
Trino leaves the flag off: one session queries across catalogs, so picking one
only changes the names `tree.qualified_name` writes — it returns all three parts
there, and nothing has to be reopened.

**A level too long to draw at once.** Pass `limit` and a tree asks the server
for one page of that level instead of the whole cached schema. The page says
whether there is more, and what is left in it is exactly the opts of the next
call:

```lua
local function page(node, after, acc)
  tree.children(node, {
    limit = 200,
    after = after,
    on_page = function(continuation) node._page = continuation end,
  }, function(nodes)
    vim.list_extend(acc, nodes)
    if not node._page.done then
      return page(node, node._page.after, acc)
    end
    draw(acc)
  end)
end
```
This works the same on instances, namespaces and sets, and the rows above are
the same shape with `hash` and `from` in place of `after`. Without `limit` the
answer comes from the catalog cache in one round trip and the server caps it
silently, which is the right trade for an ordinary schema — page when the
catalog is big enough that a missing set would matter.

**Rows under a table.** Rows are data: they cost a query and are never cached,
so they are behind a flag.

```lua
local handle = tree.children(set_node, {
  objects = true,
  limit = 50,
  on_page = function(page) next_page = page end,
}, function(rows) ... end)
-- Collapsing the node:
handle.cancel()
```
Continue with `{ objects = true, hash = next_page.hash, from = next_page.from }`.
Nothing closes an open result on your behalf, so a tree that expands tables and
never collapses them holds an open statement for each until gripd's idle sweep
reaches it — an hour by default.

**Refresh.** Nothing watches the database. After a migration, call
`tree.sweep(namespace_ref, ...)` to re-read one schema, or `tree.forget(ref)`
to drop what is cached and ask the server again.

**A definition buffer.** `require("neogrip.catalog.ddl").details(connection,
namespace, set, details)` gives the lines the plugin used to draw, and
`:edit db://table/<conn>/<catalog>/<schema>/<table>` opens one by name.
