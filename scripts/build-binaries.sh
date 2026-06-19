#!/usr/bin/env bash
# Cross-build the in-FC binaries (tabbify-codeservice + tabbify-broker) as static
# musl executables for the target arch, into ./bin/ for the Docker build to COPY.
#
# Usage: ARCH=x86_64|aarch64 scripts/build-binaries.sh
#
# The two source crates live as SIBLING repos at the workspace root:
#   ../tabbify-codeservice  ../tabbify-broker  (+ ../tabbify-workspace-contract)
#
# On a native Linux runner (CI) `cargo build --target *-linux-musl` links with
# the toolchain's own musl support and needs no extra flags. On a cross host
# (e.g. macOS dev box) a `<arch>-linux-musl-gcc` cross-linker must be on PATH
# (brew install FiloSottile/musl-cross/musl-cross); when present we auto-wire it
# (see scripts/lib-cross.sh) so the SAME script builds on both.
set -euo pipefail

ARCH="${ARCH:-x86_64}"
TARGET="${ARCH}-unknown-linux-musl"
HERE="$(cd "$(dirname "$0")/.." && pwd)"
WS_ROOT="$(cd "$HERE/.." && pwd)"

# shellcheck source=scripts/lib-cross.sh
. "$HERE/scripts/lib-cross.sh"

rustup target add "$TARGET" >/dev/null 2>&1 || true
wire_cross_linker "$ARCH"
mkdir -p "$HERE/bin"

build() {
  local crate="$1" binname="$2"
  echo "build-binaries: building $crate ($TARGET)"
  ( cd "$WS_ROOT/$crate" && cargo build --release --target "$TARGET" --bin "$binname" )
  cp "$WS_ROOT/$crate/target/$TARGET/release/$binname" "$HERE/bin/$binname"
  chmod 0755 "$HERE/bin/$binname"
}

build tabbify-codeservice tabbify-codeservice
build tabbify-broker      tabbify-broker

echo "build-binaries: binaries in $HERE/bin:"
ls -l "$HERE/bin"
