# Current Work — moonwalk

Lua DAP debugger. Self-improvement loop: if Moonwalk itself is at fault,
fix it, rebuild, republish, and re-run.

## Active (2026-10-04)

- Upstream PRs #359/#360/#361 hand-adapted, pushed to origin/main as
  6c38cec7 (remote-verified). Further work on `upstream-prs` branch.
- **Gaps**: luamake build not run (no luamake on primo); #359 DAP repro
  not run.
- **Open**: Full-Neovim Moonwalk exercise of dap.entity (waits on the
  `require('dap')` dispatcher state).

## Standing rules

- Moonwalk-only fixes are push-authorized to `qompassai/moonwalk@test`
  (no re-asking). Diver pushes and any main promotion still need
  per-push confirmation.
- Skill: `~/workspace/skills/moonwalk-debug/SKILL.md`.
- Always run against Matt's most up-to-date Neovim config.
