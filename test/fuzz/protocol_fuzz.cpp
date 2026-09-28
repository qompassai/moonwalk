//===-- protocol_fuzz.cpp -------------------------------------------*- C++ -*-===//
//
// libFuzzer target for the moonwalk DAP wire framing layer.
//
// WHAT IT TESTS
//   Arbitrary bytes are fed to the framing layer in 1-4 fragments (simulated
//   pipe/TCP fragmentation). The documented contract under test comes from
//   extension/script/common/protocol.lua and its own doc comment:
//     * frames are `Content-Length: <bytes>\r\n\r\n` + JSON payload
//     * FRAME_MAX = 16 MiB: larger declared lengths are rejected at the
//       header; the reassembly buffer can never grow without bound
//     * HEADER_MAX = 8 KiB: no `\r\n\r\n` in the first 8 KiB means "not DAP"
//     * malformed framing NEVER throws: zero/negative/non-integer/oversized
//       lengths and non-DAP bytes are dropped and return nil
//     * RECOVERY: "one bad frame cannot kill the adapter" -- after arbitrary
//       hostile input, subsequently fed valid frames must still be delivered
//
// KNOWN FINDING (verified 2026-09-28 against the real protocol.lua with
// Lua 5.4.8): the recovery contract is CURRENTLY VIOLATED. A chunk shaped
// `oops\r\n\r\n{separator-free bytes}` -- i.e. a `\r\n\r\n` followed by
// non-header bytes with no separator -- permanently desyncs the stream:
// the resync path skips past the bad separator but buffers the trailing
// non-header bytes, and every later valid frame then fails the
// "starts with Content-Length: " prefix check and is eaten as garbage.
// Repro: feed "oops\r\n\r\n{bare-body-no-separator}", then valid frames:
// 0/5 delivered, forever. The same-read resync (garbage AND a valid frame
// in one recv call, cf. test/dap/corpus/garbage_prefix.bin) still works;
// the wedge needs the garbage to arrive in an earlier read than the frame.
// Impact: one malformed chunk from a buggy/malicious client wedges the
// session -- every later request times out. This target TRAPS on the wedge
// (message: "framing layer wedged"), against the stub AND, once wired,
// against the real code, until the adapter is fixed.
//
// HOW TO BUILD (once the repo builds)
//   clang++ -std=c++17 -fsanitize=fuzzer,address protocol_fuzz.cpp -o protocol_fuzz
//   ./protocol_fuzz -max_len=65536 test/dap/corpus/
//   (the corpus dir seeds are valid_frame.bin, garbage_prefix.bin,
//   malformed_json_frame.bin)
//
// WIRING REQUIRED -- read before trusting a green run:
//   The real framing layer lives in Lua (extension/script/common/protocol.lua
//   `recv`). This file ships with a REFERENCE STUB (below) that mirrors the
//   CURRENT code line-for-line (including the wedge described above) so the
//   target compiles and runs TODAY. A green stub run proves the *harness
//   logic* (chunking, bounds checks, recovery assertions), NOT the adapter.
//   To test the real code, replace the stub body of MoonwalkFeedFraming()
//   with a call into the built native runtime that forwards `data[0, size)`
//   to the Lua `recv` reassembly state. Report back:
//     frame_complete = whether recv returned a payload,
//     buffered_bytes = current size of the reassembly buffer,
//     pending_bytes  = s.length ? s.length - #s.bytes : 0
//                      (bytes still owed to a declared Content-Length),
//     threw          = whether the Lua call had to be pcall-rescued
//                      (must never happen per the documented contract).
//   Delete the MOONWALK_FUZZ_REFERENCE_STUB marker when you do.
//
// Do NOT invent native C++ APIs for the adapter here: the only coupling
// point is the documented function name MoonwalkFeedFraming.
//===----------------------------------------------------------------------===//

#include <cstddef>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <string>
#include <vector>

