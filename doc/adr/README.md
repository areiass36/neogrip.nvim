# Architecture Decision Records

Every architecture decision in this repository is recorded here as a separate file named `<id>-<slug>.md`.
Ids are sequential and never reused or renumbered. An accepted record is never edited: to change a decision,
add a new record and mark the old one as superseded.

The initial set derives from the architectural proposal this plugin started from and from the working MVP
in the author's Neovim configuration; where the two disagreed, the record states which side won and why.

| Id | Title | Status |
| --- | --- | --- |
| 0001 | [The database work runs in a Java sidecar spoken to over stdio](0001-sidecar-over-stdio.md) | Accepted |
| 0002 | [Messages are JSON-RPC 2.0, one object per line](0002-jsonrpc-ndjson.md) | Accepted |
| 0003 | [One sidecar process per connection, started lazily, ended by stdin EOF](0003-process-per-connection.md) | Accepted |
| 0004 | [The sidecar is compiled with javac on first use from sources in the repo](0004-javac-on-first-use.md) | Accepted |
| 0005 | [A private Temurin JDK is downloaded on first use, pinned and checksum-verified](0005-pinned-jdk.md) | Accepted |
| 0006 | [JDBC drivers are downloaded on demand, pinned and checksum-verified](0006-drivers-on-demand.md) | Accepted |
| 0007 | [Secrets come exclusively from kvstore.nvim and are read only at connect time](0007-secrets-kvstore-only.md) | Accepted |
| 0008 | [Connections live in .nvim/database.json, schema version 2](0008-connection-file-schema-v2.md) | Accepted |
| 0009 | [Secrets travel to the sidecar inside the connect request, never in argv or env](0009-secrets-in-connect-request.md) | Accepted |
| 0010 | [Bulk data moves through files with temp-plus-atomic-rename, never through the protocol](0010-bulk-data-through-files.md) | Accepted |
| 0011 | [Authentication is a structured auth object with five modes](0011-auth-modes.md) | Accepted |
| 0012 | [Each configured connection has one shared JDBC connection, with extras on demand](0012-shared-connection-extras.md) | Accepted |
| 0013 | [Autocommit is the default; an explicit transaction pins the session](0013-autocommit-default.md) | Accepted |
| 0014 | [Results are paged with a default row limit and queries are cancellable on the server](0014-paged-results-cancel.md) | Accepted |
| 0015 | [Statements are delimited by a hand-written lexer, not Treesitter](0015-lexer-delimits-statements.md) | Accepted |
| 0016 | [No confirmations for dangerous statements; readonly is layered and production is visible](0016-no-confirmations.md) | Accepted |
| 0017 | [The plugin defines no keymaps; every action is a documented Lua function or command](0017-no-keymaps.md) | Accepted |
| 0018 | [Configuration is setup(opts) and nothing loads or runs before it](0018-setup-entry-point.md) | Accepted |
| 0019 | [The minimum supported Neovim version is 0.12](0019-minimum-neovim-version.md) | Accepted |
| 0020 | [MongoDB enters through a third-party JDBC wrapper behind per-connection capabilities](0020-mongodb-via-wrapper.md) | Accepted |
| 0021 | [DuckDB is a supported database and the engine behind results requery](0021-duckdb-results-requery.md) | Accepted |
| 0022 | [Language services are an in-process Lua LSP fed by the swept catalog](0022-in-process-lua-lsp.md) | Proposed |
| 0023 | [Tests are flat headless scripts in unit and live lists; live tests skip when unreachable](0023-test-strategy.md) | Accepted |
| 0024 | [User commands are prefixed NGrip](0024-ngrip-prefix.md) | Accepted |
| 0025 | [The MongoDB wrapper is DataGrip's mongo-jdbc-driver 1.21](0025-mongodb-wrapper-chosen.md) | Accepted |
| 0026 | [An expired token fails the statement; nothing renews it silently](0026-token-expiry.md) | Accepted |
| 0027 | [Sidecar methods are annotated functions returning typed records](0027-annotated-rpc-methods.md) | Accepted |
| 0028 | [Every request runs on its own thread; the session is a lock](0028-virtual-threads-session-lock.md) | Accepted |
| 0029 | [MongoDB metadata through the wrapper is best-effort](0029-mongodb-metadata-is-best-effort.md) | Accepted |
