# Project Instructions

Rules for every change made in this repository. This is a Neovim plugin written in Lua with a Java sidecar
that turns the editor into a SQL and data-manipulation client, so correctness of the protocol contract,
secret hygiene and portability rules are strict.

## Boundaries

**Always**
- Run the formatter and the linter before committing.
- Add or update tests for every behavior change.
- Record every architecture decision as an ADR before implementing it.
- Read `doc/adr/` before proposing a change that touches architecture.
- Keep `doc/protocol.md` and both protocol implementations (Lua and Java) in sync in the same commit.

**Ask first**
- Adding a dependency of any kind, including external executables, JDBC drivers and Java libraries.
- Changing command names, the public Lua API, the connection file schema or the wire protocol.
- Changing a pinned artifact version or checksum (JDK, driver jars).
- Raising the minimum supported Neovim version or the Java language level.

**Never**
- Commit secrets, keys, tokens or `.env` files.
- Skip hooks (`--no-verify`) or force push to a shared branch.
- Edit an accepted ADR. Supersede it with a new one.
- Edit generated files such as `doc/tags`.
- Commit anything that names or credits an AI tool or model. See [Commits](#commits).

## Language

- All code is written in English: identifiers, strings, error messages and comments.
- All documentation is written in English.

## Code Style

- Small functions, one responsibility per module, intention-revealing names.
- Lua is formatted with StyLua and linted with luacheck. Their config files are versioned in the
  repository root.
- Java has no build system by design (see ADR-0004). The quality bar is `javac -Xlint:all -Werror`
  compiling clean.

```bash
stylua .
stylua --check .
luacheck lua tests
javac -Xlint:all -Werror -d build/classes java/neogrip/*.java
```

## Comments

- Comment the reason behind a decision, not what the code already says.
- When a decision came from a measurement or a failed alternative, record the number or the failure in the
  comment. A future reader cannot re-run the conversation that produced it.
- Write comments as prose in full sentences.

## Tests

- Tests live in `tests/` as flat headless scripts named `unit_<area>.lua` and `live_<area>.lua`,
  registered in the `UNIT` and `LIVE` lists in `tests/run.lua`. The runner is defined by ADR-0023.
- Unit suites never touch a network or a database server. Live suites probe reachability first and skip,
  never fail, when the server is not there.
- Tests never use real credentials and never require the real kvstore.nvim: `tests/minimal.lua` preloads
  `tests/fake_kvstore.lua` in its place.

## Secret Rules

These rules must never be broken, even for convenience, debugging or refactoring.

- Every secret comes from kvstore.nvim and from nowhere else. The connection file stores only kvstore key
  names, never values; a literal secret in `.nvim/database.json` is a hard validation error (ADR-0007).
- A secret reaches the sidecar only inside the `connect` request on the stdio pipe, never in a command-line
  argument, an environment variable or a JDBC URL (ADR-0009).
- A secret never appears in a log, a notification, an error message, a register or a buffer. Every message
  derived from a driver error passes through the redaction in `dsn.lua` before a user can see it.
- The Java side never echoes `connect` parameters into responses, exceptions or stderr.
- Keep secret values in memory only as long as strictly needed: read at connect time, handed over, dropped.

## Protocol

- `doc/protocol.md` is the source of truth for the Lua–Java contract: JSON-RPC 2.0, one JSON object per
  line over stdio (ADR-0002). The sidecar's stdout carries protocol frames and nothing else; logs go to
  stderr.
- A change to the contract bumps the protocol version and is recorded in an ADR before implementation.
- Bulk data (catalog snapshots, exports) moves through files written with temp-plus-atomic-rename, never
  through the protocol (ADR-0010).

## Cross-Platform

The plugin is developed for macOS, Windows and Linux. Code must behave the same on all three.

- Build paths with `vim.fs` and `vim.uv` in Lua and `java.nio.file.Path` in Java. Never concatenate with a
  hardcoded separator.
- Never assume a shell. Run external processes with an argument list, never a shell string.
- Never assume tools exist. Detect them and fail with a clear error message.
- Keep file names lowercase so `require` behaves the same on case-insensitive filesystems (Java sources
  follow Java's own naming convention).
- Keep line endings as LF. See `.gitattributes`.
- Downloaded artifacts (JDK, driver jars) are pinned to exact versions and verified against a SHA-256
  checksum before anything from them is executed (ADR-0005, ADR-0006).

## Neovim Version

- The minimum supported Neovim version is 0.12, recorded in ADR-0019.
- Do not use APIs introduced after that version, and do not use deprecated APIs.

## Documentation

- `README.md` at the repository root is the entry point for someone who has never seen the plugin: what it
  is for, how to install it, how to use it, and the keymap recipe (the plugin defines none, ADR-0017).
- Every other documentation file lives in `doc/`. Do not create documentation files anywhere else.
- The `:help` file is `doc/neogrip.txt`. Update it whenever a command, API function or behavior changes.
- Keep documentation in sync with the code. Outdated documentation is a bug.

## Architecture Decision Records

- Every architecture decision is an ADR in `doc/adr/`.
- Each ADR is a separate file named `<id>-<slug>.md`, where `<id>` is a zero-padded sequential number
  (`0001`, `0002`, ...) and `<slug>` is a short kebab-case title.
- Ids are never reused or renumbered.
- `doc/adr/README.md` lists all ADRs ordered by id.
- Each ADR starts with its creation date and time, always in UTC+00 (ISO 8601, `YYYY-MM-DDTHH:MM:SSZ`).
- An accepted ADR is not edited. To change a decision, create a new ADR and mark the old one as superseded.
- Use this structure:

```markdown
# <id>. <Title>

- Date: YYYY-MM-DDTHH:MM:SSZ
- Status: Proposed | Accepted | Superseded by <id>

## Context

## Decision

## Consequences
```

## Commits

Commits follow Conventional Commits: `<type>(<scope>): <subject>`.

**Types**
- `feat`: new behavior visible to the user
- `fix`: bug fix
- `refactor`: code change with no behavior change
- `perf`: performance improvement
- `test`: add or change tests
- `docs`: documentation only, including ADRs
- `build`: build system or dependencies
- `ci`: continuous integration
- `chore`: maintenance that fits no other type
- `revert`: revert a previous commit

**Scopes**
- `commands`: the `:NGrip*` commands
- `connections`: connection files, resolution and secrets
- `rpc`: the JSON-RPC client and protocol definitions
- `sidecar`: the Java process lifecycle and the Java sources
- `runner`: request queueing and execution flow
- `grid`: the result buffer, its actions, exports and requery
- `explorer`: the schema explorer and document buffers
- `schema`: catalog cache and introspection
- `lsp`: language services, completion and diagnostics
- `bootstrap`: JDK, driver and binary downloads
- `docs`: files in `doc/`
- `adr`: files in `doc/adr/`
- `tests`: test infrastructure
- `repo`: repository configuration such as `.gitignore` and `.gitattributes`

A commit that touches several scopes should be split. If that is impossible, omit the scope.

**Subject**
- Imperative mood: "add", not "added" or "adds".
- Lowercase, no trailing period, at most 50 characters.

**Body**
- Optional. Separate it from the subject with a blank line and wrap it at 72 characters.
- Explain why the change was made, not what it does.

**Footer**
- Breaking changes use `!` after the scope and a `BREAKING CHANGE:` footer.
- Reference the related decision with `Refs: ADR-<id>`.

**Rules**
- One logical change per commit.
- Every commit must leave the repository passing format, lint and tests.
- Never rewrite the history of a pushed shared branch.

**AI attribution is forbidden**
- Never commit anything that names or credits an AI tool, assistant or model. This applies to commit
  messages, trailers, code, comments, documentation, file names and branch names.
- Never add `Co-authored-by` trailers or "generated with" lines.
- The one exception is the AI specific files section of `.gitignore`, which lists the pointer files so
  they are never committed.

## Branches

Format: `<type>/<short-description>`.

- `type` is one of the commit types: `feat`, `fix`, `refactor`, `perf`, `test`, `docs`, `build`, `ci`, `chore`.
- The description is lowercase kebab-case, ASCII only, at most 40 characters.
- Describe the change, not the person or the ticket number alone: `feat/grid-actions`, `fix/windows-eof`.
- Branch from `main` and keep branches short-lived.
- Delete the branch after it is merged.
