#!/usr/bin/env bash
#
# mayhem/test.sh — RUN h264bitstream's upstream functional test suite (the
# golden-output known-answer tests from Makefile.unix's `test:` target).
# build.sh already built /mayhem/h264_analyze; this only RUNS it and diffs its
# output against the committed golden `samples/*.out` files. A no-op / exit(0)
# patch produces empty output → diff fails → test.sh fails.
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
cd "$SRC"

emit_ctrf() {
  local tool="$1" passed="$2" failed="$3" skipped="${4:-0}" pending="${5:-0}" other="${6:-0}"
  local tests=$(( passed + failed + skipped + pending + other ))
  cat > "${CTRF_REPORT:-$SRC/ctrf-report.json}" <<JSON
{
  "results": {
    "tool": { "name": "$tool" },
    "summary": {
      "tests": $tests,
      "passed": $passed,
      "failed": $failed,
      "pending": $pending,
      "skipped": $skipped,
      "other": $other
    }
  }
}
JSON
  printf 'CTRF {"results":{"tool":{"name":"%s"},"summary":{"tests":%d,"passed":%d,"failed":%d,"pending":%d,"skipped":%d,"other":%d}}}\n' \
    "$tool" "$tests" "$passed" "$failed" "$pending" "$skipped" "$other"
  [ "$failed" -eq 0 ]
}

ANALYZE=/mayhem/h264_analyze
if [ ! -x "$ANALYZE" ]; then
  echo "!! $ANALYZE missing — build.sh did not produce the test binary" >&2
  emit_ctrf "h264-golden" 0 1
  exit 1
fi

# Golden known-answer tests: parse each sample stream and diff against its
# committed reference dump (samples/<name>.out).
SAMPLES=(JM_cqm_cabac x264_test riverbed-II-360p-48961)

# NAL units whose golden dump depends on undefined behaviour, keyed "<sample>:<byte offset>".
# x264_test's P-slice at offset 838 has an exp-Golomb code with 32 leading zeros, which is out
# of range for ue(v). bs_read_ue's `(1 << i) - 1` is UB for it, and upstream's golden records
# gcc's wrapped value (memory_management_control_operation 182783, golden line 138) and the
# misparse after it. Rejecting or saturating the code is an equally correct fix and changes
# lines 138-151, so no single golden is right. The body of that one NAL is masked on both
# sides; its "!! Found NAL" header and every other NAL are still compared byte-for-byte.
# Across the three samples this is the only out-of-range ue(v) read.
UB_NALS=(x264_test:838)

# mask_ub_nals <sample>: filter stdin, dropping the body lines of that sample's UB_NALS.
mask_ub_nals() {
  local offs="" e
  for e in "${UB_NALS[@]}"; do [ "${e%%:*}" = "$1" ] && offs="$offs ${e#*:}"; done
  awk -v offs="$offs" '
    BEGIN { n = split(offs, a, " "); for (i = 1; i <= n; i++) skip[a[i]] = 1 }
    /^!! Found NAL at offset / { masked = ($6 in skip); print; next }
    !masked'
}

passed=0; failed=0
tmp="$(mktemp -d)"
for s in "${SAMPLES[@]}"; do
  in="$SRC/samples/$s.264"; ref="$SRC/samples/$s.out"
  if [ ! -f "$in" ] || [ ! -f "$ref" ]; then
    echo "SKIP $s (missing sample)"; failed=$((failed+1)); continue
  fi
  "$ANALYZE" "$in" 2>/dev/null | mask_ub_nals "$s" > "$tmp/$s.out" || true
  if diff -u <(mask_ub_nals "$s" < "$ref") "$tmp/$s.out" > "$tmp/$s.diff" 2>&1; then
    echo "PASS $s"; passed=$((passed+1))
  else
    echo "FAIL $s"; sed -n '1,20p' "$tmp/$s.diff"; failed=$((failed+1))
  fi
done
rm -rf "$tmp"

emit_ctrf "h264-golden" "$passed" "$failed"
