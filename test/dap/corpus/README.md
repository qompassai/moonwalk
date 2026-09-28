# DAP framing corpus for the moonwalk conformance harness.
#
# Files:
#   valid_frame.bin          3 valid framed messages (initialize req/resp/event)
#   split_positions.txt      documented byte offsets for fragmentation tests
#   garbage_prefix.bin       non-DAP bytes followed by one valid frame
#   bad_lengths.txt          Content-Length values that must be rejected
#   malformed_json_frame.bin correct header, body is not JSON
#
# ## Fixed PR seeds vs rotating nightly seeds
#
# Pull-request runs use `--seed 1` (the runner default). With a fixed seed,
# every case that consumes the corpus (fragmentation splits, bad-length
# selection, garbage placement) makes identical choices, so PR results are
# reproducible bit-for-bit and failures can be re-run with
# `python3 test/dap/run.py --case <id> --seed 1`.
#
# Nightly runs rotate the seed (e.g. `--seed $(date +%Y%m%d)`). A rotating
# seed explores different split positions, orderings, and interleavings of
# these corpus files on each run, widening coverage over time without
# changing any committed file. If a nightly seed finds a failure, the seed
# is printed in the summary and the artifact dir is
# `artifacts/<case>/<seed>/`, so the exact run reproduces with that seed.
#
# Rule: corpus files are stable inputs; the seed only changes how cases
# *sample* from them. Never "fix" a corpus file to make a case pass --
# fix the adapter or the case.
