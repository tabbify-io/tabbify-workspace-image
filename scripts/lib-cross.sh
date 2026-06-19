#!/usr/bin/env bash
# Sourceable cross-build helpers shared by scripts/build-binaries.sh and the unit
# test (tests/build_helper_test.sh). Pure functions only — no side effects on
# source so they are safe to unit-test.

# musl_target ARCH -> "<arch>-unknown-linux-musl"
musl_target() {
  printf '%s-unknown-linux-musl' "$1"
}

# cross_linker_name ARCH -> "<arch>-linux-musl-gcc" (the brew musl-cross binary).
cross_linker_name() {
  printf '%s-linux-musl-gcc' "$1"
}

# cargo_linker_var TARGET -> "CARGO_TARGET_<TARGET-UPPERCASED>_LINKER"
# cargo upper-cases the target and replaces '-' with '_'.
cargo_linker_var() {
  local target="$1" upper
  upper="$(printf '%s' "$target" | tr 'a-z-' 'A-Z_')"
  printf 'CARGO_TARGET_%s_LINKER' "$upper"
}

# cc_var TARGET -> "CC_<target-with-underscores>"
cc_var() {
  printf 'CC_%s' "${1//-/_}"
}

# wire_cross_linker ARCH: export the cargo/cc env vars IFF a cross musl-gcc for
# ARCH is on PATH (no-op on a native Linux runner). Echoes what it did.
wire_cross_linker() {
  local arch="$1"
  local target cross
  target="$(musl_target "$arch")"
  cross="$(cross_linker_name "$arch")"
  if command -v "$cross" >/dev/null 2>&1; then
    export "$(cargo_linker_var "$target")=$cross"
    export "$(cc_var "$target")=$cross"
    echo "lib-cross: using cross musl linker $cross"
  else
    echo "lib-cross: no $cross on PATH — assuming native musl toolchain"
  fi
}
