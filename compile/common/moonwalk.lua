-- Moonwalk adapter executable target (renamed from upstream lua-debug).
-- Produces publish/bin/moonwalk (moonwalk.exe on Windows).
local lm = require('luamake')

if lm.os == 'windows' then
    lm:source_set('source_inject')({
        bindir = 'publish/bin',
        includes = {
            '3rd/bee.lua',
            '3rd/bee.lua/3rd/lua55',
            '3rd/wow64ext/src',
        },
        sources = {
            'src/process_inject/windows/*.cpp',
            '3rd/wow64ext/src/wow64ext.cpp',
        },
        links = 'advapi32',
    })
end

lm:executable('moonwalk')({
    bindir = 'publish/bin/',
    deps = 'source_bootstrap',
    windows = {
        deps = 'source_inject',
        sources = {
            'compile/windows/moonwalk.rc',
        },
    },
    msvc = {
        ldflags = '/IMPLIB:$obj/moonwalk.lib',
    },
    mingw = {
        ldflags = '-Wl,--out-implib,$obj/moonwalk.lib',
    },
    linux = {
        crt = 'static',
        ldflags = '-rdynamic',
    },
    netbsd = {
        crt = 'static',
    },
    freebsd = {
        crt = 'static',
    },
    openbsd = {
        crt = 'static',
    },
})
