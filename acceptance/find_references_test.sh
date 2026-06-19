#!/usr/bin/env bash
# v1 LSP PROOF (spec §7): boot the image, seed a 2-file rust repo, wait for the
# warm rust-analyzer index, then assert a REAL textDocument/references round-trip
# returns the cross-file reference. `find_references` must return the ACTUAL
# reference set, not an empty list.
#
# ┌─ INFRA / TOOLING GATE ────────────────────────────────────────────────────┐
# │ Needs the image BUILT with rust-analyzer baked + enough RAM to index. It   │
# │ is the headline cold→Ready proof; the cold→snapshot→warm-restore half is   │
# │ Track 3 + PHASE 1 (needs a live FC). Runs under Docker as a local proxy.   │
# └────────────────────────────────────────────────────────────────────────────┘
set -euo pipefail
IMG="${IMG:-tabbify-workspace-image:local}"

cid="$(docker run -d --privileged -p 18731:8731 \
  -e TABBIFY_DEVBOX_AUTHORIZED_KEY='ssh-ed25519 AAAATESTKEY test' "$IMG")"
trap 'docker rm -f "$cid" >/dev/null 2>&1 || true' EXIT
sleep 6

echo "== seed a 2-file rust repo (def in lib.rs, uses in main.rs) =="
docker exec -u agent "$cid" sh -c '
  mkdir -p /home/agent/projects/demo/src
  cat > /home/agent/projects/demo/Cargo.toml <<EOF
[package]
name = "demo"
version = "0.1.0"
edition = "2021"
[[bin]]
name = "demo"
path = "src/main.rs"
EOF
  printf "pub fn greet() {}\n" > /home/agent/projects/demo/src/lib.rs
  printf "use demo::greet;\nfn main() { greet(); greet(); }\n" > /home/agent/projects/demo/src/main.rs
'

echo "== wait for rust-analyzer index to be Ready (up to ~180s) =="
ready=0; resp=""
for _ in $(seq 1 90); do
  resp=$(curl -fsS -X POST http://127.0.0.1:18731/v1/code/find_references \
    -H 'content-type: application/json' \
    -d "{\"repo\":\"demo\",\"path\":\"src/lib.rs\",\"position\":{\"line\":0,\"character\":7}}" || true)
  if printf '%s' "$resp" | grep -q '"ok":true'; then ready=1; break; fi
  sleep 2
done
[ "$ready" = 1 ] || { echo "FAIL: find_references never became ready: $resp"; exit 1; }

echo "== references include the uses in main.rs (cross-file, real LSP) =="
printf '%s' "$resp" | grep -q '"path":"src/main.rs"' || {
  echo "FAIL: no cross-file reference to greet() in main.rs: $resp"; exit 1; }

echo "ALL FIND_REFERENCES ACCEPTANCE CHECKS PASSED"
