# tabbify-workspace-image — the per-user Workspace FC image (descendant of
# tabbify-devbox-image). Bakes the code-intelligence stack + the Linux-as-IDE set
# + an unprivileged `agent` uid + a SEPARATE privileged `broker` uid. ONE warm
# rust-analyzer serves BOTH the MCP agent (find_references) and the human
# (neovim gd/gr). Does NOT clone repos on boot — clones are explicit broker ops
# that finish BEFORE the post-index snapshot (spec §3.4).
#
# Privilege separation (spec §4): exec/IDE land as `agent`, never root; the
# broker holds creds as its own uid behind a 0600 socket the agent cannot read;
# the §12-S1 cap dir (/run/tabbify/caps) is 0700 broker-uid; the cap-URL NEVER
# transits env. The OS-confinement acceptance test proves the invariant.
#
# Pin the platform: the generic-FC conversion rejects a non-host-arch rootfs.
FROM --platform=linux/amd64 ubuntu:24.04

ARG ARCH=x86_64
ARG LAZYGIT_VERSION=0.44.1

# Code-intelligence + Linux-as-IDE toolchain.
#   openssh-server  — sshd the node/laptop exec connects to (:2222)
#   busybox-static  — :8080 readiness shim (Ubuntu has no busybox by default)
#   ca-certificates curl git iproute2 — net + git + ip tooling
#   neovim tmux fzf fd-find ripgrep — the curated Linux-as-IDE set
#   build-essential — rust-analyzer/cargo need a C toolchain for the dogfood repo
RUN apt-get update \
 && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
      openssh-server ca-certificates curl git iproute2 busybox-static \
      neovim tmux fzf fd-find ripgrep \
      build-essential \
 && rm -rf /var/lib/apt/lists/* \
 # Debian/Ubuntu ship fd as `fdfind`; the codeservice probes both, but a `fd`
 # alias keeps the human IDE muscle-memory working too.
 && ln -sf "$(command -v fdfind)" /usr/local/bin/fd

# rustup + rust-analyzer (the LSP) + rustc/cargo for the dogfood repo's index.
# A system-wide CARGO_HOME/RUSTUP_HOME so the `agent` uid can run cargo/r-a.
ENV RUSTUP_HOME=/opt/rustup CARGO_HOME=/opt/cargo PATH=/opt/cargo/bin:$PATH
RUN curl -fsSL https://sh.rustup.rs -o /tmp/rustup.sh \
 && sh /tmp/rustup.sh -y --profile minimal \
      --component rust-analyzer --component rust-src \
 && rm -f /tmp/rustup.sh \
 && ln -sf "$(/opt/cargo/bin/rustup which rust-analyzer)" /usr/local/bin/rust-analyzer \
 && chmod -R a+rX /opt/rustup /opt/cargo

# tree-sitter CLI from the prebuilt GitHub release (no libclang/bindgen build).
# The codeservice links the tree-sitter LIBRARY via cargo for its symbol-fallback
# engine; this CLI is for the human IDE + ad-hoc grammar work. arch-aware.
RUN set -e; \
    case "$ARCH" in \
      x86_64)  TS_ARCH=x64 ;; \
      aarch64) TS_ARCH=arm64 ;; \
      *)       TS_ARCH=x64 ;; \
    esac; \
    TS_VER=0.24.7; \
    ( curl -fsSL "https://github.com/tree-sitter/tree-sitter/releases/download/v${TS_VER}/tree-sitter-linux-${TS_ARCH}.gz" \
        | gunzip > /usr/local/bin/tree-sitter \
      && chmod 0755 /usr/local/bin/tree-sitter ) \
    || echo "WARN: tree-sitter CLI download failed (non-fatal; the lib is linked in the codeservice)"

# lazygit (Linux-as-IDE git TUI) from the GitHub release. arch-aware.
RUN set -e; \
    case "$ARCH" in \
      x86_64)  LG_ARCH=x86_64 ;; \
      aarch64) LG_ARCH=arm64 ;; \
      *)       LG_ARCH=x86_64 ;; \
    esac; \
    curl -fsSL "https://github.com/jesseduffield/lazygit/releases/download/v${LAZYGIT_VERSION}/lazygit_${LAZYGIT_VERSION}_Linux_${LG_ARCH}.tar.gz" \
      | tar -xz -C /usr/local/bin lazygit \
    || echo "WARN: lazygit download failed (non-fatal)"

# Unprivileged `agent` uid owning ~/projects + ~/knowledge, and a SEPARATE
# `broker` uid (no shell, no home, no agent-readable creds). The agent CANNOT
# read broker paths (enforced at runtime by /init + the 0600 socket / 0700 dir).
#
# The broker is added to the `agent` GROUP so the privileged broker can mediate
# the §12-S6 add-key (write agent's ~/.ssh/authorized_keys) WITHOUT the agent
# ever reading a broker credential. This is one-directional: broker∈agent-group
# lets broker traverse /home/agent (0750) + write ~/.ssh (0770, group-writable);
# the agent is NOT in the broker group, so it still cannot read the broker socket
# (0600 broker:broker) nor any cap-file (0600 broker:broker). init.sh re-asserts
# these perms at boot (the rootfs perms can be reset by the generic-FC convert).
RUN useradd --create-home --shell /bin/bash agent \
 && useradd --system --no-create-home --shell /usr/sbin/nologin broker \
 && usermod -aG agent broker \
 && mkdir -p /home/agent/projects /home/agent/knowledge \
             /home/agent/.ssh /home/agent/.config \
 && chown -R agent:agent /home/agent \
 && chmod 0750 /home/agent \
 && chmod 0770 /home/agent/.ssh

# The in-FC binaries (built by scripts/build-binaries.sh into ./bin).
COPY bin/tabbify-codeservice /usr/local/bin/tabbify-codeservice
COPY bin/tabbify-broker      /usr/local/bin/tabbify-broker
RUN chmod 0755 /usr/local/bin/tabbify-codeservice /usr/local/bin/tabbify-broker

# Pre-snapshot scrub (spec §4): drops the broker's in-RAM creds + tmpfs cred
# files BEFORE a Full snapshot freezes them. Invoked by the supervisor (Track 3)
# right before Cmd::Snapshot; the snapshot is gated on its success.
COPY scripts/pre-snapshot-scrub.sh /usr/local/bin/tabbify-pre-snapshot-scrub
RUN chmod 0755 /usr/local/bin/tabbify-pre-snapshot-scrub

# LazyVim config baked for the `agent` user (the human IDE layer).
COPY lazyvim/ /home/agent/.config/nvim/
RUN chown -R agent:agent /home/agent/.config/nvim

# sshd: privsep dir + the agent-only drop-in config.
RUN mkdir -p /run/sshd
COPY sshd_config /etc/ssh/sshd_config.d/tabbify-workspace.conf

# PID-1 init (exec-form so the generic-FC path boots it as the microVM's init).
COPY init.sh /init
RUN chmod 0755 /init

# Ports: 2222 sshd, 8080 readiness, 8731 code-service, 8732 broker token-gated
# add-key control (§12 S6, T4 IDE-remote dynamic add-key — the broker serves it
# behind the authkeys-cap bearer gate; the runner forwards [app_ula]:8732 here).
EXPOSE 2222 8080 8731 8732
ENTRYPOINT ["/init"]
