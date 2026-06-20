#!/bin/sh
# Pre-snapshot scrub (spec §4): the Full snapshot captures ALL RAM + fs, so NO
# live cap-URL / token may exist at pause time — INCLUDING in the broker's RAM.
# This does BOTH halves the review flagged as required:
#   1. tells the LIVE broker to drop its in-RAM creds (real socket round-trip via
#      `tabbify-broker --scrub` — a no-op stub here would be a silent leak);
#   2. removes the tmpfs cred files so a broker restart re-reads nothing.
# The supervisor (Track 3) invokes this over exec immediately BEFORE Cmd::Snapshot
# and ABORTS the snapshot if it exits non-zero (never freeze a held secret).
set -u

# 1. Drop the broker's in-RAM creds (the part the Full snapshot would freeze).
if [ -S /run/tabbify/broker.sock ]; then
    if /usr/local/bin/tabbify-broker --scrub; then
        echo "pre-snapshot: broker in-RAM creds dropped"
    else
        echo "pre-snapshot: FATAL broker scrub failed — ABORT snapshot" >&2
        exit 1   # never snapshot a broker that still holds a secret
    fi
else
    echo "pre-snapshot: no broker socket (creds were never loaded) — ok"
fi

# 2. Remove the tmpfs cred files (defence in depth; tmpfs is excluded from the
#    persisted rootfs, but a restart must not re-load a stale secret). Covers the
#    per-repo cap-URLs, the §12-S6 authkeys cap (the :8732 bearer token), and the
#    forge-admin token (both the in-caps path the supervisor writes and the
#    legacy bare path).
rm -f /run/tabbify/caps/*.url /run/tabbify/caps/authkeys.cap \
      /run/tabbify/caps/forge-admin.token /run/tabbify/forge-admin 2>/dev/null || true
echo "pre-snapshot: cred files removed; scrub complete"
