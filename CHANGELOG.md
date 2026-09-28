# Moonwalk changelog

All notable changes to this project are recorded here.

## Unreleased (test branch)

### Fixed

- CI now runs on the default branch: `.github/workflows/build.yml` triggers
  on `push`/`pull_request` to `main` (it previously targeted the nonexistent
  `master` branch, so no CI ever ran). The build workflow builds, runs native
  tests, runs the Lua unit tests, and runs the P0 DAP conformance tests, and
  uploads failure artifacts. It no longer attempts to publish.
- Publication moved to a dedicated `.github/workflows/release.yml` that runs
  only on `v*` tags, re-runs the full test gates before publishing, and
  publishes from `extension/` where the build actually generates
  `package.json` (the old workflow published from a nonexistent `publish/`
  directory). No `continue-on-error` anywhere in CI.
- Native test discovery (`test/interceptor.lua`) is fail-closed: it exits 2
  when zero test binaries are found, or when fewer than the committed
  per-platform minimum are found (linux 4, macos 4, windows 5; overridable
  with `MOONWALK_MIN_TESTS`). A zero-test run can no longer pass silently.
- stdio DAP framing is protected: `extension/script/frontend/proxy.lua` no
  longer writes bare `print()` diagnostics to stdout (which would corrupt the
  `Content-Length` stream); both messages now go through `common.log`.
- Request validation in `extension/script/backend/master/request.lua`:
  `setBreakpoints`, `variables`, `restart`, `terminateThreads`, `readMemory`
  (plus adjacent `writeMemory` and `disassemble`) now validate their
  arguments before dereferencing them. A malformed request gets exactly one
  unsuccessful DAP response; the adapter never raises a Lua error on the
  request path. `setBreakpoints` treats an absent `breakpoints` list as
  "clear all" per DAP, and `restart` with no arguments restarts with the
  current session configuration instead of crashing.
- `compile/common/package_json.lua` no longer advertises `lua55` and
  `lua-latest` in the public runtime enum; the README forbids claiming Lua
  5.5 support until it is implemented and tested. Internal build
  dependencies are unchanged.

### Added

- Black-box DAP conformance harness under `test/dap/`: stdlib-only Python 3,
  stdio and TCP transports, byte-accurate `Content-Length` framing with
  fragmentation/coalescing, correlated request/response matching, reverse
  requests, per-request and per-case deadlines, separate raw stdout/stderr
  capture, transcript normalization, process-tree cleanup, and failure
  artifacts. 32 cases, exactly 16 validation / 16 adversarial. Adapter
  discovery is fail-closed: binary-needing cases report BLOCKED when no
  adapter is built, never pass. Without a built adapter the static P0
  suite (CI checks, runtime-enum check, stdout-protection check) passes
  10/10 and the 22 adapter-needing cases report BLOCKED.
- Lua unit tests under `test/unit/`, run by `test/unit/run_unit.lua`, which
  discovers `*_test.lua`, fails on zero tests or zero assertions, and
  reports the validation/adversarial split (36 tests: 18/18, 613 assertions).
  Coverage: DAP wire framing against the real `common/protocol` and
  `common/json` (round trips, every split position, 100 coalesced frames,
  16 MiB boundary, malformed headers, one-byte-at-a-time delivery, seeded
  garbage-recovery trials) and request validation against the real backend
  `request`/`response` modules.
- `test/fuzz/` libFuzzer targets for the DAP framing layer (`protocol_fuzz`,
  `undump_fuzz`, `source_map_fuzz`). They ship with explicitly-marked
  reference stubs mirroring the current Lua behavior -- a green stub run
  proves harness logic only; each header names the exact function to wire
  once the native build exists.
- `test/run.lua`: single project entry point dispatching the unit, native,
  DAP, and fuzz stages, reporting PASS/FAIL/BLOCKED per stage.

### Known findings (documented, not changed)

- The DAP framing layer (`extension/script/common/protocol.lua`) does not
  resynchronize after a non-terminated garbage prefix: the
  `Content-Length: ` prefix check is anchored at the buffer start, so one
  malformed chunk can wedge the stream until the 8 KiB header cap drops
  the buffer. This is verified by unit test MW-PROTO-A05 and documented
  in `test/fuzz/protocol_fuzz.cpp`, which traps on the wedge by design.
  The parser is frozen wire code (header comment: restyle only), so no
  behavior change was made; fixing the resync policy needs Matt's call.

### Test-balance policy

Every test layer in this program keeps an exact 50/50 split between
validation tests (specified behavior holds) and adversarial tests
(malformed input, protocol abuse, and resource limits are handled safely).
The unit runner enforces the split and reports it on every run.
