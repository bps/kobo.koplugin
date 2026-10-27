# Testing

## Unit tests

Run `busted spec/` with LuaJIT, Busted and LuaCov installed in an isolated development environment.
The unit suite loads `spec/helper.lua`, which replaces KOReader dependencies and many operating
system operations. Passing these tests does not establish filesystem, process or SQLite correctness.

## Native integration tests

The separate suite runs in fresh LuaJIT processes without `spec/helper.lua`. It uses real files,
libarchive, SQLite databases, child processes, pipes and process cleanup. Cryptographic operations
in the archive tests are deterministic stand-ins; this is not a cryptography or device-firmware
test.

Required dependencies:

- LuaJIT and LuaFileSystem for its Lua 5.1 ABI
- Native libarchive and SQLite libraries discoverable by the dynamic loader
- Bash, `timeout` (GNU coreutils on macOS), `zip`, `unzip`, and standard POSIX shell commands
- A koreader-base source checkout

CI pins the runtime source to `cd173c179a56b42ddbf06b6ac3eafec099ffe219`. To run the same suite:

```bash
git clone https://github.com/koreader/koreader-base .native-runtime/koreader-base
git -C .native-runtime/koreader-base checkout cd173c179a56b42ddbf06b6ac3eafec099ffe219
KOREADER_BASE="$PWD/.native-runtime/koreader-base" bash test/run-integration.bash
```

Every suite has a 20-second deadline. Missing dependencies are errors, not skipped tests. The
private `dbus-monitor` fixture is placed first on PATH only for this runner. The tests do not
connect to the host system bus or terminate unrelated monitors.

The SQLite tests use temporary databases and injected database triggers. They check successful
commits, failures of either update, reader-blocked commits, exclusive locks, rollback and lock
release. Never point these tests at a device's live database.

The tests cover:

- Preserving existing cache files and publishing finalized archives
- Detecting native archive close failures and failed publication
- Non-blocking split-message reads, final-message delivery, EOF and owned-process cleanup
- Atomic reading-state writes under real SQLite failures and contention
- Fresh release ZIPs, required runtime files and propagation of packaging errors

Hardware smoke tests remain necessary for radio bring-up, suspend/resume and device-specific
Bluetooth behavior.
