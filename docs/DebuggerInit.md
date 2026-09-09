### Initialization Flow

A brief overview of several ways to load the `luadebug` debugger.

All parameters from the VS Code frontend are passed in full to the Lua Debug proxy process. That process is responsible for loading `lua-debug.so` / `lua-debug.dll` into the Lua virtual-machine environment.

Parameter delivery occurs in two stages. During initialization, only some parameters are currently passed. In the second stage, after the debugger has loaded, all parameters are passed in the DAP protocol's `initialized` message.

## Launch

1. The application supports Lua's standard `-e` argument.
2. Injector.

## Attach

1. Actively connect to the debugger.
2. Injector.

### Active Connection

Call `dofile debugger.lua` directly in the source code.

## Details

### `-e`

Pass startup parameters in a string using `DBG 'address[/ansi]/luaversion'`.

Currently, only three parameters can be passed: `address`, `utf8`, and `luaversion`.

### Injector

Use the injector to load the `attach_lua` function as the main entry point, which ultimately mounts `attach.lua`.

Parameters are passed through `ipc_send_luaversion`.

In practice, only the `luaversion` parameter can be passed.
