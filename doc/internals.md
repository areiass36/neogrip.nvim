# Internals

Measured facts, driver quirks and platform traps that justify non-obvious code. Decisions and their
trade-offs live in `doc/adr/`; this file holds the numbers and the recorded failures those decisions
and the code lean on. Each fact lives here exactly once, and the code points at it with a
`See doc/internals.md#<anchor>` comment instead of repeating it.

## grid

- A whole render measured 23 ms at 200 rows, 1091 ms at 10 000 and 1983 ms at 20 000; rendering only
  the rows a batch added holds a batch at 35-45 ms. This is why the reuse path exists in
  `lua/neogrip/grid/init.lua`, `render`.
- Rendering from an index instead of from the top: re-rendering everything measured 425 ms per batch
  at ten thousand rows with eight columns. `opts.from` in `lua/neogrip/grid/layout.lua`, `M.render`.
- The execution clock fires ten times a second and a full render measured about 2 s at 20 000 rows,
  so a tick rewrites only the footer line (`lua/neogrip/grid/init.lua`, `repaint_footer`) and repaints
  only that line (`lua/neogrip/grid/highlight.lua`, `paint_line`); `M.paint`'s buffer-wide clear is
  the cost the clock exists to avoid.
- A continuation batch's `elapsed_ms` must not overwrite the statement's: doing so turned "this
  statement took 1420 ms" into "3 ms" the moment the reader scrolled. `lua/neogrip/grid/init.lua`,
  `M.add_page`.
- `nvim_buf_delete` on an unlisted buffer fires `BufWipeout` and not `BufDelete` (BufDelete is about
  the buffer list), so a cleanup hooked to BufDelete alone never ran and the debounce timer was never
  stopped. Both events are subscribed in `lua/neogrip/grid/init.lua`, `attach_cursor_sync`.
- A second augroup created with the same name and `clear = true` silently deletes the first one's
  autocommands, so the grid's cursor-sync group is named per buffer.
  `lua/neogrip/grid/init.lua`, `attach_cursor_sync`.
- A gutter width taken from the row count re-widthed the whole gutter at row 100 and again at row
  1000 while the reader scrolled, so the width has a floor of four digits.
  `lua/neogrip/grid/init.lua`, `M.row_number_for`.
- The cursor-driven load is debounced at 120 ms so holding `j` asks once rather than once per line;
  the dialect module's repaint debounce settled on the same value. `DEBOUNCE_MS` in
  `lua/neogrip/grid/init.lua` and the `vim.defer_fn` in `lua/neogrip/ui/syntax.lua`.
- Extmark priorities in the grid: the stripe paints at 90, below treesitter's 100, so it only tints;
  cell content paints at 100, the ellipsis at 105, and the cursor cell over everything at 150.
  `lua/neogrip/grid/highlight.lua`.
- Data row r is line r + 2 (header and rule above it); starting the partial clear of an appended
  batch one line lower wiped the stripe and colours off the last row of the previous batch.
  `lua/neogrip/grid/highlight.lua`, `M.paint`.
- JDBC `getUpdateCount` answers -1 when the driver will not say, which is not the same as zero rows
  affected; the footer says "statement ran" instead of "-1 rows affected".
  `lua/neogrip/grid/init.lua`, `describe`.
- Postgres `bytea` arrives with its invalid bytes already replaced by U+FFFD, so the original cannot
  be recovered; binary detection therefore looks for the replacement character itself.
  `lua/neogrip/grid/layout.lua`, `M.looks_binary`.
- Cell truncation binary-searches the cut point: a 1 MB JSON cell walked down one character at a
  time is slow. `lua/neogrip/grid/layout.lua`, `M.truncate`.

## runner-and-execute

- Trino refuses a statement that carries its terminator and rejects two statements in one call, both
  failing with "mismatched input ';'"; a trailing terminator also breaks the subquery the sort wraps
  a statement in. The terminator is stripped in `lua/neogrip/execute.lua`, `execute_statement`, and in
  `lua/neogrip/sql/split.lua`, `M.selection`; one statement per call is the shape of
  `lua/neogrip/execute.lua`, `run_sequence`.
- A continuable result opens with the whole paging window: opening with batch+1 made the second page
  drain and refill, paying an expensive statement twice - measured on a Trino GROUP BY over a Delta
  table at 226 s and then 236 s, versus 4 ms when opening with the window. The same 226 s wait is
  why a refill announces its execution and restarts the grid clock.
  `java/app/neogrip/gripd/adapter/jdbc/Cursor.java`, `open`; the continuation's progress handler in
  `lua/neogrip/execute.lua`, `M.load_more`.
