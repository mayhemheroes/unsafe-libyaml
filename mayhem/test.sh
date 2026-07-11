#!/usr/bin/env bash
#
# unsafe-libyaml/mayhem/test.sh — RUN dtolnay/unsafe-libyaml's own test suite (`cargo test`) and
# emit a CTRF summary. exit 0 iff no test failed.
#
# PATCH-grade oracle: unsafe-libyaml ships golden-output tests against the official YAML test suite
# (tests/test_parser.rs asserts the parser's event stream BYTE-EXACT against each fixture's
# `test.event`; tests/test_emitter.rs asserts emitted YAML byte-exact against `out.yaml`/`in.yaml`;
# tests/test_parser_error.rs asserts that malformed inputs are REJECTED). These compare exact
# parser/emitter output to standard fixtures, so a no-op / "exit(0)" / output-altering patch CANNOT
# pass. This script only RUNS the suite via `cargo test`; it never builds fuzz targets.
#
# Note: the suite's build script (tests/data/build.rs) downloads the pinned yaml-test-suite tarball
# (data-2020-02-11) on first run. We run `cargo test` with the crate's NORMAL flags (the
# default/stable resolution of the installed toolchain) — no sanitizer RUSTFLAGS — to keep the
# oracle honest and fast.
#
# TOOLCHAIN SNAG: dtolnay's MSRV is 1.60, but we build on a dated nightly (cargo-fuzz needs nightly
# for -Zsanitizer). nightly added a deny-by-default lint `dangerous_implicit_autorefs` that fires
# inside the crate's OWN test-suite driver binaries (src/bin/run-{parser,emitter}-test-suite.rs:
# `(*parser).field` autoref'ing a raw-pointer deref). These bins are compiled only by `cargo test`,
# never by `cargo fuzz build`, so the fuzz build is unaffected. Demote ONLY that lint to a warning
# so the suite compiles on the pinned nightly. This does NOT touch any assertion: the golden
# event-stream / emitted-YAML comparisons and the error-rejection checks run unchanged, so the
# anti-reward-hacking oracle stays fully intact.
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

: "${MAYHEM_JOBS:=$(nproc)}"
cd "$SRC"

# emit_ctrf <tool> <passed> <failed> [skipped] [pending] [other]
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

if ! command -v cargo >/dev/null 2>&1; then
  echo "cargo not available — cannot run the test suite" >&2
  emit_ctrf "cargo-test" 0 1 0; exit 2
fi

echo "=== running cargo test (unsafe-libyaml YAML test-suite golden vectors) ==="
# Use the image's DEFAULT toolchain (the Dockerfile pins it to the same nightly the fuzz build uses),
# so no `+toolchain` override — that would make rustup try to install a different channel into the
# read-only shared /opt/rust. --no-fail-fast so we count every test; RUSTFLAGS cleared so it inherits
# nothing from the sanitizer build.
out="$(RUSTFLAGS="-A dangerous_implicit_autorefs" cargo test --no-fail-fast --jobs "$MAYHEM_JOBS" 2>&1)"; rc=$?
echo "$out"

# libtest prints one line per test binary:
#   test result: ok. 12 passed; 0 failed; 0 ignored; 0 measured; 0 filtered out; ...
# Sum across all binaries.
PASSED=0; FAILED=0; IGNORED=0
while read -r p f i; do
  PASSED=$(( PASSED + p )); FAILED=$(( FAILED + f )); IGNORED=$(( IGNORED + i ))
done < <(printf '%s\n' "$out" \
  | sed -n 's/^test result:.* \([0-9][0-9]*\) passed; \([0-9][0-9]*\) failed; \([0-9][0-9]*\) ignored.*/\1 \2 \3/p')

# If we parsed no result lines, fall back to the cargo exit code (e.g. compile error).
if [ "$(( PASSED + FAILED + IGNORED ))" -eq 0 ]; then
  echo "could not parse any 'test result:' lines; using cargo exit code $rc" >&2
  [ "$rc" -eq 0 ] && { emit_ctrf "cargo-test" 1 0 0; exit 0; }
  emit_ctrf "cargo-test" 0 1 0; exit 1
fi

emit_ctrf "cargo-test" "$PASSED" "$FAILED" "$IGNORED"
