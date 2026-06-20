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

cid="$(docker run -d --privileged -p 18731:8731 -p 18080:8080 -p 18732:8732 \
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

# §12 S6: the broker's token-gated :8732 add-key endpoint. NO authkeys.cap is
# written in this smoke run, so the endpoint FAILS CLOSED — every request 401s
# (this is exactly the agent's situation: reachable but unauthorized). The
# status-only `-o /dev/null -w %{http_code}` lets us assert the code without -f.
code_no_token=$(curl -s -o /dev/null -w '%{http_code}' \
  -X POST http://127.0.0.1:18732/v1/authorized-keys \
  -H 'content-type: application/json' \
  -d '{"public_key":"ssh-ed25519 AAAA agent@self"}')
echo "== :8732 add-key WITHOUT a token is 401 (got $code_no_token) =="
[ "$code_no_token" = "401" ] || { echo "FAIL: no-token add-key must be 401, got $code_no_token"; exit 1; }

code_bad_token=$(curl -s -o /dev/null -w '%{http_code}' \
  -X POST http://127.0.0.1:18732/v1/authorized-keys \
  -H 'authorization: Bearer not-the-cap' -H 'content-type: application/json' \
  -d '{"public_key":"ssh-ed25519 AAAA agent@self"}')
echo "== :8732 add-key with a WRONG token is 401 (got $code_bad_token) =="
[ "$code_bad_token" = "401" ] || { echo "FAIL: wrong-token add-key must be 401, got $code_bad_token"; exit 1; }

# Now write a real authkeys.cap as root (simulating the supervisor cap-file) and
# prove the CORRECT token passes authorization (no longer 401 → it reaches the
# append). The agent could never do this write (0600 broker-uid cap-file). The
# broker re-reads the cap-file FRESH per request, so NO restart is needed.
docker exec -u root "$cid" sh -c '
  printf "BOOTSMOKE-CAP\n" > /run/tabbify/caps/authkeys.cap
  chown broker:broker /run/tabbify/caps/authkeys.cap
  chmod 0600 /run/tabbify/caps/authkeys.cap
'
code_good_token=$(curl -s -o /dev/null -w '%{http_code}' \
  -X POST http://127.0.0.1:18732/v1/authorized-keys \
  -H 'authorization: Bearer BOOTSMOKE-CAP' -H 'content-type: application/json' \
  -d '{"public_key":"ssh-ed25519 AAAAonelinekey laptop@home"}')
echo "== :8732 add-key with the CORRECT token passes authz, got 200 ($code_good_token) =="
[ "$code_good_token" != "401" ] || { echo "FAIL: correct-token add-key must NOT be 401"; exit 1; }
# The append targets agent's real ~/.ssh inside the image (the agent user exists),
# so the correct token should land a clean 200.
[ "$code_good_token" = "200" ] || { echo "FAIL: correct-token add-key expected 200, got $code_good_token"; exit 1; }

# And the agent STILL cannot read the cap-file (0600 broker-uid) — so it could
# never have presented this token itself.
if docker exec -u agent "$cid" cat /run/tabbify/caps/authkeys.cap 2>/dev/null; then
  echo "FAIL: agent read the authkeys cap"; exit 1
fi
echo "== agent CANNOT read the authkeys cap (so it cannot self-add keys) =="

echo "ALL BOOT-SMOKE CHECKS PASSED"
