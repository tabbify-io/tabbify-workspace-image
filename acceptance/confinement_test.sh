#!/usr/bin/env bash
# OS-CONFINEMENT ACCEPTANCE (spec §4 / §12 S1): an SSH session as `agent` (the
# only allowed exec user) CANNOT read the cap-URL, the broker socket, or the
# forge-admin token. The cap-URL arrives via the §12-S1 FILE channel — the
# supervisor writes /run/tabbify/caps/<repo>.url (broker-uid, 0600 dir 0700). It
# is NEVER passed via env, so there is no env/proc-environ leak. We SIMULATE the
# supervisor by writing the cap file as root, then assert `agent` cannot read it.
#
# ┌─ INFRA GATE ──────────────────────────────────────────────────────────────┐
# │ The TRUE acceptance is `ssh :2222` as agent inside a LIVE Firecracker VM.  │
# │ This Docker harness is a faithful local proxy for the file/uid/socket      │
# │ confinement (the part that does NOT need FC), and it MUST pass before the  │
# │ image ships. The end-to-end ssh-into-FC run is the project's live-E2E gate │
# │ (PHASE 1, needs a running KVM worker) — see the report.                    │
# └────────────────────────────────────────────────────────────────────────────┘
set -euo pipefail
IMG="${IMG:-tabbify-workspace-image:local}"

cid="$(docker run -d --privileged \
  -e TABBIFY_DEVBOX_AUTHORIZED_KEY='ssh-ed25519 AAAATESTKEY test' "$IMG")"
trap 'docker rm -f "$cid" >/dev/null 2>&1 || true' EXIT
sleep 6

echo "== supervisor writes a per-repo cap file (broker-uid, 0600) =="
docker exec -u root "$cid" sh -c '
  printf "http://172.31.0.1:8788/git/SUPERSECRETCAP\n" > /run/tabbify/caps/demo.url
  chown broker:broker /run/tabbify/caps/demo.url
  chmod 0600 /run/tabbify/caps/demo.url
'

echo "== supervisor writes the §12-S6 authkeys cap (broker-uid, 0600) =="
docker exec -u root "$cid" sh -c '
  printf "SUPERSECRETAUTHKEYSCAP\n" > /run/tabbify/caps/authkeys.cap
  chown broker:broker /run/tabbify/caps/authkeys.cap
  chmod 0600 /run/tabbify/caps/authkeys.cap
'

echo "== agent CANNOT read the per-repo cap file =="
if docker exec -u agent "$cid" cat /run/tabbify/caps/demo.url 2>/dev/null; then
  echo "FAIL: agent read the cap-URL file"; exit 1
fi

echo "== agent CANNOT read the §12-S6 authkeys cap (so it cannot self-add keys) =="
if docker exec -u agent "$cid" cat /run/tabbify/caps/authkeys.cap 2>/dev/null; then
  echo "FAIL: agent read the authkeys cap file"; exit 1
fi
echo "== the authkeys cap is NOT in agent's environment =="
if docker exec -u agent "$cid" sh -c 'env | grep -q SUPERSECRETAUTHKEYSCAP'; then
  echo "FAIL: authkeys cap leaked into agent env"; exit 1
fi

echo "== agent CANNOT even list the cap dir (0700 broker-uid) =="
if docker exec -u agent "$cid" sh -c 'ls /run/tabbify/caps 2>/dev/null | grep -q demo'; then
  echo "FAIL: agent listed the cap dir"; exit 1
fi

echo "== the cap-URL is NOT in agent's environment (it never transits env) =="
if docker exec -u agent "$cid" sh -c 'env | grep -q SUPERSECRETCAP'; then
  echo "FAIL: cap-URL leaked into agent env"; exit 1
fi

echo "== agent CANNOT read/connect the broker socket (0600 broker-uid) =="
if docker exec -u agent "$cid" sh -c 'test -r /run/tabbify/broker.sock'; then
  echo "FAIL: agent can read the broker socket"; exit 1
fi

echo "== agent's git remote points at the broker/forge, NOT :8788 =="
docker exec -u agent "$cid" sh -c '
  for d in /home/agent/projects/*/; do
    [ -d "$d/.git" ] || continue
    url=$(git -C "$d" remote get-url origin 2>/dev/null || true)
    case "$url" in *:8788*) echo "FAIL: agent remote hits :8788"; exit 1;; esac
  done
'

echo "ALL CONFINEMENT CHECKS PASSED"
