#ifndef LUAI_DEVENT_H
#define LUAI_DEVENT_H

#include "lua.h"

void callhook(lua_State *L, int event, BCLine line);

#define LUA_CALLHOOK(L, event, type) callhook(L, event, type)

#define LUA_ERREVENT_PANIC 0x10

#define luai_errevent_(L, errcode) LUA_CALLHOOK(L, LUA_HOOKEXCEPTION, errcode)

#define luai_errevent(L, errcode)           \
    if (G(L)->hookmask2 & LUA_MASKEXCEPTION) {  \
        switch (errcode) {                  \
        case LUA_ERRRUN:                    \
        case LUA_ERRSYNTAX:                 \
        case LUA_ERRMEM:                    \
        case LUA_ERRERR: {                  \
            luai_errevent_(L, errcode);        \
            break;                          \
        }}                                  \
    }
#endif