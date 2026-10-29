# 0015. Statements are delimited by a hand-written lexer, not Treesitter

- Date: 2026-10-29T13:39:55Z
- Status: Accepted

## Context

The architectural proposal suggested Treesitter SQL for finding the statement under the cursor, with a
fallback when the parser is missing. The generic SQL grammar has known gaps in the dialects this plugin
targets, the parser is something the user would have to install — against the zero-install goal — and
T-SQL's `GO` is not SQL at all, so Treesitter can never delimit it.

The MVP answered this with a small hand-written lexer that already handles PostgreSQL dollar-quoting,
MySQL's `DELIMITER` command, SQL Server's `GO`, nested block comments, and per-dialect backslash escaping.
It is dependency-free and has a test suite.

## Decision

The MVP's lexer (`sql/split.lua`) is the one and only statement delimiter, ported as-is. This supersedes
the Treesitter-first wording of the original proposal's ADR-011. Treesitter, when the user happens to have
the parser, is used for nothing but optional syntax colouring.

## Consequences

- Statement execution works identically on a bare Neovim with no parsers installed.
- New dialect quirks are the lexer's to learn, with tests; there is no grammar to lean on.
- Result display concerns from the proposal's ADR-011 (column widths, NULL display, truncation) are
  configuration of the grid, carried in `config.lua`.
