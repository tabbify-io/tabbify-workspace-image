#!/bin/sh
# Tabbify Workspace init (PID 1 in the microVM). Never exits — it IS the VM init;
# if PID 1 exits the kernel panics (panic=1) and the FC reboots in a loop. The
# broker, codeservice, and sshd all run as supervised CHILDREN.
#
# Responsibilities:
#   * real /dev (devtmpfs) so ssh-keygen / git have entropy;
#   * /run/tabbify tmpfs (root-owned, NOT snapshot-persisted) — the broker's
#     cred area; create /run/tabbify/caps (0700 broker-uid) — the §12-S1 channel
#     the SUPERVISOR (Track 3) writes per-repo cap-URLs into. /init NEVER reads a
#     cap-URL and it never enters env (spec §4 line 63 / §12 S1);
#   * /proc hidepid=2 + ptrace_scope=2 so the agent cannot inspect/ptrace broker;
#   * inject the node SSH key into AGENT's authorized_keys (exec lands as agent,
#     NEVER root);
#   * :8080 readiness shim (supervisor health probe);
#   * start the broker as the `broker` uid, the codeservice as the `agent` uid,
#     and sshd (AllowUsers=agent);
#   * does NOT clone repos (clones are explicit broker ops, post-boot).
set -u

AGENT_HOME=/home/agent
AUTH_KEYS="$AGENT_HOME/.ssh/authorized_keys"
TABBIFY_RUN=/run/tabbify

# 0. Real /dev. The generic-FC rootfs ships an empty tmpfs over /dev, hiding the
#    kernel devtmpfs (so /dev/urandom and /dev/null are absent and git/ssh-keygen
#    die for lack of entropy). Re-mount devtmpfs BEFORE ssh-keygen.
mount -t devtmpfs none /dev 2>/dev/null \
  && echo "workspace: re-mounted devtmpfs over /dev" \
  || echo "workspace: WARN could not mount devtmpfs over /dev" >&2

# 0b. hidepid=2 — the agent uid cannot see other uids' /proc entries (the broker
#     PID, its cmdline/env). Best-effort: logged if the kernel refuses.
mount -o remount,rw,hidepid=2 -t proc proc /proc 2>/dev/null \
  || mount -t proc -o hidepid=2 proc /proc 2>/dev/null \
  || echo "workspace: WARN hidepid=2 not applied" >&2

# 0c. ptrace hardening (defence in depth; agent cannot ptrace the broker).
sysctl -w kernel.yama.ptrace_scope=2 >/dev/null 2>&1 || true

# 1. Broker cred area: a tmpfs (NOT snapshot-persisted) owned by the broker uid
#    so the broker can bind its 0600 socket (/run/tabbify/broker.sock) and read
#    the cap files. Mode 0711 broker-uid: the agent uid may traverse but CANNOT
#    list the dir, and every sensitive child is broker-only (socket 0600, caps
#    dir 0700) — so the agent can read NEITHER the socket NOR any cap. The §12-S1
#    cap sub-dir /run/tabbify/caps is broker-owned 0700; the SUPERVISOR writes
#    per-repo cap-URLs there post-create (/run/tabbify/caps/<repo>.url). /init
#    NEVER reads a cap-URL from env — the secret never enters the agent's
#    environment (spec §4 line 63 / §12 S1).
mkdir -p "$TABBIFY_RUN"
mount -t tmpfs -o mode=0711,uid=0,gid=0 tmpfs "$TABBIFY_RUN" 2>/dev/null || true
# Own the cred area by the broker uid so it can create the socket; 0711 keeps
# the agent from listing it (the socket name + cap files stay hidden).
chown broker:broker "$TABBIFY_RUN"
chmod 0711 "$TABBIFY_RUN"
mkdir -p "$TABBIFY_RUN/caps"
chown broker:broker "$TABBIFY_RUN/caps"
chmod 0700 "$TABBIFY_RUN/caps"
echo "workspace: created broker-only cred area $TABBIFY_RUN (socket 0600) + cap dir $TABBIFY_RUN/caps 0700"

# 2. Inject the node SSH key into AGENT (exec lands as `agent`, never root).
if [ -n "${TABBIFY_DEVBOX_AUTHORIZED_KEY:-}" ]; then
    mkdir -p "$AGENT_HOME/.ssh"
    printf '%s\n' "$TABBIFY_DEVBOX_AUTHORIZED_KEY" > "$AUTH_KEYS"
    chown -R agent:agent "$AGENT_HOME/.ssh"
    chmod 700 "$AGENT_HOME/.ssh"
    chmod 600 "$AUTH_KEYS"
    echo "workspace: injected node key into agent authorized_keys"
else
    echo "workspace: WARN TABBIFY_DEVBOX_AUTHORIZED_KEY empty; exec will fail until a key is provisioned" >&2
fi

# 3. Unique host keys per workspace.
ssh-keygen -A || echo "workspace: FATAL ssh-keygen -A failed; sshd cannot start" >&2

# 4. Readiness shim on :8080 (supervisor health probe).
if command -v busybox >/dev/null 2>&1; then
    mkdir -p /var/run/ws-www
    echo "workspace ok" > /var/run/ws-www/index.html
    busybox httpd -f -p 8080 -h /var/run/ws-www &
fi

# 5. Broker as the privileged `broker` uid (holds creds; agent has no access).
#    Binds the 0600 socket /run/tabbify/broker.sock; reads cap-URLs from the
#    0700 broker-uid cap dir only.
echo "workspace: starting tabbify-broker as broker uid"
setpriv --reuid broker --regid broker --init-groups \
    /usr/local/bin/tabbify-broker &
# Give the broker a moment to bind the 0600 socket before the agent service.
sleep 1

# 6. Code-service as the UNPRIVILEGED agent uid (confined to ~/projects+~/knowledge).
echo "workspace: starting tabbify-codeservice as agent on :8731"
setpriv --reuid agent --regid agent --init-groups \
    env CODESERVICE_USER_ID="${CODESERVICE_USER_ID:-default}" \
        PATH="/opt/cargo/bin:$PATH" \
    /usr/local/bin/tabbify-codeservice &

# 7. Init loop: sshd (agent-only) as a restartable child; PID 1 never exits.
echo "workspace: starting sshd on :2222 (agent-only, supervised)"
while :; do
    /usr/sbin/sshd -D -e &
    SSHD_PID=$!
    wait "$SSHD_PID"
    echo "workspace: sshd exited rc=$? — restarting in 1s" >&2
    sleep 1
done
