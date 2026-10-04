# Patterns — moonwalk

## Debugging Lua

- Headless Neovim nightly with Matt's latest diver config.
- Skill: `~/workspace/skills/moonwalk-debug/SKILL.md`.
- Upstream PRs are hand-adapted (not cherry-picked) — verify behavior,
  don't trust the diff alone.

## Repomap (codebase map for agents)

One-shot generation (no flake wiring in this repo):

```
nix run github:qompassai/nix?dir=repomap -- /path/to/repo --budget 15000 --out .repomap.txt
```

`.repomap.txt` is a derived artifact — gitignore it, never commit it.
For automatic regeneration on `nix develop`, wire the flake input per
github.com/qompassai/nix/tree/main/repomap/README.md.
