//===-- undump_fuzz.cpp ---------------------------------------------*- C++ -*-===//
//
// libFuzzer target for the moonwalk bytecode undumper.
//
// WHAT IT TESTS
//   Mutated Lua bytecode (arbitrary bytes, biased toward plausible dump
//   headers) is fed to the undumper. The contract under test:
//     * the undumper NEVER throws on hostile input -- malformed bytecode is
//       rejected with a clean error, never a crash
//     * acceptance is deterministic: the same bytes always give the same
//       verdict
//     * a valid `string.dump` header prefix mutated in only the code bytes
//       must not be mis-parsed into an unbounded allocation (output size is
//       bounded by a sane multiple of input size)
//
// The real undumper is `backend.worker.undump` (Lua; see test/undump.lua for
// the round-trip harness). It parses `string.dump` output back into a
// prototype table used for breakpoint source mapping.
//
// HOW TO BUILD (once the repo builds)
//   clang++ -std=c++17 -fsanitize=fuzzer,address undump_fuzz.cpp -o undump_fuzz
//   ./undump_fuzz -max_len=65536
//
// WIRING REQUIRED -- read before trusting a green run:
//   This file ships with a REFERENCE STUB (below) so the target compiles and
//   runs TODAY. The stub accepts only inputs starting with the Lua 5.4 dump
//   magic (`\x1bLua` + version byte 0x54) and rejects everything else without
//   throwing; that models "reject cleanly", nothing more. A green stub run
//   proves the harness logic, NOT the undumper.
//   To test the real code, replace the stub body of MoonwalkUndump() with a
//   call into the built native runtime that invokes `backend.worker.undump`
//   on the input bytes (as a Lua string) and reports (accepted, error).
//   Delete the MOONWALK_FUZZ_REFERENCE_STUB marker when you do.
//
// Do NOT invent native C++ APIs for the adapter here: the only coupling
// point is the documented function name MoonwalkUndump.
//===----------------------------------------------------------------------===//

#include <cstddef>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <string>

namespace harness {

struct UndumpResult {
    bool accepted;        // the undumper produced a prototype
    bool threw;           // an exception escaped (must never happen)
    size_t output_bytes;  // size of the produced structure rendering
};

//===-- WIRING POINT ------------------------------------------------------===//
// REAL wiring (after the native build exists): call `backend.worker.undump`
// in the built runtime with the input bytes as a Lua string; accepted=true
// when it returns a prototype table, accepted=false + error string when it
// rejects. threw must be false in both cases.
//
// REFERENCE STUB (active now): header-magic check only.
//===----------------------------------------------------------------------===//
#define MOONWALK_FUZZ_REFERENCE_STUB 1

UndumpResult MoonwalkUndump(const uint8_t* data, size_t size) {
#ifdef MOONWALK_FUZZ_REFERENCE_STUB
    // Lua 5.4 string.dump header: "\x1bLua" 0x54 0x19 0x93 "\r\n\x1a\n".
    // The stub accepts the magic and pretends to parse; everything else is
    // a clean rejection. Real parsing behavior must come from the runtime.
    static const uint8_t kMagic[] = {0x1b, 'L', 'u', 'a', 0x54};
    if (size >= sizeof(kMagic) &&
        memcmp(data, kMagic, sizeof(kMagic)) == 0) {
        // Pretend-parse: output proportional to input, never explosive.
        return UndumpResult{true, false, size * 4};
    }
    return UndumpResult{false, false, 0};
#else
    // ---- real wiring goes here; see the header comment ----
    (void)data;
    (void)size;
    return UndumpResult{false, false, 0};
#endif
}

}  // namespace harness

extern "C" int LLVMFuzzerTestOneInput(const uint8_t* data, size_t size) {
    if (size == 0) return 0;

    harness::UndumpResult r1 = harness::MoonwalkUndump(data, size);

    // INVARIANT: no exception may escape the undumper, ever.
    if (r1.threw) {
        fprintf(stderr, "undump_fuzz: exception escaped the undumper\n");
        __builtin_trap();
    }

    // INVARIANT: output stays proportional to input (no unbounded
    // allocation driven by hostile size fields in the bytecode).
    if (r1.accepted && r1.output_bytes > size * 64 + 1024) {
        fprintf(stderr, "undump_fuzz: output disproportionate to input: "
                "in=%zu out=%zu\n", size, r1.output_bytes);
        __builtin_trap();
    }

    // INVARIANT: deterministic verdict -- same bytes, same answer.
    harness::UndumpResult r2 = harness::MoonwalkUndump(data, size);
    if (r1.accepted != r2.accepted || r1.threw != r2.threw) {
        fprintf(stderr, "undump_fuzz: nondeterministic verdict\n");
        __builtin_trap();
    }
    return 0;
}
