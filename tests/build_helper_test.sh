#!/usr/bin/env bash
# Unit test for scripts/lib-cross.sh — the pure cross-build env-derivation logic.
# No docker / no cargo: asserts the exact env-var names cargo/cc look for, so a
# rename of the linker convention is caught here, not at build time.
set -euo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
. "$HERE/scripts/lib-cross.sh"

fail=0
check() { # check <label> <actual> <expected>
  if [ "$2" = "$3" ]; then
    echo "ok: $1"
  else
    echo "FAIL: $1 — got '$2' want '$3'"; fail=1
  fi
}

check "musl_target x86_64"  "$(musl_target x86_64)"  "x86_64-unknown-linux-musl"
check "musl_target aarch64" "$(musl_target aarch64)" "aarch64-unknown-linux-musl"

check "cross_linker_name x86_64"  "$(cross_linker_name x86_64)"  "x86_64-linux-musl-gcc"
check "cross_linker_name aarch64" "$(cross_linker_name aarch64)" "aarch64-linux-musl-gcc"

check "cargo_linker_var x86_64" \
  "$(cargo_linker_var x86_64-unknown-linux-musl)" \
  "CARGO_TARGET_X86_64_UNKNOWN_LINUX_MUSL_LINKER"
check "cargo_linker_var aarch64" \
  "$(cargo_linker_var aarch64-unknown-linux-musl)" \
  "CARGO_TARGET_AARCH64_UNKNOWN_LINUX_MUSL_LINKER"

check "cc_var x86_64" \
  "$(cc_var x86_64-unknown-linux-musl)" \
  "CC_x86_64_unknown_linux_musl"

# wire_cross_linker is a no-op (just logs) when the cross-gcc is absent — assert
# it does not export when PATH has no matching linker.
( PATH="/nonexistent" wire_cross_linker x86_64 >/dev/null 2>&1
  if [ -n "${CARGO_TARGET_X86_64_UNKNOWN_LINUX_MUSL_LINKER:-}" ]; then
    echo "FAIL: wire_cross_linker exported with no cross-gcc on PATH"; exit 1
  fi
  echo "ok: wire_cross_linker no-ops without a cross-gcc"
) || fail=1

[ "$fail" = 0 ] && echo "ALL BUILD-HELPER TESTS PASSED" || { echo "BUILD-HELPER TESTS FAILED"; exit 1; }