- The runner's watchdog arms at the request timeout plus 10 s, and only when the timeout is
  non-zero: a timeout of 0 means "run as long as it takes" and must not arm and kill at 10 s.
  `lua/neogrip/gripd/runner.lua`, `M.run`.

## gripd-process

- A stale class cache reads as every statement hanging, recorded twice: compiled trees left from the
  old package layout turned a JDK mismatch into hangs (they are deleted best-effort, because a
  Windows process can hold a class file open), and classes compiled by a newer `NEOGRIP_TEST_JDK`
  javac failed to load on the pinned runtime with `UnsupportedClassVersionError` - which also
  surfaced as hangs, not as a build error. Both constrain `lua/neogrip/gripd/init.lua`, `M.build` (the
  stale-tree sweep and the `--release` flag).
- An `Error` - not just an `Exception` - leaving a handler thread without a response makes the
  client wait forever: a class cache compiled by a newer JDK made every statement hang on a
  `LinkageError`. The dispatch therefore catches `Throwable`, so a request always gets an answer.
  `java/lib/neogrip/jsonrpc/RpcServer.java`.
- The MongoDB wrapper's sampling comparator violates its own contract: TimSort rejects it, while the
  legacy merge sort does not enforce the check - hence `-Djava.util.Arrays.useLegacyMergeSort=true`
  on gripd's command line. Past that, the wrapper's JDBC `getTables` still throws
  `NumberFormatException` parsing a null, so collection names come from the wrapper's own
  `db.getCollectionNames()` script instead. `lua/neogrip/gripd/init.lua`, `M.launch`;
  `java/app/neogrip/gripd/adapter/jdbc/catalog/MongoFields.java`, `collectionNames`.

## lsp

- Treesitter's sql parser errors on T-SQL (bracketed names, TOP, @variables, MERGE, GO), so mssql
  buffers use `syntax/tsql.vim` instead of the extmark layer, and statement splitting is a
  hand-written lexer rather than a treesitter walk. `lua/neogrip/ui/syntax.lua`,
  `lua/neogrip/sql/split.lua`.
- Highlight layer priorities: the dialect extmark layer paints at 110, above treesitter (100) and
  below semantic tokens (125) and diagnostics (150). The LSP deliberately does not advertise
  semantic tokens - they would paint at 125, over the dialect layer's 110 - and matchadd was
  rejected because it is per window and breaks in a split. `lua/neogrip/ui/syntax.lua`;
  `CAPABILITIES` in `lua/neogrip/lsp/init.lua`.

## schema-and-tree

- `getSchemas` answers nothing on SQLite, so its sets hang directly off the connection in the tree;
  MySQL has no schema layer either, and the shared schema reader treats a `getSchemas` exception as
  exactly that. `lua/neogrip/catalog/tree.lua`;
  `java/app/neogrip/gripd/adapter/jdbc/catalog/Metadata.java`, `schemaNames`.
- DuckDB reports main, information_schema and pg_catalog once per attached catalog, so schema names
  are deduplicated (exactly, since an engine that tells Main from main has two schemas there).
  `java/app/neogrip/gripd/adapter/jdbc/catalog/Metadata.java`, `schemaNames`.
- Mongo field sampling reads fifty documents from each end of the collection: the first hundred
  alone biased the answer toward whatever was inserted first. A true random `$sample` was measured
  working and deliberately not used, because a field list that differs between two calls makes tree
  nodes appear and vanish. Without deduplicating by `_id`, a two-document collection reported every
  field as appearing in four documents.
  `java/app/neogrip/gripd/adapter/jdbc/catalog/MongoFields.java`, `sampleFields`.
- Row estimates per engine: PostgreSQL's `reltuples` is -1 on a never-analysed table (PostgreSQL 14
  and up), which is not an estimate, so those rows are left out; MySQL's `table_rows` is an estimate
  on InnoDB and exact on MyISAM, and a view has none; SQL Server sums `row_count` (not `rows`) over
  `index_id` 0 and 1, the heap and the clustered index, so each table is counted once; sqlite,
  duckdb, trino and the Mongo wrapper keep no row estimate at all.
  `java/app/neogrip/gripd/adapter/jdbc/catalog/Counts.java`.
