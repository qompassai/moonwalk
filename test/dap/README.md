# moonwalk DAP conformance harness

Black-box conformance tests for the moonwalk Lua DAP adapter, plus
libFuzzer targets for its wire framing, bytecode undumper, and
source-path normalization layers.

Standard library only: `python3` and a C++17 compiler are the only
requirements. No pip, no third-party packages, no placeholders.

## Layout

```
test/dap/
  run.py            # the runner: discovery, timeouts, artifacts, summary
  client.py         # DAPClient: stdio/TCP transports, framing, deadlines,
                    # reverse requests, raw capture, transcript normalization,
                    # Linux /proc process-tree cleanup
  assertions.py     # invariant checkers (each raises AssertionError)
  cases/
    _common.py      # shared session helpers (not a case; underscore-prefixed)
    _yamlish.py     # minimal YAML-subset parser for the CI workflow checks
    mw_*.py         # the cases (see "Case list")
  fixtures/
    loop.lua breakme.lua crash.lua   # debuggee programs
  corpus/
    valid_frame.bin garbage_prefix.bin malformed_json_frame.bin
    bad_lengths.txt split_positions.txt README.md
test/fuzz/
  protocol_fuzz.cpp    # DAP wire framing (Content-Length reassembly)
  undump_fuzz.cpp      # bytecode undumper (string.dump input)
  source_map_fuzz.cpp  # source-path normalization
```

## Run syntax

```sh
# list all cases
python3 test/dap/run.py --list

# full suite (default seed is 1; PR runs must use the default)
python3 test/dap/run.py

# one case, default seed
python3 test/dap/run.py --case MW-STDIO-001

# one case, explicit seed (nightly rotation)
python3 test/dap/run.py --case MW-REQ-003 --seed 20260928

# conformance gate suite only (what CI runs)
python3 test/dap/run.py --suite p0

# custom artifact root (default: <repo>/artifacts)
python3 test/dap/run.py --artifacts-dir /tmp/mw-artifacts

# allow cases marked destructive (none are currently)
python3 test/dap/run.py --allow-destructive
```

Every case runs under a watchdog thread: the case timeout in its `CASE`
dict is absolute. **Every timeout is a FAIL** -- a hung adapter is never a
pass, never retried silently.

## Case statuses

| status    | meaning |
|-----------|---------|
| `PASS`    | every assertion held |
| `FAIL`    | an assertion failed, a timeout fired, or the adapter misbehaved |
| `BLOCKED` | the case could not run for an environmental reason, with the reason recorded |
| `ERROR`   | the harness itself broke (bug in the case or runner, not the adapter) |

### BLOCKED semantics

`BLOCKED` is a loud "could not test", never a pass. Today the only
BLOCKED trigger is a missing adapter binary: `ctx.require_adapter()`
raises, the runner records `BLOCKED` with the reason
(`no adapter binary found; probed <paths>`), and no assertions are
evaluated. A BLOCKED case must never be reported as passing, and a suite
with any BLOCKED case is not green.

## Artifact layout

On `FAIL` or `ERROR` (and whenever `--artifacts-dir` is given), the runner
writes:

```
artifacts/<case-id>/<seed>/
  command.txt             # exact reproducer command
  environment.txt         # python version, platform, cwd, repo, git SHA,
                          # case/status/seed, killed_by_runner
  transcript.jsonl        # normalized DAP transcript, one JSON object per
                          # line (t, dir, kind, payload); ends with a
                          # case-error entry carrying the failure text
  stdout.bin              # raw adapter stdout bytes (only when the case
  stderr.txt              # raw adapter stderr        spawned a client;
  framing-violations.txt  # framing/decode violations per-client -N suffix
                          # seen on stdout             when a case spawns >1)
  adapter-exit.json       # adapter pid, returncode, stdout/stderr byte counts
  process-tree.txt        # /proc process tree under the adapter at case end
  fixture.lua             # the debuggee fixture used, when any
  reproduction.sh         # executable reproducer (cd <repo> && rerun)
```

`stdout.bin` is the ground truth: `transcript.jsonl` is derived from it by
the (also tested) framing parser, so a framing bug shows up as a
framing-violation, not as a mysteriously clean transcript.

## Adapter-path assumption (loud)

The adapter is a single native binary produced by the repo build. The
runner probes, in order:

1. `<repo>/build/bin/moonwalk`
2. `<repo>/build/moonwalk`
3. `<repo>/publish/**/moonwalk*`

The first executable regular file wins. If the build renames the binary
or splits it per-platform, `find_adapter()` in `run.py` must be updated --
a miss BLOCKS every black-box case rather than faking a pass. The probed
paths are recorded in the BLOCKED reason.

