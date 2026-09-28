//===-- source_map_fuzz.cpp -----------------------------------------*- C++ -*-===//
//
// libFuzzer target for the moonwalk source-path normalization layer.
//
// WHAT IT TESTS
//   Byte soup is mapped onto a path-ish alphabet and fed through path
//   normalization. The contract under test (from
//   extension/script/backend/worker/filesystem.lua):
//     * `source_normalize(path)` returns a normalized ABSOLUTE path with
//       forward slashes (relative inputs are resolved against the cwd)
//     * normalization NEVER throws on hostile input
//     * normalization is deterministic and idempotent:
//       normalize(normalize(p)) == normalize(p)
//     * normalization is a pure function of its input: no global state leaks
//       between calls (two interleaved inputs normalize independently)
//
// The real entry points are `backend.worker.filesystem.source_normalize`
// and `path_normalize` (Lua). Breakpoint path matching depends on this
// layer: a normalization that throws or misbehaves on hostile workspace
// paths is a debugger-integrity bug.
//
// HOW TO BUILD (once the repo builds)
//   clang++ -std=c++17 -fsanitize=fuzzer,address source_map_fuzz.cpp \
//       -o source_map_fuzz
//   ./source_map_fuzz -max_len=1024
//
// WIRING REQUIRED -- read before trusting a green run:
//   This file ships with a REFERENCE STUB (below) so the target compiles and
//   runs TODAY. The stub implements the *documented* normalization shape
//   (absolute-ize against a fixed root, split on both slash kinds, drop
//   `.`, resolve `..` without escaping the root, rejoin with `/`). A green
//   stub run proves the harness logic, NOT the adapter's Lua code.
//   To test the real code, replace the stub body of MoonwalkNormalizePath()
//   with a call into the built native runtime invoking
//   `backend.worker.filesystem.source_normalize` on the input and returning
//   the resulting string. Delete the MOONWALK_FUZZ_REFERENCE_STUB marker
//   when you do.
//
// Do NOT invent native C++ APIs for the adapter here: the only coupling
// point is the documented function name MoonwalkNormalizePath.
//===----------------------------------------------------------------------===//

#include <cstddef>
#include <cstdint>
#include <cstdio>
#include <string>
#include <vector>

namespace harness {

//===-- WIRING POINT ------------------------------------------------------===//
// REAL wiring (after the native build exists): invoke
// `backend.worker.filesystem.source_normalize` in the built runtime on
// `path` and return its result string. Must not throw: the Lua side must
// convert errors into returned strings.
//
// REFERENCE STUB (active now): documented normalization shape only.
//===----------------------------------------------------------------------===//
#define MOONWALK_FUZZ_REFERENCE_STUB 1

std::string MoonwalkNormalizePath(const std::string& path) {
#ifdef MOONWALK_FUZZ_REFERENCE_STUB
    // Fixed root stands in for fs.current_path(); the point is the shape
    // (absolute, forward slashes, `.`/`..` resolved, root-clamped), which is
    // what the documented contract promises.
    std::string p = path;
    for (char& c : p)
        if (c == '\\') c = '/';
    if (p.empty() || p[0] != '/') p = "/harness/cwd/" + p;
    std::vector<std::string> segs;
    size_t i = 0;
    while (i <= p.size()) {
        size_t j = p.find('/', i);
        if (j == std::string::npos) j = p.size();
        std::string s = p.substr(i, j - i);
        if (s.empty() || s == ".") {
            // skip
        } else if (s == "..") {
            if (!segs.empty()) segs.pop_back();  // clamped at root
        } else {
            segs.push_back(s);
        }
        i = j + 1;
    }
    std::string out;
    for (const auto& s : segs) {
        out += '/';
        out += s;
    }
    return out.empty() ? "/" : out;
#else
    // ---- real wiring goes here; see the header comment ----
    (void)path;
    return "";
#endif
}

}  // namespace harness

// Map raw fuzzer bytes onto a hostile-but-path-shaped alphabet so the
// input exercises separators, dots, drive letters, tildes, and high bytes.
static std::string ToPath(const uint8_t* data, size_t size) {
    static const char kAlphabet[] =
        "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
        "/\\.:~_- ";
    std::string out;
    out.reserve(size);
    for (size_t i = 0; i < size; ++i)
        out += kAlphabet[data[i] % (sizeof(kAlphabet) - 1)];
    // Sprinkle in raw high bytes occasionally: normalization must not choke
    // on non-UTF8 either.
    for (size_t i = 0; i < size; i += 7) {
        if (data[i] & 0x80) out += static_cast<char>(data[i]);
    }
    return out;
}

extern "C" int LLVMFuzzerTestOneInput(const uint8_t* data, size_t size) {
    if (size == 0) return 0;
    std::string path = ToPath(data, size);

    std::string n1, n2, n3;
    bool threw = false;
    try {
        n1 = harness::MoonwalkNormalizePath(path);
        n2 = harness::MoonwalkNormalizePath(path);
        n3 = harness::MoonwalkNormalizePath(n1);
    } catch (...) {
        threw = true;
    }
    // INVARIANT: normalization never throws.
    if (threw) {
        fprintf(stderr, "source_map_fuzz: exception escaped normalization\n");
        __builtin_trap();
    }

    // INVARIANT: deterministic -- same input, same output.
    if (n1 != n2) {
        fprintf(stderr, "source_map_fuzz: nondeterministic normalization\n");
        __builtin_trap();
    }

    // INVARIANT: idempotent -- normalizing twice is a fixed point.
    if (n1 != n3) {
        fprintf(stderr, "source_map_fuzz: not idempotent: %s -> %s -> %s\n",
                path.c_str(), n1.c_str(), n3.c_str());
        __builtin_trap();
    }

    // INVARIANT: result is absolute with forward slashes only.
    if (n1.empty() || n1[0] != '/' || n1.find('\\') != std::string::npos) {
        fprintf(stderr, "source_map_fuzz: bad normalized shape: %s\n",
                n1.c_str());
        __builtin_trap();
    }

    // INVARIANT: independence -- an interleaved second input does not
    // perturb the first (no hidden global state).
    std::string other = harness::MoonwalkNormalizePath("/other/x/../y");
    std::string n1_again = harness::MoonwalkNormalizePath(path);
    if (n1 != n1_again || other != "/other/y") {
        fprintf(stderr, "source_map_fuzz: global-state leak detected\n");
        __builtin_trap();
    }
    return 0;
}