- DuckDB answers a whole-schema `getPrimaryKeys` with an empty result rather than refusing, so each
  table's key is asked for again per table - otherwise the sweep's per-table fallback never runs and
  a definition is cached without its PRIMARY KEY. In the sweep itself, null ("the driver refused")
  must be told apart from an empty map (Trino has no keys at all), or the per-table fallback
  triggers for an engine that truly has no keys.
  `java/app/neogrip/gripd/adapter/jdbc/catalog/Details.java`, `collectDetails`;
  `java/app/neogrip/gripd/adapter/jdbc/catalog/Keys.java`, `schemaPrimaryKeys`.
- Trino throws on `getIndexInfo` because it has no indexes at all; the exception is read as "no
  indexes to report". `java/app/neogrip/gripd/adapter/jdbc/catalog/Keys.java`, `indexInfos`.
- MySQL and MariaDB report their databases as catalogs with no schema layer, and `getTables` with
  the database in the schema argument silently ignores it. Measured against MySQL 9: asking for
  schema "testdb" answered the sys views instead of its two tables, while catalog "testdb" answered
  exactly the two - and MariaDB's driver accepts either, which hides the fault on half the fixtures.
  `java/app/neogrip/gripd/adapter/jdbc/catalog/Listings.java`, `databaseIsCatalog`; the same fact is
  behind the qualifier choice in `Counts.java`, `counts` and `NativeDdl.java`, `nativeDdlText`.
- Asking `getTables` by type does not work across drivers: DuckDB says "BASE TABLE" where others say
  "TABLE", and an unrecognised type silently returns nothing - so everything is requested and the
  system objects are dropped afterwards.
  `java/app/neogrip/gripd/adapter/jdbc/catalog/Listings.java`, `tables`.
- The sibling pool for the sweep is sized per table, not per schema: MySQL, SQLite and the common
  PostgreSQL database keep everything in one schema, and sizing by schemas would leave them
  sequential. `java/app/neogrip/gripd/adapter/jdbc/catalog/Introspect.java`.
- Native DDL per engine: MySQL's SHOW CREATE answers the table's name first and its definition
  second, while Trino answers the definition alone; SQLite keeps the verbatim statement that created
  the table in `sqlite_master`; DuckDB, SQL Server and MongoDB answer no table definition in one
  statement at all. `java/app/neogrip/gripd/adapter/jdbc/catalog/NativeDdl.java`.
- Only the scheme between `jdbc:` and the next colon identifies the engine: the rest of the url can
  carry a file path, and a DuckDB file called postgres_dump.duckdb must not be mistaken for a
  PostgreSQL server. `java/app/neogrip/gripd/adapter/jdbc/catalog/Metadata.java`, `schemeOf`.
- Trino reports Integer.MAX_VALUE as the column size of every plain varchar, which printed as
  varchar(2147483647); a size is shown only when it is positive and below that bound.
  `java/app/neogrip/gripd/adapter/jdbc/catalog/Metadata.java`, `describeType`.

## document-buffers

- Document URIs are percent-encoded with rfc2396 rather than Neovim's default rfc3986, which leaves
  "/" alone - a schema called "a/b" would then spell a path separator. `ENCODING` in
  `lua/neogrip/ui/document.lua`.
- A multi-line value written into a single buffer line raises out of a BufReadCmd, so passing notes
  are flattened to one line before being rendered. `lua/neogrip/ui/document.lua`, `comment`.
- `:edit` refuses to leave a modified buffer when 'hidden' is off; the fallback still opens the
  document in a fresh buffer, losing only the way back. `lua/neogrip/ui/document.lua`, `M.open`.
- MySQL reports every primary key's name as PRIMARY, a name it will not accept back in DDL, so that
  name is dropped from the rendered definition. `lua/neogrip/catalog/ddl.lua`, `constraints`.
- An index's kind is not shared syntax (USING btree is Postgres, CLUSTERED is T-SQL), so the kind is
  said in a trailing comment rather than spelled in the statement. `lua/neogrip/catalog/ddl.lua`,
  `indexes`.
- MySQL and SQLite spell column comments inside the column definition; the portable COMMENT ON form
  is written rather than guessing each dialect's spelling. `lua/neogrip/catalog/ddl.lua`, `comments`.

## requery

- CSVs are registered in DuckDB with `all_varchar = true`: type inference that turns an id into a
  float is worse than every column arriving as text. `lua/neogrip/grid/requery.lua`, `M.register`.
