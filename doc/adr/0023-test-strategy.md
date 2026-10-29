# 0023. Tests are flat headless scripts in unit and live lists; live tests skip when unreachable

- Date: 2026-10-29T13:39:55Z
- Status: Accepted

## Context

plenary/busted nesting was considered (kvstore.nvim uses it) and rejected here: the MVP's harness — a
ten-line `minimal.lua`, a support module with `describe`/`check`/`sync`/`reachable`, flat script suites and
an explicit runner — already exists, tests callback-based code naturally through `sync`, and adds no
dependency. The module under test is loaded directly, not through a plugin manager, so the tests exercise
the code rather than the loader.

## Decision

Tests are flat headless Lua scripts under `tests/`, named `unit_<area>.lua` (no network, no server) and
`live_<area>.lua` (real sidecar and, where applicable, real databases from `tests/containers.sh`),
registered in explicit `UNIT` and `LIVE` lists in `tests/run.lua` and invoked as
`nvim --headless -u tests/minimal.lua -l tests/run.lua [unit]`. Live suites probe reachability first and
skip — never fail — when the server is absent; CI's live job asserts a minimum reached-count so skipping
cannot silently become total. The harness preloads `tests/fake_kvstore.lua` in place of kvstore.nvim.
Quality bars: `stylua --check .`, `luacheck lua tests`, and `javac -Xlint:all -Werror` compiling clean.

## Consequences

- No test dependency to install anywhere; CI needs only Neovim and a JDK.
- The harness is ours to maintain, including its known weakness: flat scripts share no isolation beyond
  what each suite cleans up itself.
- Modules must export their test hooks deliberately (synchronous twins, pure renderers), which doubles as
  API discipline.
