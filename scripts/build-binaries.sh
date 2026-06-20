#!/usr/bin/env bash
# LOCAL-DEV ONLY. Cross-build the in-FC binaries (tabbify-codeservice +
# tabbify-broker) as static musl executables for the target arch, into ./bin/.
#
# NOTE: the Dockerfile is now SELF-CONTAINED — its multi-stage `binbuilder`
# stage builds these binaries from source at docker-build time, so neither
# `tcli deploy --remote` (supervisor-side `docker build`) NOR a plain local
# `docker build .` needs this script. It survives only as a fast LOCAL inner
# loop: with sibling checkouts (../tabbify-codeservice, ../tabbify-broker) it
# rebuilds just the changed crate into ./bin/, which you can then wire into an
# ad-hoc image if you want to skip the in-docker rebuild. It is NOT used by CI.
#
# Usage: ARCH=x86_64|aarch64 scripts/build-binaries.sh
#
# Where the crate sources come from (per crate, independently):
#   * LOCAL DEV: if a sibling repo exists at ../tabbify-<crate>, build it in place
#     (fast inner loop; whatever you have checked out).
#   * CI / clean host: clone the PUSHED repo at a rev-PINNED SHA into a build
#     workdir and build that. The crates git-depend on tabbify-workspace-contract
#     (and codeservice git-deps tabbify-broker), so cargo resolves those from
#     github keylessly (all repos public) — no sibling contract checkout needed.
#
# The pinned revs below are the single source of truth for the CI build. Override
# per crate via env (CODESERVICE_REV / BROKER_REV) for a coordinated re-pin.
#
# Cross-linking the musl target needs a linker that targets musl. We prefer
# cargo-zigbuild (zig ships its own musl libc + cross-linker, so NO
# `<arch>-linux-musl-gcc` is needed) — the same path tabbify-forge's release CI
# uses. When `cargo-zigbuild` is on PATH we run `cargo zigbuild`; otherwise we
# fall back to plain `cargo build` and auto-wire a brew `<arch>-linux-musl-gcc`
# cross-linker if one is present (see scripts/lib-cross.sh) for a local dev box
# that has musl-cross but not zig. CI installs zig + cargo-zigbuild (deploy.yml),
# so it always takes the zigbuild path and never needs musl-gcc.
set -euo pipefail

ARCH="${ARCH:-x86_64}"
TARGET="${ARCH}-unknown-linux-musl"
HERE="$(cd "$(dirname "$0")/.." && pwd)"
WS_ROOT="$(cd "$HERE/.." && pwd)"

# Pinned PUSHED revs (single source of truth; env-overridable for re-pin).
CODESERVICE_REV="${CODESERVICE_REV:-fa8f389eabc0e597f5d2d13f1253ce1fb2d1b278}"
BROKER_REV="${BROKER_REV:-a637582b1a65ddbcf9362ab57e5d2acc0e19b252}"

GH_BASE="${GH_BASE:-https://github.com/tabbify-io}"
WORKDIR="${WORKDIR:-$HERE/.build-src}"

# shellcheck source=scripts/lib-cross.sh
. "$HERE/scripts/lib-cross.sh"

rustup target add "$TARGET" >/dev/null 2>&1 || true
mkdir -p "$HERE/bin"

# Pick the build driver once. cargo-zigbuild needs no musl-gcc; only wire the
# brew cross-linker for the plain-`cargo build` fallback.
if command -v cargo-zigbuild >/dev/null 2>&1; then
  CARGO_BUILD_CMD="zigbuild"
  echo "build-binaries: using cargo-zigbuild (zig cross-linker, no musl-gcc needed)"
else
  CARGO_BUILD_CMD="build"
  echo "build-binaries: cargo-zigbuild not found — falling back to 'cargo build' + musl-gcc"
  wire_cross_linker "$ARCH"
fi

# resolve_src CRATE REV -> echo the dir to build in.
# Prefers a sibling checkout (local dev); else clones the pinned rev into WORKDIR.
resolve_src() {
  local crate="$1" rev="$2" sib="$WS_ROOT/$1" dst
  if [ -d "$sib/.git" ] || [ -f "$sib/Cargo.toml" ]; then
    echo "build-binaries: using local sibling $sib" >&2
    printf '%s' "$sib"
    return 0
  fi
  dst="$WORKDIR/$crate"
  echo "build-binaries: cloning $crate@$rev -> $dst" >&2
  rm -rf "$dst"
  mkdir -p "$dst"
  git -C "$dst" init -q
  git -C "$dst" remote add origin "$GH_BASE/$crate.git"
  git -C "$dst" fetch -q --depth 1 origin "$rev"
  git -C "$dst" checkout -q FETCH_HEAD
  printf '%s' "$dst"
}

build() {
  local crate="$1" binname="$2" rev="$3" src
  src="$(resolve_src "$crate" "$rev")"
  echo "build-binaries: building $crate ($TARGET, cargo $CARGO_BUILD_CMD) from $src"
  ( cd "$src" && cargo "$CARGO_BUILD_CMD" --release --target "$TARGET" --bin "$binname" )
  cp "$src/target/$TARGET/release/$binname" "$HERE/bin/$binname"
  chmod 0755 "$HERE/bin/$binname"
}

build tabbify-codeservice tabbify-codeservice "$CODESERVICE_REV"
build tabbify-broker      tabbify-broker      "$BROKER_REV"

echo "build-binaries: binaries in $HERE/bin:"
ls -l "$HERE/bin"
