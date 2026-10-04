# Architectural Decisions — moonwalk

## Self-improvement loop (standing)

**Decision**: If Moonwalk itself is at fault, fix it, rebuild, republish,
and re-run. Do not work around debugger bugs.

**Context**: Moonwalk is the debugger for all Lua work. A broken debugger
produces false results.

## Test-branch push auth (standing)

**Decision**: Moonwalk-only fixes may push to `qompassai/moonwalk@test`
without re-asking.

**Consequence**: Diver pushes and main promotions still require explicit
confirmation. Keep moonwalk changes scoped to moonwalk.
