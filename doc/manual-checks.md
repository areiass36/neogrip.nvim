# Manual checks

What automation cannot cover. Run these by hand before a release, on each platform where they apply, and
record the date and result at the bottom.

## Downloads (per OS: macOS, Windows, Linux)

Automation covers the checksum logic against a local file; the real network path is manual.

1. Delete the plugin's data directory (`:echo stdpath("data")` + `/neogrip`).
2. Open a project with a DuckDB connection and run a statement.
3. Confirm the JDK download starts, the checksum passes, the sidecar compiles and the statement runs.
4. Repeat with a PostgreSQL connection to confirm a driver jar download.

## Secrets never reach a command line

1. Connect to a password-protected database.
2. Find the sidecar PID with `:NGripDoctor`.
3. Inspect the process command line (`ps -o command -p <pid>` on Unix,
   `Get-CimInstance Win32_Process -Filter "ProcessId=<pid>" | Select CommandLine` on Windows).
4. Confirm no password, user name or JDBC URL appears in it.

## Real kvstore integration

The test suite runs against a fake. Once per release, configure a real connection whose password lives in
kvstore.nvim and connect, confirming the key is read and a missing key produces the error message that
names `:KVStore <key>`.

## Windows child-process termination

1. On Windows, run a long statement and kill the Neovim process from Task Manager (no clean exit).
2. Confirm the sidecar java.exe disappears within a few seconds (stdin EOF path).

## Interactive authentication (when the Entra phase lands)

Entra ID interactive login opens a browser and cannot run in CI.

1. Connect to an Azure SQL database with `auth.type = "entra_interactive"`.
2. Confirm the status notifications appear, the browser opens, and the connection completes after MFA.
3. Confirm the documented limitation: the flow fails with a clear message in a headless session.

## Results

| Date | Check | OS | Result |
| --- | --- | --- | --- |
