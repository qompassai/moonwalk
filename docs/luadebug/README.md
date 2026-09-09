> Why is `luadebug` needed?

The primary design goal of `luadebug` is to minimize the debugger's impact on the debug target as much as possible. Although `lua-debug`, like other Lua debuggers, appears to have most of its code written in Lua, that Lua code does not execute in the debug target's VM.

`luadebug` embeds a Lua 5.4 VM. Whether the debug target uses Lua 5.1 or Lua 5.4, the debugger's code always runs on the Lua 5.4 VM embedded in `luadebug`. The debugger can read and modify data in the debug target only through the APIs provided by `luadebug`. This minimizes the debugger's impact on the debug target to the greatest extent possible.

As a result, `luadebug` can be loaded separately by the debug target and by the debugger code, but the APIs it provides to each are different.
