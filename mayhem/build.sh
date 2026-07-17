#!/usr/bin/env bash
#
# mayhem/build.sh — build h264bitstream's fuzz harness + standalone reproducer,
# plus the upstream functional test suite (the golden-output tests from
# Makefile.unix's `test:` target), all inside the commit image.
set -euo pipefail

[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer}"
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${CC:=clang}" ; : "${CXX:=clang++}" ; : "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
: "${MAYHEM_JOBS:=$(nproc)}"
: "${COVERAGE_FLAGS=}"
export SANITIZER_FLAGS DEBUG_FLAGS CC CXX LIB_FUZZING_ENGINE MAYHEM_JOBS COVERAGE_FLAGS

cd "$SRC"

LIB_SRCS="h264_nal.c h264_sei.c h264_stream.c"

# 1) Build the library itself with sanitizers + DWARF<4 so the FUZZED code is
#    instrumented. Two flavours:
#      - fuzz:   + SanitizerCoverage (-fsanitize=fuzzer-no-link) so libFuzzer /
#                Mayhem get edge coverage over the LIBRARY, not just the harness.
#      - repro:  sanitizers only (the standalone run-once driver provides no
#                coverage runtime, so no fuzzer instrumentation there).
rm -rf fuzzobj reproobj
mkdir -p fuzzobj reproobj
for c in $LIB_SRCS; do
    base="$(basename "${c%.c}").o"
    $CC $SANITIZER_FLAGS $DEBUG_FLAGS -fsanitize=fuzzer-no-link -std=c99 -I"$SRC" -c "$SRC/$c" -o "fuzzobj/$base"
    $CC $SANITIZER_FLAGS $DEBUG_FLAGS -std=c99 -I"$SRC" -c "$SRC/$c" -o "reproobj/$base"
done
ar rcs fuzzobj/libh264bitstream.a fuzzobj/*.o
ar rcs reproobj/libh264bitstream.a reproobj/*.o

# 2) Harness — fuzzer binary (coverage-instrumented lib) + standalone (run-once) reproducer.
#    Both link mayhem/lsan_off.c, the build-time LeakSanitizer off-switch (SPEC §6.2 item 15).
$CC $SANITIZER_FLAGS $DEBUG_FLAGS -fsanitize=fuzzer-no-link -std=c99 $LIB_FUZZING_ENGINE \
    "$SRC/mayhem/fuzz_h264.c" "$SRC/mayhem/lsan_off.c" -I"$SRC" fuzzobj/libh264bitstream.a -lm \
    -o /mayhem/fuzz_h264

$CC $SANITIZER_FLAGS $DEBUG_FLAGS -std=c99 "$STANDALONE_FUZZ_MAIN" \
    "$SRC/mayhem/fuzz_h264.c" "$SRC/mayhem/lsan_off.c" -I"$SRC" reproobj/libh264bitstream.a -lm \
    -o /mayhem/fuzz_h264-standalone

# 3) Test suite — build h264_analyze with the project's NORMAL toolchain/flags
#    (gcc, as in Makefile.unix/autotools; clean, no sanitizers) so mayhem/test.sh
#    only RUNS the golden-output oracle. The committed samples/*.out goldens were
#    generated with gcc; clang -O2 diverges on one exp-Golomb value.
TEST_CC=gcc
rm -f oracle/*.o
mkdir -p oracle
for c in $LIB_SRCS; do
    obj="oracle/$(basename "${c%.c}").o"
    $TEST_CC -O2 $COVERAGE_FLAGS -std=c99 -I"$SRC" -c "$SRC/$c" -o "$obj"
done
ar rcs oracle/libh264bitstream.a oracle/*.o
$TEST_CC -O2 $COVERAGE_FLAGS -std=c99 -I"$SRC" "$SRC/h264_analyze.c" \
    oracle/libh264bitstream.a -lm -o /mayhem/h264_analyze
