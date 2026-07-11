#!/usr/bin/env bash
#
# unsafe-libyaml/mayhem/build.sh — build dtolnay/unsafe-libyaml's cargo-fuzz targets as sanitized
# libFuzzer binaries, replicating OSS-Fuzz's Rust path (infra/base-images/base-builder/compile +
# projects/unsafe-libyaml/build.sh which runs `cargo fuzz build` and copies load/parse/scan).
#
# unsafe-libyaml is a pure-Rust YAML parser (libyaml transliterated to Rust by c2rust). cargo-fuzz
# drives the build:
#   - it provides its own libFuzzer runtime (the produced binary IS a libFuzzer target — Mayhem
#     runs it directly via `libfuzzer: true`);
#   - ASan is enabled the Rust way, through RUSTFLAGS `-Zsanitizer=address` (NOT clang's
#     $SANITIZER_FLAGS / CFLAGS — those don't apply to rustc), which is exactly what OSS-Fuzz's
#     `compile` sets for FUZZING_LANGUAGE=rust. nightly is required for `-Zsanitizer`.
#
# Targets (fuzz/fuzz_targets/*.rs — all three from the repo + OSS-Fuzz build.sh):
#   scan   — drives yaml_parser_scan over raw input bytes (tokenizer).
#   parse  — drives yaml_parser_parse over raw input bytes (event stream).
#   load   — drives yaml_parser_load over raw input bytes (document tree).
# Each consumes a raw &[u8] YAML byte stream.
set -euo pipefail

# clang rejects SOURCE_DATE_EPOCH='' — must be unset or a valid integer (kept for parity even though
# the Rust build doesn't invoke clang directly; cargo's cc-built deps might).
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

: "${MAYHEM_JOBS:=$(nproc)}"
export MAYHEM_JOBS
# cargo-fuzz has no --jobs flag; cargo reads parallelism from CARGO_BUILD_JOBS.
export CARGO_BUILD_JOBS="$MAYHEM_JOBS"

# $RUST_DEBUG_FLAGS threads DWARF < 4 debug info through the fuzz build (§6.2 item 10).
# Uses -C llvm-args=--dwarf-version=2 to force DWARF 2 via LLVM on the project's Rust code.
# clang-19 / LLVM defaults to DWARF 5; Mayhem triage cannot read DWARF >= 4.
: "${RUST_DEBUG_FLAGS:=-C debuginfo=2 -C force-frame-pointers=yes -C llvm-args=--dwarf-version=2}"

cd "$SRC"

# ── DWARF < 4 enforcement (§6.2 item 10) ────────────────────────────────────────────────────────
# Rust's nightly ASan runtime (librustc-nightly_rt.asan.a) is compiled with LLVM's DWARF 5.
# It is linked BEFORE the project code, so without intervention the first CU in the binary's
# .debug_info would be DWARF 5, failing the verify-repo DWARF < 4 check.
# Fix: strip the debug sections from the ASan archive ONCE (idempotent: stripping an already-stripped
# archive is a no-op). The stripped .a stays in the image, so the offline PATCH re-run sees the same
# file and the first .debug_info CU is then DWARF 2 from our project code.
ASAN_RT="$(find "$RUSTUP_HOME/toolchains" -name "librustc-nightly_rt.asan.a" 2>/dev/null | head -1)"
if [ -n "$ASAN_RT" ] && [ -f "$ASAN_RT" ]; then
    echo "Stripping debug info from Rust ASan runtime to enforce DWARF < 4: $ASAN_RT"
    objcopy --strip-debug "$ASAN_RT"
fi

# libfuzzer-sys compiles libFuzzer from C++ via the cc crate; force DWARF 3 so those CUs also
# satisfy the check (the cc crate respects CFLAGS/CXXFLAGS).
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
export CFLAGS="${CFLAGS:+$CFLAGS }${DEBUG_FLAGS}"
export CXXFLAGS="${CXXFLAGS:+$CXXFLAGS }${DEBUG_FLAGS}"

# The cargo-fuzz crate lives in fuzz/ (cargo-fuzz convention).
FUZZ_TARGETS=(scan parse load)
TRIPLE="x86_64-unknown-linux-gnu"

# Replicate OSS-Fuzz `compile` RUSTFLAGS for a libFuzzer+ASan Rust build. cargo-fuzz sets the ASan
# flag itself by default, but we set it explicitly so the behavior is pinned and visible. `--cfg
# fuzzing` matches what libfuzzer-sys expects. RUST_DEBUG_FLAGS adds DWARF 2 debug info.
export RUSTFLAGS="${RUSTFLAGS:-} --cfg fuzzing -Zsanitizer=address ${RUST_DEBUG_FLAGS}"

echo "=== cargo fuzz build (image-default nightly toolchain, ASan via RUSTFLAGS) ==="
echo "RUSTFLAGS=$RUSTFLAGS"

# `-O` mirrors OSS-Fuzz's build.sh (release w/ opt). cargo-fuzz reads the targets from
# fuzz/Cargo.toml. We build per-target so a single bad target doesn't mask the others, and so each
# binary path is deterministic.
for t in "${FUZZ_TARGETS[@]}"; do
  echo "--- building fuzz target: $t ---"
  # Use the image's DEFAULT toolchain (the Dockerfile pins it to the required nightly); a `+toolchain`
  # override would make rustup try to install a different channel into the read-only shared /opt/rust.
  cargo fuzz build -O "$t"
  bin="$SRC/fuzz/target/$TRIPLE/release/$t"
  if [ ! -x "$bin" ]; then
    echo "ERROR: expected fuzz binary not found at $bin" >&2
    exit 1
  fi
  cp "$bin" "/mayhem/$t"
  echo "built /mayhem/$t"
done

echo "build.sh complete:"
ls -la /mayhem/scan /mayhem/parse /mayhem/load 2>&1 || true
