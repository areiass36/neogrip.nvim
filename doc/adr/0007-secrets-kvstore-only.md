# 0007. Secrets come exclusively from kvstore.nvim and are read only at connect time

- Date: 2026-10-29T13:39:55Z
- Status: Accepted

## Context

The MVP resolved passwords through a tagged union of sources: environment variable, external command,
native OS keyring, interactive prompt, or none. That bought flexibility and three per-OS keyring
integrations to maintain. Worse, the `command` source allowed a project file cloned from a repository to
name an executable — a remote-execution vector the architectural proposal explicitly rejected.

kvstore.nvim is the author's own plugin: one encrypted vault, master key in the OS keystore, synchronous
`get(key)`, no external programs, already maintained and tested on all three platforms.

## Decision

Every secret — password, client secret, token, SSH passphrase — is read from kvstore.nvim and from nowhere
else. The connection file stores only kvstore key names (`{ "kvstore": "<key>" }`); a literal secret value
in a connection file is a hard validation error. kvstore.nvim is a hard dependency of the plugin. The read
happens in Lua, only at connect time; `get` being synchronous is accepted because it runs once per connect,
not per statement. The MVP's `env`, `command` and `prompt` sources and its entire `keyring/` layer are not
ported.

## Consequences

- The connection file is inert data again: nothing in it can execute anything.
- One less subsystem to maintain; secret storage bugs are kvstore's to fix in one place.
- Users must install kvstore.nvim and register keys with `:KVStore <key>` before connecting; error
  messages must say exactly that.
- A slow keystore blocks the editor for the duration of one `get` at connect; revisit only if it hurts.
- Tests must never require the real kvstore: the harness preloads an in-memory fake.
