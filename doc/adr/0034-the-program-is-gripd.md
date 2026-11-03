# 0034. The Java program is gripd, and the handshake names it (protocol 3)

- Date: 2026-11-03T15:14:00Z
- Status: Accepted

## Context

"Sidecar" is deployment jargon: it names a packaging pattern - a container riding along with another -
and says nothing about what this program is. What it is, since ADR-0001, is a standalone JSON-RPC daemon
that speaks JDBC and whose first client happens to be Neovim. The word spread into 53 files, including
the wire: the `initialize` result answers with `sidecarInfo`.

Alternatives considered: `engine` (accurate - it executes - but collides with the database's own engines in
every error message), `host` (idiomatic for Neovim's remote plugin hosts, but names the hosting rather
than the work), `backend` (clear and unambiguous, but defines the program by what it is not), `bridge`
and `conduit` (both describe a channel, and this program does work of its own). `gripd` keeps the
project's own identity - this is neogrip's daemon - and follows the one convention a daemon name has.

Also considered: renaming the program but leaving `sidecarInfo` on the wire until some later contract
change needed a version bump anyway. Rejected: a handshake that names the program by its abandoned name
is the drift this repository refuses elsewhere, and the bump is what turns a mismatch between an old
plugin and a new class tree into a refusal at `initialize` instead of a field nobody reads.

## Decision

- The program is `gripd`: package `neogrip.gripd`, composition root `neogrip.gripd.Daemon`, Lua module
  `neogrip.gripd`, test double `tests/mock_gripd.lua`. The base of the project keeps the base of the
  name; `neogrip` stays the namespace because the plugin is what this is part of.
- The `initialize` result answers with `gripdInfo`, and the protocol version goes from 2 to 3.
  `doc/protocol.md` and both implementations move in the same commit, as the contract requires.
- Protocol 3 carries exactly one change - that field's name - so a mismatch cannot be misread as
  anything else.
- The commit scope `sidecar` becomes `gripd` in `.ai/INSTRUCTIONS.md`.
- The compiled-class directory is cleared of the old package trees (`neogrip/app`, `neogrip/db`,
  `neogrip/rpc`) before the next build, best-effort.
- Accepted records keep the old word, and `0001-sidecar-over-stdio.md` keeps its file name: ids and names
  are never renumbered or renamed, and a decision log is history, not documentation. This record is the
  pointer from one term to the other.

## Consequences

- A plugin and a class tree from opposite sides of this change refuse each other at `initialize` instead
  of exchanging a field under the wrong name.
- Every user recompiles once, because the class cache is stamped with the protocol version.
- The old class trees are removed before the build but failure is ignored: on Windows a live process can
  hold a `.class` file open, and the build must proceed anyway.
- 53 files change, and the ADR log keeps saying "sidecar" in the twenty-three records that predate this
  one. That is correct for a historical log and will read as inconsistent to anyone who treats it as
  documentation.
- Nothing in the editor's production code reads the handshake field - only the live test and the mock do -
  so the wire change is the cheapest half of the rename and the version bump is what gives it teeth.