// Documented protocol constants (extension/script/common/protocol.lua).
static const size_t kFrameMax = 16u * 1024u * 1024u;  // 16 MiB
static const size_t kHeaderMax = 8192;                // 8 KiB

namespace harness {

struct FeedResult {
    bool frame_complete;   // a full frame payload emerged from this feed
    size_t buffered_bytes; // bytes currently held in reassembly state
    size_t pending_bytes;  // >0 iff a Content-Length was accepted and its
                           // body is still short this many bytes
    bool threw;            // an error escaped the layer (must never happen)
};

//===-- WIRING POINT ------------------------------------------------------===//
// Feed `size` bytes into the framing layer's reassembly state.
//
// REAL wiring (after the native build exists): forward the bytes to the Lua
// `recv` in extension/script/common/protocol.lua via the built runtime and
// fill in FeedResult as documented in the file header.
//
// REFERENCE STUB (active now): a line-for-line model of the CURRENT Lua
// `recv`, wedge included. STUB SIMPLIFICATION: the real recv parses the
// length with tonumber() (accepts "0x10", "1e3", surrounding space); the
// stub accepts strict ASCII digits only. Both reject-or-accept without
// throwing, which is all the invariants below depend on.
//===----------------------------------------------------------------------===//
#define MOONWALK_FUZZ_REFERENCE_STUB 1

struct StubState {
    std::string bytes;
    size_t cursor = 0;  // consumed prefix; avoids O(n^2) front-erases
    bool has_length = false;
    size_t length = 0;
};

static StubState g_stub;

static size_t buffered(const StubState& s) { return s.bytes.size() - s.cursor; }

static void compact(StubState& s) {
    if (s.cursor == 0) return;
    if (s.cursor >= s.bytes.size())
        s.bytes.clear();
    else
        s.bytes.erase(0, s.cursor);
    s.cursor = 0;
}

FeedResult MoonwalkFeedFraming(const uint8_t* data, size_t size) {
#ifdef MOONWALK_FUZZ_REFERENCE_STUB
    g_stub.bytes.append(reinterpret_cast<const char*>(data), size);
    bool complete = false;
    for (;;) {
        if (g_stub.has_length) {
            if (g_stub.length <= buffered(g_stub)) {
                g_stub.cursor += g_stub.length;
                g_stub.has_length = false;
                complete = true;
                continue;
            }
            break;
        }
        size_t pos = g_stub.bytes.find("\r\n\r\n", g_stub.cursor);
        if (pos == std::string::npos) {
            if (buffered(g_stub) > kHeaderMax) {
                g_stub.bytes.clear();
                g_stub.cursor = 0;
            }
            break;
        }
        size_t rel = pos - g_stub.cursor;  // 0-based offset of separator
        bool ok = rel > 15 &&
                  g_stub.bytes.compare(g_stub.cursor, 16, "Content-Length: ") == 0 &&
                  pos > g_stub.cursor + 16;
        unsigned long long length = 0;
        if (ok) {
            for (size_t i = g_stub.cursor + 16; i < pos; ++i) {
                char c = g_stub.bytes[i];
                if (c < '0' || c > '9') {
                    ok = false;
                    break;
                }
                length = length * 10 + (unsigned)(c - '0');
                if (length > kFrameMax) break;
            }
            ok = ok && length >= 1 && length <= kFrameMax;
        }
        // Malformed: skip past the bad separator and rescan (mirrors the
        // real recv, including its cross-read desync behavior -- see the
        // KNOWN FINDING note in the file header).
        g_stub.cursor = pos + 4;
        if (ok) {
            g_stub.has_length = true;
            g_stub.length = (size_t)length;
        } else {
            g_stub.has_length = false;
        }
    }
    if (g_stub.cursor > (1u << 20)) compact(g_stub);
    size_t avail = buffered(g_stub);
    size_t pending =
        (g_stub.has_length && g_stub.length > avail) ? g_stub.length - avail : 0;
    return FeedResult{complete, avail, pending, false};
#else
    // ---- real wiring goes here; see the header comment ----
    (void)data;
    (void)size;
    return FeedResult{false, 0, 0, false};
#endif
}

void MoonwalkResetFraming() {
#ifdef MOONWALK_FUZZ_REFERENCE_STUB
    g_stub = StubState();
#endif
}

}  // namespace harness

