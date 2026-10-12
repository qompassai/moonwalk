# Moonwalk Linux build restored (2026-10-12)

luamake IS on primo (~/.local/bin/luamake). The Linux build failed at
gumpp/src/signature.cpp: signature/x86.hpp includes
../internal/arch-x86/gumx86reader.h, absent from the tree.

Root cause: 3rd/frida_gum/gumpp is a flattened submodule. The parent
3rd/frida_gum/.gitignore ignores *.h and *.c (meant for downloaded
devkits), so when gumpp was flattened, src/internal/** (4 .h + 1 .c)
was silently never committed. Its one exception named a stale path
(gumpp/internal/*.c).

Fix: restored the 5 files from fesily/gumpp commit
bd7de637a9487858b9e9fe347e917a947503f14d - proven to be the vendored
snapshot by matching blob hashes of signature.cpp, interceptor.cpp,
process.cpp, objectwrapper.hpp, symbolutil.cpp simultaneously.
Gitignore exceptions corrected to gumpp/src/internal/*.c and
gumpp/src/internal/**/*.h.

Also fixed: arch extraction regex [%w]+-([%w]+) truncates x86_64 to
x86 (underscore is not in %w) in compile/common/frida.lua and
compile/test/make.lua - changed to [%w_]+. And test/symbol/gum_symbol.c
needs _GNU_SOURCE + <setjmp.h> before <frida-gum.h> (sigjmp_buf under
-std=c11).

Verified: clean rebuild 497/497 rc=0; publish/bin/moonwalk answers a
DAP initialize request; luacheck (repo config) 0/0 and stylua clean on
both edited .lua files. Test build 4/5 (test_thunk link remains - see
current.md). SCIP (scip-lua over compile/ corpus): 30 files, 995
definitions, 1945 occurrences; index.scip gitignored at repo root.