- `uv.kill` with signal 0 returns nil plus ESRCH for a dead process rather than raising, so a plain
  pcall around it would report every pid as alive; liveness is `ok and result == 0`.
  `lua/neogrip/grid/requery.lua`, `process_alive`.

## jdbc-drivers

- The MongoDB JDBC wrapper answers every query with a single column holding a whole document; the
  cursor detects that shape and splits it into one column per field.
  `java/app/neogrip/gripd/adapter/jdbc/Cursor.java`, `describe`;
  `java/app/neogrip/gripd/adapter/jdbc/Documents.java`.
- DuckDB answers `getTableName` and `getSchemaName` with empty strings, SQLite has no schema layer,
  an expression has no table, and some drivers throw rather than say so; optional metadata reads map
  absent, empty and unreadable all to null. `java/app/neogrip/gripd/adapter/jdbc/Cursor.java`,
  `optional`.
- No sibling connection is opened against DuckDB, SQLite or MongoDB: the first two are single-writer
  files, and the MongoDB driver starts a JavaScript engine per connection.
  `java/app/neogrip/gripd/adapter/jdbc/catalog/SiblingPool.java`, `isSingleConnection`.
- MongoDB refuses `setQueryTimeout` outright, and a missing knob is no reason to fail the query;
  optional driver settings go through a tolerance wrapper.
  `java/app/neogrip/gripd/adapter/jdbc/Drivers.java`, `tolerate`.
- Error positions per engine: PostgreSQL reports the offending character and nothing else does; SQL
  Server reports a line within the batch; MySQL puts the line only inside the message text, as
  "at line N". `java/app/neogrip/gripd/adapter/rpc/SqlErrors.java`.

## connections-and-dsn

- PostgreSQL: without `sslmode=disable` for a localhost address, a local server's refused TLS
  handshake is reported as a password problem. `lua/neogrip/gripd/dsn.lua`.
- MySQL and MariaDB: without `characterEncoding=UTF-8` the connector negotiates latin1 and non-ASCII
  values come back mojibaked. `lua/neogrip/gripd/dsn.lua`.
- Trino: port 443 is TLS in practice, and without `SSL=true` the driver reports a TLS server as an
  unexpected end of stream rather than as the wrong scheme. `lua/neogrip/gripd/dsn.lua`.
- Trino: the driver rejects an empty catalog segment in the URL path, and refuses a property it sees
  both in the URL and in the properties object - so only the file-url drivers (sqlite, duckdb) get
  their options passed as JDBC properties. `lua/neogrip/gripd/dsn.lua`.

## bootstrap

- Windows `vim.fn.executable()` can report 0 for a freshly extracted .exe while antivirus still
  holds it, so the JDK probe checks presence with `fs_stat` and lets a true failure surface at
  spawn. `lua/neogrip/gripd/bootstrap/jdk.lua`, `find_executable`.
- Corporate TLS inspection serves certificates without revocation information, which Windows curl
  (schannel) rejects; downloads on Windows pass `--ssl-revoke-best-effort`.
  `lua/neogrip/gripd/bootstrap/download.lua`, `fetch`.
- Hashing uses the OS tool because reading a 190 MB archive into a Lua string would double its
  memory cost. `lua/neogrip/gripd/bootstrap/download.lua`, `M.sha256_of`.

## protocol

- The Lua decoder's numbers are doubles and `vim.json.decode` silently rounds integers past 2^53.
  2^53 is 16 digits, so the client quotes integer literals of 16 or more digits before decoding
  (quoting at 16 keeps every value that is exactly representable as a number), and gripd sends
  BIGINT at or above 2^53 as text in the first place. `lua/neogrip/codec/json.lua`;
  `java/app/neogrip/gripd/adapter/jdbc/Values.java`.

## java-tooling

- `.classpath` gives the language server `java/lib` and `java/app` as the only source roots and
  points its output at `build/jdtls`, apart from the `build/classes` tree a manual `javac` writes,
  so neither can hand the other a half-written class file.
- `.settings/org.eclipse.jdt.core.prefs` pins the language server to release 21 with
  `methodParameters=generate`. Without the compliance level the server compiles on whatever JDK it
  runs on, and a Java 22+ API reads as fine in the editor until `javac --release 21` refuses it;
  without the parameter names the RPC library's named binding has nothing to bind by.