// A known-good frame (mirrors test/dap/corpus/valid_frame.bin content).
static std::vector<uint8_t> GoodFrame() {
    const char* json = "{\"type\":\"response\",\"seq\":2,\"request_seq\":1,"
                       "\"command\":\"initialize\",\"success\":true}";
    std::string frame = "Content-Length: " + std::to_string(strlen(json)) +
                        "\r\n\r\n" + json;
    return std::vector<uint8_t>(frame.begin(), frame.end());
}

// Feed bytes, enforcing the no-throw and bounded-buffer invariants.
static harness::FeedResult checked_feed(const uint8_t* data, size_t size) {
    harness::FeedResult r;
    try {
        r = harness::MoonwalkFeedFraming(data, size);
    } catch (...) {
        fprintf(stderr, "protocol_fuzz: exception escaped the framing layer\n");
        __builtin_trap();
    }
    if (r.threw) {
        fprintf(stderr, "protocol_fuzz: error escaped the framing layer\n");
        __builtin_trap();
    }
    // INVARIANT: the reassembly buffer stays bounded no matter what.
    if (r.buffered_bytes > kFrameMax + kHeaderMax + size) {
        fprintf(stderr, "protocol_fuzz: unbounded reassembly buffer: %zu\n",
                r.buffered_bytes);
        __builtin_trap();
    }
    return r;
}

extern "C" int LLVMFuzzerTestOneInput(const uint8_t* data, size_t size) {
    if (size == 0) return 0;
    harness::MoonwalkResetFraming();

    // Split the input into 1-4 fragments at fuzzer-derived offsets to
    // simulate pipe/TCP fragmentation (see corpus/split_positions.txt).
    size_t nfrag = 1 + (size > 3 ? data[0] % 4 : 0);
    size_t cuts[3] = {0, 0, 0};
    for (size_t i = 0; i + 1 < nfrag && i < 3; ++i) {
        cuts[i] = 1 + (data[1 + i] % (size ? size : 1));
    }
    size_t start = 0;
    for (size_t f = 0; f < nfrag; ++f) {
        size_t end = (f + 1 < nfrag) ? cuts[f] % (size + 1) : size;
        if (end < start) end = start;
        if (end > size) end = size;
        checked_feed(data + start, end - start);
        start = end;
    }

    // INVARIANT (recovery): one bad chunk must not kill the adapter. After
    // arbitrary hostile input, valid frames must still be deliverable.
    // A declared-but-incomplete Content-Length is legitimate waiting, not a
    // wedge: its owed bytes are paid with filler first. A valid frame eaten
    // with nothing pending, twice in a row, is a deterministic wedge: the
    // eater state (stale separator-free bytes buffered, no declared length)
    // is a fixed point, so the third attempt cannot succeed either.
    std::vector<uint8_t> good = GoodFrame();
    bool recovered = false;
    for (int attempt = 0; attempt < 3 && !recovered; ++attempt) {
        harness::FeedResult r = checked_feed(good.data(), good.size());
        if (r.frame_complete) {
            recovered = true;
            break;
        }
        if (r.pending_bytes > 0) {
            std::vector<uint8_t> pay(r.pending_bytes, uint8_t('x'));
            pay.insert(pay.end(), good.begin(), good.end());
            r = checked_feed(pay.data(), pay.size());
            recovered = r.frame_complete;
            break;
        }
    }
    if (!recovered) {
        fprintf(stderr, "protocol_fuzz: framing layer wedged -- valid frames "
                        "are no longer delivered after hostile input\n");
        __builtin_trap();
    }
    return 0;
}
