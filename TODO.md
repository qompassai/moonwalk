# TODO: make lua-debug a reliable Neovim debugger

Repository: [qompassai/lua-debug](https://github.com/qompassai/lua-debug).
Reviewed source: [`d80654e613e13b7ca79a64c038541f9386cd75b3`](https://github.com/qompassai/lua-debug/tree/d80654e613e13b7ca79a64c038541f9386cd75b3).
The downloaded source archive identifies that exact commit. The local build tree
shown in the request was used for context; its binaries were not executed.
This is a source-reviewed implementation checklist, not a claim of completed
Neovim compatibility or a runtime security audit.

**Goal:** retain the existing debugger engine, make its DAP adapter independent
of VS Code, and integrate it with a plugin-free Neovim debugging layer on Arch
Linux. Debugging Lua programs and debugging Neovim's own Lua require separate
acceptance tests.

## What already exists

| Component | Existing implementation | Action |
| --- | --- | --- |
| Standalone adapter | `compile/common/lua-debug.lua` builds `publish/bin/lua-debug` | Reuse and package it |
| Stdio transport | `extension/script/frontend/main.lua` chooses `frontend.stdio` when no port is supplied | Harden and test it |
| DAP framing | `extension/script/common/protocol.lua` handles Content-Length and JSON | Bound and validate it |
| TCP frontend | A positional port selects a listener on `127.0.0.1` | Keep optional; do not confuse it with the debuggee connection |
| Debuggee connection | `frontend/proxy.lua`, `common/socket.lua`, `script/debugger.lua` | Document both endpoints and connection direction |
| Engine | `src/luadebug/` and `extension/script/backend/` | Preserve working breakpoint, stepping and evaluation code |
| Runtime builds | `compile/common/runtime.lua` builds Lua 5.1–5.5, LuaJIT and lua-latest variants | Start with Linux x64 Lua 5.4 and LuaJIT |
| Non-extension bootstrap | `examples/standalone/debugger.lua` loads `publish/script/debugger.lua` | Extend into editor-independent examples |

Source: [build target](https://github.com/qompassai/lua-debug/blob/d80654e613e13b7ca79a64c038541f9386cd75b3/compile/common/lua-debug.lua),
[frontend](https://github.com/qompassai/lua-debug/blob/d80654e613e13b7ca79a64c038541f9386cd75b3/extension/script/frontend/main.lua),
[runtime builds](https://github.com/qompassai/lua-debug/blob/d80654e613e13b7ca79a64c038541f9386cd75b3/compile/common/runtime.lua).

Do not replace DAP with LSP or Neovim RPC. Neovim RPC can help launch or control
a test Neovim process, but debugger requests still travel over DAP. Do not load
the entire adapter frontend into Neovim: its bundled host runtime and target
LuaJIT runtime are different execution environments.

## P0 — establish a minimal editor-independent session

### 1. Confirm the Neovim client boundary

- [ ] Record the exact installed Neovim version, LuaJIT version, architecture,
  and the actual DAP client API used by the configuration.
- [ ] Verify the existing native debugging layer before adding registration
  code. Do not assume Neovim 0.13 automatically provides a documented
  `vim.debug.adapters` or `vim.debug.configurations` API. The upstream runtime
  directory inspected for this review did not contain a `debug` or `dap`
  module; inspect any custom build or separately supplied implementation.
- [ ] If the existing DAP layer is available, add one adapter integration to it.
  If it is not, track implementing a plugin-free DAP client as a separate
  prerequisite, including framing, pending requests, reverse requests, events,
  session state, UI and teardown. Launching a subprocess alone is insufficient.
- [ ] Use one adapter process per session initially. Spawn the actual executable
  with an argv list, pipes and a controlled working directory. Keep the adapter
  off a PTY; terminal newline transformations can corrupt its protocol.
- [ ] Add the integration as a small module, for example a proposed
  `integrations/neovim/lua_debug.lua`. Install it into the existing configuration's
  module structure without replacing its shared DAP loader.

Acceptance: a headless client sends `initialize` to the adapter and parses one
successful response without VS Code, Node, extension installation, or a UI.

### 2. Normalize configuration before frontend launch/attach

**Files:** `extension/script/frontend/proxy.lua`,
`frontend/debuger_factory.lua`, `backend/master/resolve_config.lua`,
`backend/master/request.lua`, `backend/worker/variables.lua`.

- [ ] Dispatch launch/attach using the outer request's `command`. Currently
  `proxy_start()` tests `pkg.arguments.request`; a normal DAP client need not
  duplicate the command in the adapter-specific argument object. Reject an
  inconsistent duplicate explicitly if backward compatibility keeps it.
- [ ] Move reusable normalization to a proposed `script/common/config.lua` and
  invoke it before frontend code consumes configuration. The existing resolver
  is called in the backend, after frontend launch decisions have already run.
- [ ] Fix the resolver's declared contract: it currently mutates in place and
  returns nothing, although its annotation describes returned config/error
  values. Either document in-place mutation or implement and check the returns.
- [ ] Validate the request and field types instead of silently converting every
  non-attach request to launch. Return one structured DAP error for invalid input.
- [ ] Define explicit defaults and validation for `program`, `cwd`, `luaVersion`,
  `luaArch`, `luaexe`, `runtimeExecutable`, `arg`, `arg0`, `runtimeArgs`, `env`,
  `console`, `inject`, `address`, `client`, `stopOnEntry`, `stopOnThreadEntry`,
  `keepSessionAlive`, `sourceCoding`, `outputCapture`, `path`, `cpath`,
  `sourceMaps`, and `configuration.variables`.
- [ ] Always validate/default the nested `configuration.variables` table, even
  when `configuration = {}` was supplied. `variables.lua` dereferences it.
- [ ] Handle JSON null intentionally, including the documented environment
  variable removal behavior; do not treat a decoder's null sentinel as a string.
- [ ] Resolve Neovim-specific values such as current file and project root in
  the Neovim integration. Do not expect `${file}`, `${workspaceFolder}`, or
  `${command:...}` expansion to be provided by the wire protocol.
- [ ] Keep the repository's `arg` field in documented examples. If adding an
  `args` alias, normalize it explicitly and reject ambiguous double definitions.
- [ ] Document that adapter launch `pathFormat = 'linuxpath'` is an internal
  source-path convention; it is not the same field as the DAP initialize
  request's `pathFormat = 'path'` or `'uri'`.

Acceptance: a minimal launch succeeds without VS Code defaults, and a request
without `arguments.request` neither hangs nor disappears. Malformed config
fails before any debuggee is spawned.

Evidence: [frontend dispatch](https://github.com/qompassai/lua-debug/blob/d80654e613e13b7ca79a64c038541f9386cd75b3/extension/script/frontend/proxy.lua),
[current resolver](https://github.com/qompassai/lua-debug/blob/d80654e613e13b7ca79a64c038541f9386cd75b3/extension/script/backend/master/resolve_config.lua).

### 3. Correct session sequencing and terminal negotiation

**Files:** `frontend/proxy.lua`, `frontend/debuger_factory.lua`,
`backend/master/request.lua`, `backend/master/response.lua`,
`backend/master/event.lua`, `backend/master/mgr.lua`.

- [ ] Use `internalConsole` for the first working launch. It avoids requiring
  the client to implement terminal reverse requests during the initial milestone.
- [ ] Check `supportsRunInTerminalRequest` before requesting a client terminal.
  If unsupported, use a documented compatible fallback or return a clear error.
- [ ] Track each `runInTerminal` request by its sequence ID. Currently frontend
  terminal responses are discarded. Handle success, failure, returned process
  information, and timeout; cancel the pending launch if terminal creation fails.
- [ ] Give every client-facing adapter message a valid increasing sequence
  number. Frontend-generated messages currently use `seq = 0`, while the backend
  has its own counter. Establish one outward sequence owner and translate
  `request_seq` where proxying reverse requests requires it.
- [ ] Preserve the existing suppression of the backend's duplicate initialize
  response (`__norepl`) until a tested replacement exists. Assert exactly one
  initialize response and a correctly ordered initialized event.
- [ ] Exercise initialize, launch/attach, breakpoint configuration,
  configurationDone, stopped, continued, disconnect and terminated transitions
  with a client that does not reproduce VS Code's timing.
- [ ] Define launch-versus-attach process ownership. Detach must not kill an
  independently started Neovim process by default; owned launch processes must
  be cleaned up after failed startup.
- [ ] Do not advertise support for unimplemented client reverse requests.
  Generate a capability/test matrix from handlers and tested behavior, not from
  what VS Code happens to implement.

Acceptance: a client without terminal support can debug a simple program;
a client terminal refusal ends the launch with an error and leaves no retry loop.

### 4. Remove the confirmed VS Code request-order assumption

**Files:** `backend/worker.lua`, `backend/worker/variables.lua`,
`backend/worker/evaluate.lua`, `backend/master/event.lua`,
`common/capabilities.lua`, `docs/capabilities.md`.

- [ ] Replace the special `cleanFrame()` trigger in `CMD.stackTrace` that depends
  on `startFrame == 0` and `levels == 1`. Its comment explicitly assumes VS Code's
  first request pattern. Tie invalidation to a defined execution/stop generation.
- [ ] Keep frame IDs and variable references valid for their appropriate DAP
  lifetimes. Reject stale references cleanly after resume/restart; do not clear
  valid references simply because the UI asks for another page of frames.
- [ ] Test initial stackTrace requests with omitted levels, levels=1, and larger
  page sizes, then scopes, variables and evaluation in different valid orders.
- [ ] Treat `__vscodeVariableMenuContext` as optional presentation metadata.
  Ensure ordinary values, types, references and variable mutation work without it.
- [ ] Audit capability-dependent events such as invalidated, memory and ANSI
  output. Some paths already check client flags; preserve these checks and
  inspect the remaining paths instead of blindly deleting capabilities.
- [ ] Replace the documentation legend that equates unsupported features with
  “VSCode is not implemented” with distinct adapter and client support columns.

Acceptance: stepping and variable inspection remain correct in a Neovim client
that requests a full stack immediately instead of requesting one frame first.

Evidence: [worker stack handling](https://github.com/qompassai/lua-debug/blob/d80654e613e13b7ca79a64c038541f9386cd75b3/extension/script/backend/worker.lua),
[variable presentation](https://github.com/qompassai/lua-debug/blob/d80654e613e13b7ca79a64c038541f9386cd75b3/extension/script/backend/worker/variables.lua).

## P1 — make transport, installation and failure handling dependable

### 5. Bound transport and make EOF terminate the session

**Files:** `common/protocol.lua`, `common/socket.lua`, `common/net.lua`,
`frontend/stdio.lua`, `frontend/main.lua`, `frontend/proxy.lua`.

- [ ] Introduce named, documented limits for header bytes, message bytes,
  queued bytes, outstanding reverse requests, messages processed per update,
  connection attempts and startup deadlines. Test the chosen boundary values.
- [ ] Validate Content-Length as a finite nonnegative integer within the message
  bound; reject missing/duplicate length fields and malformed JSON deterministically.
  Preserve UTF-8 byte lengths and incremental partial/multiple-message handling.
- [ ] Avoid repeated unbounded string concatenation for read/write queues; use
  bounded chunks or an indexed buffer where measurement justifies it.
- [ ] Distinguish “no bytes yet” from closed stdin in `frontend/stdio.lua`.
  Its current recv path returns an empty string for nil/zero peek results, while
  `frontend/main.lua` loops indefinitely. Verify bee's peek semantics and add an
  explicit close signal and teardown path.
- [ ] Replace unbounded connection retry behavior in `common/socket.lua` with
  a deadline, bounded retry scheduling and cancellation on client exit.
- [ ] Make writes, reads and teardown report failures. Send protocol frames only
  on stdout; send adapter diagnostics to stderr or bounded log files.
- [ ] Audit protocol debug `print` calls and the global `print = log.info`
  replacement. Debug tracing must not corrupt framing or silently hijack another
  host's printing behavior. Prefer explicit log calls in owned runtime code.
- [ ] Ensure top-level exceptions exit nonzero after reporting an actionable
  error. The frontend currently catches errors for logging without an explicit
  failure exit; a logging failure must not replace the original diagnostic.

Acceptance: split headers, coalesced messages, malformed lengths, oversized
messages, closed pipes and a missing debuggee never cause unbounded growth or
an adapter process that survives indefinitely after its client exits.

### 6. Separate immutable assets from writable runtime state

**Files:** `script/bootstrap.lua`, `frontend/main.lua`, `backend/bootstrap.lua`,
`common/ipc.lua`, `common/socket.lua`, `frontend/proxy.lua`, `script/attach.lua`,
`script/launch.lua`, `src/launcher/util/log.cpp`.

- [ ] Preserve the relative `bin/`, `script/` and `runtime/` distribution layout
  initially. Bootstrap derives its asset root from `package.cpath`, and the
  frontend derives WORKDIR from the executable path. Test installation before
  splitting these directories or symlinking the executable into another prefix.
- [ ] Add an explicit, validated asset-root override if relocatable installation
  requires one. Keep it distinct from debuggee cwd and writable state directories.
- [ ] Move client/master/worker logs out of the installation directory. They
  currently target `client.log`, `master.log` and `worker.log` under the asset root.
- [ ] Move IPC files out of `WORKDIR/tmp`; update both producers and consumers,
  including the launcher native code and the Lua-version handoff.
- [ ] Use a private session directory under a validated `$XDG_RUNTIME_DIR` for
  Unix sockets/IPC, with a securely created private temporary-directory fallback.
  Use `$XDG_STATE_HOME/lua-debug` or the documented XDG default for persistent logs.
- [ ] Set explicit permissions, unique session identifiers, log size/retention
  limits and idempotent cleanup. Avoid PID-only predictable shared-temp paths;
  validate Unix socket path length before attempting to bind.
- [ ] Change the launch bootstrap's slash-separated parameter encoding before
  passing arbitrary Unix socket paths through it. `script/launch.lua` currently
  splits the address string on `/`; structured data or safe quoting is needed.
- [ ] Default network endpoints to loopback and document unauthenticated debug
  access. Prefer private Unix sockets locally and SSH forwarding for remote use;
  do not claim loopback prevents access by other local users.

Acceptance: two simultaneous sessions run under an ordinary user from a read-only
installation, without collisions or writes into `/usr` or the checkout.

### 7. Make generated launch code and process ownership safe

**Files:** `frontend/debuger_factory.lua`, `frontend/process_inject.lua`,
`examples/attach/debugger.lua`, `script/debugger.lua`.

- [ ] Keep subprocess argv as lists and avoid shell evaluation by default.
  Separate `argsCanBeInterpretedByShell` opt-in behavior from ordinary arguments.
- [ ] Replace generated Lua source built from unescaped paths. The current
  bootstrap uses long-bracket strings and changes them into quoted strings on
  Unix; quotes, backslashes and delimiter-like text need round-trip tests.
  Use a robust Lua-string serializer such as `%q`, or pass structured bootstrap
  data separately instead of constructing executable text.
- [ ] Audit GDB/LLDB command generation separately from shell quoting. A safe argv
  does not make interpolated debugger expressions safe.
- [ ] Replace `.vscode/extensions` scans and `io.popen('ls ...')` discovery in the
  attach example with an explicit installation path or documented environment key.
- [ ] Retain child process handles until ownership is transferred or the session
  ends. Specify cleanup after spawn failure, backend connection failure, terminal
  failure, disconnect and editor shutdown.
- [ ] Prefer explicit bootstrap attach for initial Linux support. Keep GDB/LLDB
  injection optional; report ptrace/permission failures without recommending
  running Neovim as root or weakening system-wide restrictions.

### 8. Build and package the adapter independently of extension publishing

**Files:** `make.lua`, `compile/common/make.lua`, `compile/copy_extension.lua`,
`compile/common/package_json.lua`, `compile/common/config.lua`,
`compile/linux/make.lua`, `compile/common/runtime.lua`,
`compile/download_deps.lua`, `.github/workflows/build.yml`.

- [ ] Add a headless distribution target that installs the executable, bootstrap,
  shared libraries, runtime variants, scripts, JSON implementation and licenses.
  Retain VS Code packaging as a separate optional target if desired.
- [ ] Stop making extension manifest generation and copying extension images a
  requirement of the headless target. Generate a client-neutral launch/attach
  schema and make the extension manifest consume it where practical.
- [ ] Add proposed `packaging/arch/PKGBUILD` with `DESTDIR`-style staging. Keep
  the asset tree together under a suitable package-owned directory and provide
  a launcher that preserves argument boundaries and locates those assets.
- [ ] Build as an ordinary user, honor Arch build flags, and verify compatibility
  of hardening flags with the LuaJIT/Frida/native-hook components. Do not promise
  that every generic linker hardening flag is safe without running the hooks.
- [ ] Provide a runtime selection option so the first Linux package can build
  Lua 5.4 and LuaJIT without always rebuilding every bundled Lua variant.
- [ ] Preserve Lua 5.1/LuaJIT compatibility for target-loaded bootstrap code.
  Do not mechanically downgrade adapter-host code that intentionally uses the
  separate bundled modern Lua runtime.
- [ ] Audit effective language standards and configuration precedence: common
  config declares C11/C++17 and assigns debug mode, while the documented command
  requests release and launcher sources include `std::format`. Verify emitted
  compile commands before treating these as confirmed build failures.
- [ ] Make dependency retrieval pinned and checksum-verified, with explicit
  subprocess exit checks. `download_deps.lua` pins Frida 16.0.10 but currently
  ignores the value from `p:wait()` and does not verify archive digests.
- [ ] Select only the requested OS/architecture during dependency preparation;
  keep network downloads out of ordinary formatting/debugging and package build
  steps once sources have been prepared. Review Frida upgrades with ABI tests.
- [ ] Record compiler, target ABI, dependency revisions and runtime variants in a
  generated build manifest. Support clang and one chosen compiler-cache layer;
  benchmark before chaining buildcache and sccache around the same compiler.
- [ ] Update CI branch filters from `master` to the fork's actual branch policy
  (`main` at review). Pin third-party actions to reviewed commits.
- [ ] Separate build/test jobs from credentialed publishing. Current build CI
  installs `vsce`/`ovsx` and attempts marketplace publishing; add headless archives
  and run publishing only on explicitly chosen release events.

Acceptance: a clean headless build and staged Arch package work without VS Code,
Node or marketplace credentials, and can execute from a read-only prefix.

Evidence: [build workflow](https://github.com/qompassai/lua-debug/blob/d80654e613e13b7ca79a64c038541f9386cd75b3/.github/workflows/build.yml),
[dependency preparation](https://github.com/qompassai/lua-debug/blob/d80654e613e13b7ca79a64c038541f9386cd75b3/compile/download_deps.lua).

## P2 — debug Neovim's own embedded LuaJIT

This milestone is additional to using Neovim as the UI for ordinary Lua programs.
A Lua file using `vim.api` must run inside Neovim, not the bundled standalone Lua.

- [ ] Add a proposed `examples/neovim/target.lua` bootstrap and a separate Neovim
  target process. Keep the controlling editor responsive while the target's Lua
  execution is paused; do not use the same paused process as the primary UI.
- [ ] Start from an isolated `nvim --clean` target and explicit trusted bootstrap
  path; progressively test startup configuration and real plugins afterward.
- [ ] Use the existing `debugger.lua` `start`/attach machinery with a matching
  `runtime/linux-x64/luajit/luadebug.so`. Distinguish this engine library from
  `publish/bin/launcher.so`, which serves a different role.
- [ ] Verify the core against the installed Neovim LuaJIT build: architecture,
  symbol visibility, ABI, GC64 mode and any fork-specific patches. A directory
  named `luajit` does not prove compatibility; do not load a Lua 5.4 core into it.
- [ ] Prefer explicit `platform`/runtime selection in the Neovim bootstrap to
  shell-based uname discovery. Review existing `LUA_DEBUG_PLATFORM`,
  `LUA_DEBUG_CORE` and `LUA_DEBUG_PATH` behavior before adding overlapping knobs.
- [ ] Document and test JIT-state changes. The existing LuaJIT detection path
  calls `jit.off()`; explicit runtime selection may take a different path.
  Define consistent behavior and restoration semantics instead of silently
  changing global JIT state permanently.
- [ ] Keep global pcall/xpcall/coroutine patching opt-in. `setup_patch()` rewrites
  these functions; test return values, errors and interaction with other hooks,
  and provide teardown if it is used in a long-lived Neovim target.
- [ ] Test breakpoints in an ordinary module, an autocmd, `vim.schedule`, a timer
  callback, a coroutine and startup configuration. Define behavior for an idle
  target and for pause requests while native code or an event loop is running.
- [ ] Evaluate `vim.*` expressions only in the target's correct Lua state and
  context. Prevent or clearly report unsafe calls from fast-event contexts.
  Debugger worker threads must not directly call Neovim's main-thread-only APIs.
- [ ] Preserve real source names for loaded files where possible. Test
  `loadstring`, generated chunks and missing files through DAP sourceReference
  retrieval, rather than inventing filesystem paths for every frame.
- [ ] Confirm detach restores target usability; explicitly test target shutdown,
  controller shutdown, reconnect and stale frame/variable handles.

Acceptance: controller Neovim breaks inside a second Neovim process, reads a
local variable, steps, continues and detaches while both processes remain usable.

## P2 — integrate the native Neovim user experience

- [ ] Add idempotent setup and owned teardown to the existing native DAP layer.
  Use native APIs for buffers, windows, extmarks, input/select and process I/O.
- [ ] Keep breakpoints, watches, output buffers and source buffers session-aware;
  schedule UI work on the main loop and discard stale asynchronous responses.
- [ ] Implement or connect start/continue/step/pause/stop, breakpoint toggle,
  stack selection, scopes/variables, watches and evaluation. Keep advanced UI
  features separate from adapter correctness.
- [ ] Resolve source paths consistently with project cwd and sourceMaps. Keep
  Linux paths case-sensitive and test spaces, non-ASCII names and symlinked roots.
- [ ] Use Neovim terminal jobs for debuggee terminals when the client advertises
  runInTerminal support; return the matching reverse response and process data.
- [ ] Add a native health report for adapter path, executable permissions, asset
  layout, selected runtime, shared-library loading, writable session directory
  and the client API actually in use. Make discovery work explicit and bounded.
- [ ] Keep debugger hooks opt-in; loading the integration module must not attach
  to Neovim, open sockets, modify globals, or start a debuggee automatically.

## Minimal configuration fixture

This is **adapter-specific launch data for the integration tests**, not a claimed
Neovim registration API. Resolve these absolute paths before sending it. The
redundant `request` field is shown for compatibility with the current frontend;
remove dependence on it in task 2.

```lua
local launch_arguments = {
    type = 'lua',
    request = 'launch',
    name = 'Lua smoke test',
    program = '/absolute/project/main.lua',
    cwd = '/absolute/project',
    workspaceFolder = '/absolute/project',
    luaVersion = 'lua54',
    luaArch = 'x86_64',
    console = 'internalConsole',
    inject = 'none',
    arg = {},
    arg0 = {},
    env = {},
    stopOnEntry = true,
    stopOnThreadEntry = false,
    keepSessionAlive = false,
    sourceCoding = 'utf8',
    pathFormat = 'linuxpath',
    outputCapture = { 'print', 'io.write', 'stdout', 'stderr' },
    configuration = {
        variables = {
            showIntegerAsHex = false,
        },
    },
}
```

Current adapter command: `/absolute/lua-debug/publish/bin/lua-debug`, no arguments
for stdio. `--stdio`, `--root` or other new CLI flags are proposals only until
implemented; the current bootstrap interprets its first argument as a port.
Do not replace the adapter command with `/usr/bin/lua` or `nvim`.

## Verification and release gates

Add a proposed `test/dap/` wire-level harness independent of any editor and a
proposed `test/neovim/` headless integration suite. Preserve existing engine tests.

| Gate | Required cases |
| --- | --- |
| Protocol | Fragmented/coalesced messages, UTF-8 lengths, invalid lengths/JSON, EOF and output purity |
| Initialization | Minimal capabilities; no VS Code IDs, settings, request ordering or command variables |
| Launch | Lua 5.4 first, LuaJIT next; spaces/quotes/backslashes in paths and arguments |
| Configuration | Missing optional fields; malformed nested fields; command without arguments.request |
| Breakpoints | Set/replace/clear, conditional and hit-count breakpoints, logpoints |
| Execution | Entry stop, continue, next, stepIn, stepOut, pause, exception reporting |
| Inspection | Multiple stack paging orders, scopes, variable paging, evaluate, stale references |
| Terminals | Capability absent, reverse request rejected, terminal exit, startup timeout |
| Attach | Explicit bootstrap, connection direction, failed endpoint, detach without killing target |
| Neovim target | Embedded LuaJIT, scheduled/autocmd/coroutine callbacks, independent controller |
| Lifecycle | Client crash, target crash, repeated sessions, cancellation, no orphaned resources |
| Installation | Read-only prefix, unprivileged user, two concurrent sessions, XDG directories |
| Packaging | Clean build, selected runtimes, verified dependencies, no mandatory extension publishing |

- [ ] Make the first release gate a complete stdio session: initialize, launch,
  initialized event, breakpoint configuration, configurationDone, breakpoint
  stop, stack/scopes/variables, continue and clean disconnect.
- [ ] Add fault-injection tests for every owned resource and asynchronous boundary
  changed by the port. Keep timeouts and fixture sizes explicit in the tests.
- [ ] Add headless Neovim integration CI alongside the adapter protocol harness;
  avoid tests that merely duplicate the implementation's assumptions.
- [ ] Run LuaJIT syntax checks only on target/Neovim-loaded LuaJIT code, and use
  the correct host runtime for adapter/build scripts. Run static checks with
  explicit runtime-specific globals and types, not blanket diagnostic disables.
- [ ] Preserve legal notices for the engine and bundled dependencies; document
  fork changes and license/package contents when redistributing runtimes.
- [ ] Update `README.md`, `docs/DebuggerInit.md`, `docs/capabilities.md`, and
  standalone/attach examples with Neovim and terminal-client instructions.

## Suggested implementation order

1. Verify the client API and add a stdio handshake test.
2. Fix frontend dispatch, normalize config, and make internalConsole launch work.
3. Fix sequence/reverse-response handling and frame/reference lifetimes.
4. Bound transport and implement EOF, timeout and failure cleanup.
5. Separate assets from state, then stage an installable headless package.
6. Add native Neovim UI integration for ordinary Lua programs.
7. Prove a separate Neovim target works with the matching LuaJIT core.
8. Add optional terminal, remote and injection paths after the basic gates pass.

The core port is DAP interoperability, configuration and packaging. Rewriting the
engine, removing every occurrence of the word VSCode, adding unsupported advanced
capabilities, or converting all bundled code to LuaJIT syntax are not prerequisites.

Protocol reference: [DAP overview](https://microsoft.github.io/debug-adapter-protocol/overview)
and [specification](https://microsoft.github.io/debug-adapter-protocol/specification).
Neovim baseline to inspect: [upstream runtime modules](https://github.com/neovim/neovim/tree/master/runtime/lua/vim).
