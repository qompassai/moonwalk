# Current Work — moonwalk

Lua DAP debugger. Self-improvement loop: if Moonwalk itself is at fault,
fix it, rebuild, republish, and re-run.

## Active (2026-10-12)

- Linux build GREEN on primo: vendored gumpp was missing its
  src/internal/ headers (swallowed by 3rd/frida_gum/.gitignore *.h/*.c
  rules when the submodule was flattened); restored from fesily/gumpp
  bd7de63 (the exact snapshot the vendored sources match) and the
  gitignore exceptions fixed. Clean rebuild: 497/497, DAP initialize
  answered by publish/bin/moonwalk.
- Arch regex truncation fixed in compile/common/frida.lua and
  compile/test/make.lua ([%w]+ stopped at the underscore in x86_64).
- Test build: 4/5 targets build+link (test_frida, test_symbol,
  test_delayload, testwaitdll). test_thunk still fails to link: its
  rule lacks the luadbg compile environment (onelua exports
  luadbg_-prefixed API; thunk_create_allocf selection differs).
  Harness run: delayload/symbol rc=0, frida interceptor test ran;
  testwaitdll exits 255 bare (needs launcher+module argv; driven by
  test/waitdll.lua in the full flow).
- upstream-prs: LANDED. The branch no longer exists; its PR
  adaptations are in origin/main via 6c38cec. Sandbox clone
  ~/workspace/repos/moonwalk is stale (local main behind 10, local
  test behind 1, zero unpushed commits).

## Standing rules

- Moonwalk-only fixes are push-authorized to `qompassai/moonwalk@test`
  (no re-asking). Diver pushes and any main promotion still need
  per-push confirmation.
- Skill: `~/workspace/skills/moonwalk-debug/SKILL.md`.
- Always run against Owner's most up-to-date Neovim config.
