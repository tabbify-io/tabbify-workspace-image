#!/usr/bin/env bash
# Boot the image under plain Docker (NOT firecracker) and assert the contract:
#   * codeservice answers on :8731 as the `agent` uid;
#   * :8080 readiness responds;
#   * the broker runs as the `broker` uid;
#   * sshd is configured AllowUsers=agent / PermitRootLogin no.
# A fast local proxy for the in-FC boot; the FC path is exercised in PHASE 1.
# Requires the image built + bin/ populated. Run --privileged so /init's mount/
# setpriv/sysctl succeed (the FC path runs PID-1 as real init where they do).
set -euo pipefail
IMG="${IMG:-tabbify-workspace-image:local}"

cid="$(docker run -d --privileged -p 18731:8731 -p 18080:8080 \
  -e TABBIFY_DEVBOX_AUTHORIZED_KEY='ssh-ed25519 AAAATESTKEY test' "$IMG")"
trap 'docker rm -f "$cid" >/dev/null 2>&1 || true' EXIT
sleep 6

echo "== codeservice runs as agent =="
docker exec "$cid" sh -c 'ps -o user= -C tabbify-codeservice' | grep -qx agent

echo "== broker runs as broker uid =="
docker exec "$cid" sh -c 'ps -o user= -C tabbify-broker' | grep -qx broker

echo "== :8080 readiness =="
curl -fsS http://127.0.0.1:18080/ >/dev/null

echo "== :8731 workspace_status envelope =="
curl -fsS -X POST http://127.0.0.1:18731/v1/code/workspace_status \
  -H 'content-type: application/json' -d '{}' | grep -q '"ok":true'

echo "== sshd is agent-only =="
docker exec "$cid" grep -q '^AllowUsers agent' /etc/ssh/sshd_config.d/tabbify-workspace.conf
docker exec "$cid" grep -q '^PermitRootLogin no'  /etc/ssh/sshd_config.d/tabbify-workspace.conf

echo "ALL BOOT-SMOKE CHECKS PASSED"
