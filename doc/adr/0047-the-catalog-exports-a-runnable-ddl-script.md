# 0047. The catalog exports a runnable DDL script

- Date: 2026-11-12T14:39:04Z
- Status: Accepted

## Context

The catalog can already describe one set at a time: a document buffer renders a definition from the
JDBC metadata (`catalog/ddl`), and the engine's own text is appended where one cheap statement
produces it (`catalog/nativeDdl`). What it cannot do is hand over a whole namespace as one file — the
thing a user reaches for before a migration, a review, or a scratch copy of a schema. Assembling that
file by opening one document buffer per table and yanking is the workaround in use today, and it
loses the one property that makes such a file worth having: that it runs, top to bottom, against an
empty schema.

Everything the file needs already travels the protocol. `catalog/tables` lists a namespace ordered by
name and paged by keyset (ADR-0038), `catalog/details` carries the columns, keys and indexes of one
set, and `catalog/nativeDdl` carries the server's own text where the engine has one. No protocol
change is required; the question is only how the client composes those answers into a script.

Three constraints shape that composition. First, the document-buffer rule extends naturally: every
non-comment line is runnable SQL, and what cannot be spelled is said in a comment, never guessed.
Second, a script is only runnable if a table is created after the tables it references, so the file
must be ordered by the foreign-key graph, not by name alone. Third, the catalog's two caches — the
swept store and the per-question TTL cache — answer at the moment they were filled; a file handed to
a migration must answer for the server as it is now, and producing it must not overwrite what the
explorer is showing.

## Decision

A new public function, `require("neogrip.catalog.export").script(target, opts, callback)`, writes the
DDL of everything under `target` to `opts.path` and reports `{ tables, views, collections, skipped }`.
It returns a handle whose `cancel()` stops the enumeration between requests; the callback fires
exactly once in every path, a cancel included. With no callback, the notifier reports the counts.

1. **The target is a tree node id or a ref.** `tree.ref_of(id)` is added as the inverse of
   `tree.id(ref)`, resolved against the named connection's shape — the id alone cannot say which
   level a segment fills. An id whose first segment names no configured connection is refused. An
   `object` or `attribute` id is refused: neither has a definition. A `server` id is refused when the
   shape's next level reconnects (`shape.reconnects`): walking instances would mean reopening the
   connection per instance, and the export never changes what the user is connected to. Where the
   shape goes straight down — a file database, a connection pinned to its database, Trino's
   in-session catalogs — the deeper levels are enumerated with the same paged listings the tree uses.

2. **Every answer comes from the server, and the caches are left untouched.** The export calls
   `gripd.request` directly: it never reads the swept store or the TTL cache, and never writes
   either. The price is one `catalog/details` (and, where the engine has one, one `catalog/nativeDdl`)
   per set, sequentially — which is also what makes `cancel()` meaningful between requests.

3. **Composition follows the engine's native shape.** Where the engine hands back a complete
   `CREATE TABLE` — MySQL, MariaDB, Trino, SQLite — the native text is the statement, verbatim, and
   the rendered definition is not repeated next to it; SQLite's text carries the table alone — an
   index is its own row of `sqlite_master` — so its index statements are still rendered after it. Where the engine hands back fragments —
   PostgreSQL's `ALTER TABLE ... ADD CONSTRAINT` and `CREATE INDEX` — the rendered `CREATE TABLE`
   carries the columns alone and the native fragments carry every constraint, so a CHECK constraint
   appears once and nothing is declared twice. Where the engine hands back nothing — MSSQL, DuckDB —
   the rendered definition stands alone, keys inline, indexes as statements, and the file says that
   CHECK constraints are not reported. A view is the engine's own text where there is one and a
   comment where there is not; a collection is always a comment, because what the catalog reports
   for one is a sample, not a schema (ADR-0038). `COMMENT ON` is not emitted: it is not every
   engine's syntax, and a statement that fails on replay has no place in this file.

4. **Tables are ordered dependencies-first.** Among the tables whose exported dependencies are
   already written, the lexicographically smallest name goes next, so the order is total and two
   exports of one unchanged schema are byte-identical. A self-reference is not a dependency. A cycle
   is broken at the smallest remaining name and the file names both ends in a comment. A foreign key
   pointing outside the exported set is kept — removing it would silently change the schema — and
   noted in a comment. Views follow the tables, ordered by name.

5. **The file is deterministic and written atomically.** No timestamp, no environment, the same
   target twice gives the same bytes — which is what makes two exports diffable. The script is
   written to a temporary name and renamed into place, the rule ADR-0010 set for bulk data. A set
   that vanishes between the listing and its details is skipped with a comment naming it; an empty
   namespace produces the header and a comment, never an empty file. Any server message quoted into
   a comment passes through the redaction in `gripd/dsn.lua` first.

## Consequences

- The export is slower than a sweep: one round trip per set, sequential. Accepted — correctness of
  the moment beats speed here, and the sweep's file was never runnable SQL.
- The composition table in the module must agree with `NativeDdl.java`'s shape table; an engine added
  to one side without the other degrades to a rendered-only export, which is still runnable.
- Replayed against an empty schema, the file reproduces what the catalog reports — not what the
  server privately knows. On the engines where JDBC is the only source (MSSQL, DuckDB), a CHECK
  constraint is lost and the file says so.
- The suites gain an export suite that stubs `gripd.request` and asserts the caches untouched, and a
  live suite that replays the script against a scratch schema and compares the re-export.