## Platform assumptions (loud)

Linux-first. Process-tree discovery and cleanup read `/proc/<pid>/stat`
and `/proc/<pid>/task/<tid>/children` directly -- no psutil, no `ps`
parsing. Cleanup sends `SIGTERM`, waits bounded, then `SIGKILL`, and only
ever touches processes in the adapter's own tree (children the case
spawned). **The harness never attaches to, signals, or kills a process it
did not spawn.** Cases declare their needs (`needs_ptrace`,
`needs_network`, `needs_admin`) in `CASE`; the runner refuses to run a
case whose needs are not allowed on the current platform.

## Case list

Static (no adapter needed; CI gate `--suite p0`):

| id | kind | what it checks |
|----|------|----------------|
| MW-CI-001 | validation | CI workflow exists and has the required jobs |
| MW-CI-002 | validation | workflow triggers on the right branches |
| MW-CI-003 | validation | workflow runs the DAP suite step |
| MW-CI-004 | validation | no publish/deploy step in PR workflows |
| MW-RUNTIME-001 | validation | `luaVersion` enum matches the supported set |
| MW-STDIO-003 | validation | stdio frontend reads protocol.lua framing constants |

Black-box (need the adapter binary; `--suite p1`):

| id | kind | what it checks |
|----|------|----------------|
| MW-STDIO-001 | validation | initialize handshake over stdio |
| MW-STDIO-002 | adversarial | stale `/tmp/luadbg_*` socket cleanup keeps the DAP stream clean |
| MW-REQ-001..006 | adversarial | malformed backend requests: exactly one unsuccessful response, no crash, session survives |
| MW-ATTACH-001 | adversarial | attach with no selector: validation error before spawning anything |
| MW-ATTACH-002 | adversarial | attach with non-boolean `client`: explicit type error |
| MW-LIFE-001 | validation | stdin EOF shuts the adapter down within the bound |
| MW-LIFE-002 | adversarial | backend SIGKILLed: exactly one synthesized `terminated` |
| MW-LIFE-003 | validation | natural `terminated`, then client goes away: still exactly one |
| MW-LIFE-010 | adversarial | request before initialize: error, adapter stays alive |
| MW-LIFE-011 | adversarial | duplicate initialize: exactly one correlated response either way |
| MW-LIFE-012 | adversarial | unknown command before and after launch: one error each |

## Fuzz targets

`test/fuzz/*.cpp` are libFuzzer targets (`LLVMFuzzerTestOneInput`).
Build once the repo builds:

```sh
clang++ -std=c++17 -fsanitize=fuzzer,address test/fuzz/protocol_fuzz.cpp -o protocol_fuzz
./protocol_fuzz -max_len=65536 test/dap/corpus/
```

Each target's only coupling to the adapter is one documented function
name (`MoonwalkFeedFraming`, `MoonwalkUndump`, `MoonwalkNormalizePath`).
They ship with reference stubs modeling the documented contracts so they
compile and run today; the file headers mark exactly what must be wired
to the real code after the native build exists, and a green stub run
proves only the harness logic, not the adapter. **Known finding** (in the
`protocol_fuzz.cpp` header, verified against the real `protocol.lua`):
a hostile chunk can permanently desync the framing stream, so the
recovery invariant currently traps -- by design, until the adapter is
fixed.

## AI-agent task contract template

When delegating harness work to an agent, paste and fill this in. The
agent must follow it verbatim.

```
You are extending the moonwalk DAP harness. Hard constraints:

- Ownership: ONLY new files under test/dap/ and test/fuzz/. Do not edit
  any other file for any reason.
- Python 3 standard library only. No pip, no network installs, no
  placeholders or stubs in shipped code (fuzz targets excepted: their
  reference stubs are explicitly marked).
- Deterministic default seed: 1. New cases take --seed and are
  reproducible bit-for-bit at the default.
- Every timeout is a FAIL. Missing adapter binary is BLOCKED with a
  reason, never a fake pass. Static cases must pass without a binary.
- Never attach to, signal, or kill processes the case did not spawn.
  Linux-first: /proc-based process handling, no psutil.
- No destructive git operations. Do not push.

Task: <one specific task>

Before writing code, read: test/dap/README.md (this file),
test/dap/client.py, test/dap/assertions.py, test/dap/cases/_common.py,
and the protocol sources your task touches
(extension/script/common/protocol.lua,
extension/script/frontend/stdio.lua,
extension/script/frontend/proxy.lua,
extension/script/backend/master/request.lua).

Report back: files created, exact per-case results from
`python3 test/dap/run.py`, the Python version, the adapter probe result,
and anything you could not honestly implement.
```
