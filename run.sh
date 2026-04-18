#!/usr/bin/env bash
#
# OpenClaw Podman Deploy
# Runs an isolated Ubuntu 24.04 LTS container via Podman rootless.
# The entrypoint loops `openclaw gateway run` with exponential backoff.
# Network-isolated: slirp4netns with host loopback disabled.
#
# Host prerequisites:
#   Ubuntu/Debian:  sudo apt install -y podman
#   Fedora/RHEL:    sudo dnf install -y podman
#   Run './run.sh setup' once to enable container auto-restart after host reboot.
#
# Env overrides:
#   SSH_PORT             Host port for container SSH (default: 2222)
#   GATEWAY_PORT         Expose gateway port from container to host
#   OPENCLAW_VERSION     npm tag/version (default: latest)
#
set -euo pipefail

print_help() {
    cat <<'EOF'
Usage:
  ./run.sh start               Start container (creates on first run, resumes if stopped)
  ./run.sh stop                Stop container (preserves state)
  ./run.sh restart             Stop + start
  ./run.sh status              Show container + gateway state, last exit reason
  ./run.sh shell               Interactive shell inside container
  ./run.sh shell -- cmd args…  Run argv directly (no shell parsing)
  ./run.sh shell -c 'string'   Run command string via bash -lc
  ./run.sh destroy             Remove container (data in .data/ is kept)
  ./run.sh rebuild [--yes]     Destroy + rebuild image from scratch
  ./run.sh update              Update openclaw; print version diff
  ./run.sh version             Show installed openclaw version (non-zero if missing)
  ./run.sh logs                Show container logs
  ./run.sh backup              Stop briefly, export to .backups/ (mode 0600)
  ./run.sh restore <file>      Restore container + data; rolls back on failure
  ./run.sh setup               Enable host-level auto-restart (linger + podman-restart)
  ./run.sh help                Show this help
EOF
}

# ── Help (before preflight so it works without podman) ────────────────────
case "${1:-}" in -h|--help|help) print_help; exit 0 ;; esac

# ── Preflight ─────────────────────────────────────────────────────────────
command -v podman >/dev/null 2>&1 || { echo "Error: podman is not installed. Run: sudo apt install -y podman"; exit 1; }
if ! awk -F: -v u="$(whoami)" '$1==u {f=1} END{exit !f}' /etc/subuid 2>/dev/null; then
    echo "Error: rootless podman requires subuid/subgid entries for $(whoami)."
    echo "Fix:   sudo usermod --add-subuids 100000-165535 --add-subgids 100000-165535 $(whoami) && podman system migrate"
    exit 1
fi

# ── Config ────────────────────────────────────────────────────────────────
DIR="$(cd "$(dirname "$0")" && pwd)"
CONTAINER_NAME="openclaw"
IMAGE_NAME="openclaw-ubuntu"
DATA_DIR="$DIR/.data"
USER_HOME_DIR="$DATA_DIR/openclaw-user-home"
BACKUP_DIR="$DIR/.backups"
TMP_DIR="$DIR/.tmp"
VM_USER="user"
GATEWAY_PORT="${GATEWAY_PORT:-}"
SSH_PORT="${SSH_PORT:-2222}"
OPENCLAW_VERSION="${OPENCLAW_VERSION:-latest}"

# ── Containerfile Generation ──────────────────────────────────────────────
generate_containerfile() {
    cat > "$DIR/Containerfile" << 'EOF'
FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive

# core tools — wrap heavy installs with eatmydata to skip dpkg fsyncs (~25% faster)
RUN apt-get update \
    && apt-get install -y --no-install-recommends eatmydata \
    && eatmydata apt-get install -y --no-install-recommends \
    curl wget git htop tmux vim nano jq unzip zip file sudo direnv \
    # build toolchain
    build-essential \
    # python
    python3 python3-pip python3-venv \
    # code search & navigation
    ripgrep fd-find tree fzf \
    # networking
    net-tools dnsutils iputils-ping netcat-openbsd openssl \
    openssh-client openssh-server rsync \
    # databases
    sqlite3 \
    # process debugging
    lsof psmisc \
    # media
    ffmpeg \
    # compression
    bzip2 xz-utils \
    # tls/auth
    ca-certificates gnupg locales \
    && sed -i '/en_US.UTF-8/s/^# //' /etc/locale.gen \
    && locale-gen

ENV LANG=en_US.UTF-8
ENV LC_ALL=en_US.UTF-8
ENV SHELL=/bin/bash

# node.js 22
RUN curl -fsSL https://deb.nodesource.com/setup_22.x | bash - \
    && eatmydata apt-get install -y nodejs

# github cli
RUN curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
        | dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
        > /etc/apt/sources.list.d/github-cli.list \
    && apt-get update && eatmydata apt-get install -y gh

# yq — pinned version, sha256 verified via release checksums manifest
ARG YQ_VERSION=v4.45.4
RUN set -e; \
    arch=$(dpkg --print-architecture); \
    asset="yq_linux_${arch}"; \
    base="https://github.com/mikefarah/yq/releases/download/${YQ_VERSION}"; \
    curl -fsSL "${base}/${asset}" -o "/tmp/${asset}"; \
    curl -fsSL "${base}/checksums" -o /tmp/yq.sums; \
    curl -fsSL "${base}/checksums_hashes_order" -o /tmp/yq.order; \
    col=$(awk '$1=="SHA-256"{print NR+1; exit}' /tmp/yq.order); \
    hash=$(awk -v f="${asset}" -v c="${col}" '$1==f{print $c; exit}' /tmp/yq.sums); \
    [ -n "$hash" ] || { echo "Could not resolve yq sha256"; exit 1; }; \
    echo "${hash}  /tmp/${asset}" | sha256sum -c -; \
    install -m 0755 "/tmp/${asset}" /usr/local/bin/yq; \
    rm -f /tmp/yq.sums /tmp/yq.order "/tmp/${asset}"

# user setup
RUN useradd -m -s /bin/bash -G sudo user \
    && echo "user:openclaw" | chpasswd \
    && echo "user ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/user

# sudo wrapper — auto-prepends sudo unless already present
RUN echo '#!/bin/bash\n[[ "$*" == *sudo* ]] && exec "$@" || exec sudo "$@"' > /usr/local/bin/user_sudo.sh \
    && chmod 755 /usr/local/bin/user_sudo.sh

# openclaw — install system-wide to avoid first-boot races with mounted home
ARG OPENCLAW_VERSION=latest
RUN npm install -g "openclaw@${OPENCLAW_VERSION}"

# ssh server
RUN mkdir -p /run/sshd /home/user/.ssh \
    && chown -R user:user /home/user/.ssh \
    && chmod 700 /home/user/.ssh \
    && printf '%s\n' \
        'Port 2222' \
        'ListenAddress 0.0.0.0' \
        'PermitRootLogin no' \
        'PasswordAuthentication yes' \
        'PubkeyAuthentication yes' \
        'KbdInteractiveAuthentication no' \
        'UsePAM no' \
        'X11Forwarding no' \
        'AllowTcpForwarding yes' \
        'GatewayPorts no' \
        'AllowUsers user' \
        > /etc/ssh/sshd_config.d/openclaw.conf

# uv (python package manager) - install system-wide since /home/user is a mounted volume
RUN curl -LsSf https://astral.sh/uv/install.sh | env UV_INSTALL_DIR=/usr/local/bin sh

CMD ["sleep", "infinity"]
EOF
}

# ── Utilities ─────────────────────────────────────────────────────────────
run_step() {
    local label="$1"
    shift
    echo "==> $label"
    "$@"
    echo "Done: $label"
}

create_tmp_dir() {
    mkdir -p "$TMP_DIR"
    mktemp -d "$TMP_DIR/openclaw.XXXXXX"
}

cleanup_tmp_dir() {
    local tmp_dir="$1"
    [ -n "$tmp_dir" ] && rm -rf "$tmp_dir"
}

check_port_free() {
    local port=$1
    command -v ss >/dev/null 2>&1 || return 0
    if ss -ltn 2>/dev/null | awk '{print $4}' | grep -qE "[:.]${port}$"; then
        echo "Error: host port $port is already in use. Set SSH_PORT / GATEWAY_PORT or stop the conflicting process."
        exit 1
    fi
}

# ── Image Management ──────────────────────────────────────────────────────
image_exists() {
    podman image exists "$IMAGE_NAME" 2>/dev/null
}

build_image() {
    generate_containerfile
    if image_exists; then
        echo "Image '$IMAGE_NAME' already exists. Use './run.sh rebuild' to force rebuild."
        return 0
    fi
    echo "Building image (this takes a few minutes on first run)..."
    podman build \
        --build-arg "OPENCLAW_VERSION=$OPENCLAW_VERSION" \
        -t "$IMAGE_NAME" -f "$DIR/Containerfile" "$DIR"
}

remove_image_if_present() {
    podman rmi -f "$IMAGE_NAME" 2>/dev/null || true
}

rebuild_image() {
    if [ "${1:-}" != "--yes" ] && [ -t 0 ]; then
        read -rp "Rebuild image from scratch? Container will be recreated (data in .data/ is kept). [y/N] " ans
        case "$ans" in [Yy]|[Yy][Ee][Ss]) ;; *) echo "Aborted."; return 0 ;; esac
    fi
    run_step "Remove existing container" destroy_container
    run_step "Remove existing image" remove_image_if_present
    run_step "Generate Containerfile" generate_containerfile
    run_step "Build image from scratch" podman build --no-cache \
        --build-arg "OPENCLAW_VERSION=$OPENCLAW_VERSION" \
        -t "$IMAGE_NAME" -f "$DIR/Containerfile" "$DIR"
    run_step "Start rebuilt container" start_container
}

# ── Container Exec / Readiness ────────────────────────────────────────────
vm_exec() {
    podman exec -u "$VM_USER" "$CONTAINER_NAME" "$@"
}

wait_for_ready() {
    echo "Waiting for container..."
    for _ in $(seq 1 15); do
        if podman exec "$CONTAINER_NAME" true 2>/dev/null \
            && podman exec "$CONTAINER_NAME" sh -c 'pgrep -x sshd >/dev/null' 2>/dev/null; then
            echo "Container is up."
            return 0
        fi
        sleep 1
    done
    echo "Error: container not ready after 15 seconds."
    podman logs --tail 30 "$CONTAINER_NAME" 2>&1 || true
    return 1
}

wait_for_ssh_port() {
    echo "Waiting for SSH on port $SSH_PORT..."
    for _ in $(seq 1 20); do
        if timeout 1 bash -c "</dev/tcp/127.0.0.1/$SSH_PORT" 2>/dev/null; then
            echo "SSH is reachable."
            return 0
        fi
        sleep 1
    done
    echo "Error: SSH port $SSH_PORT is not reachable."
    return 1
}

wait_for_gateway() {
    echo "Waiting for openclaw gateway..."
    local stable=0
    for _ in $(seq 1 30); do
        if podman exec "$CONTAINER_NAME" pgrep -f 'openclaw gateway' >/dev/null 2>&1; then
            stable=$((stable + 1))
            if [ "$stable" -ge 3 ]; then
                echo "Gateway process running."
                return 0
            fi
        else
            stable=0
        fi
        sleep 1
    done
    echo "Warning: openclaw gateway did not stay up. Recent logs:"
    podman logs --tail 30 "$CONTAINER_NAME" 2>&1 || true
    return 1
}

# ── Home Directory Init (pre-gateway sentinel) ────────────────────────────
# First bootstrap: entrypoint waits for ~/.openclaw-ready before launching
# the gateway, so init runs without a chown-vs-gateway race. On subsequent
# starts the sentinel is already present and init is a no-op.
init_home_dir() {
    if ! vm_exec test -e "/home/$VM_USER/.openclaw-ready" 2>/dev/null; then
        echo "Initializing home directory..."
        podman exec "$CONTAINER_NAME" chown -R "$VM_USER:$VM_USER" "/home/$VM_USER"
        vm_exec sh -c "cp /etc/skel/.bashrc /etc/skel/.profile /etc/skel/.bash_logout ~ 2>/dev/null || true"
        vm_exec sh -c 'mkdir -p ~/.ssh && chmod 700 ~/.ssh'
        vm_exec touch "/home/$VM_USER/.openclaw-ready"
    fi
    if ! vm_exec sh -lc 'command -v openclaw >/dev/null 2>&1'; then
        install_openclaw
    fi
}

install_openclaw() {
    echo "Installing openclaw@${OPENCLAW_VERSION}..."
    podman exec "$CONTAINER_NAME" sh -lc "set -e; npm install -g openclaw@${OPENCLAW_VERSION}; command -v openclaw >/dev/null 2>&1"
}

# ── Lifecycle ─────────────────────────────────────────────────────────────
is_running() {
    podman container exists "$CONTAINER_NAME" 2>/dev/null \
        && [ "$(podman inspect -f '{{.State.Running}}' "$CONTAINER_NAME" 2>/dev/null)" = "true" ]
}

container_exists() {
    podman container exists "$CONTAINER_NAME" 2>/dev/null
}

preflight_ports() {
    check_port_free "$SSH_PORT"
    [ -n "$GATEWAY_PORT" ] && check_port_free "$GATEWAY_PORT"
}

create_container() {
    local image="$1"
    [ -r "$DIR/entrypoint.sh" ] || { echo "Error: $DIR/entrypoint.sh missing or unreadable."; exit 1; }
    local run_args=(
        -d
        --name "$CONTAINER_NAME"
        --restart=always
        --init
        --network=slirp4netns:allow_host_loopback=false
        -v "$USER_HOME_DIR:/home/$VM_USER:Z"
        -v "$DIR/entrypoint.sh:/usr/local/bin/entrypoint.sh:Z,ro"
        --log-opt max-size=10m
        -p "127.0.0.1:${SSH_PORT}:2222"
    )
    if [ -n "$GATEWAY_PORT" ]; then
        run_args+=(-p "${GATEWAY_PORT}:${GATEWAY_PORT}")
    fi
    podman run "${run_args[@]}" "$image" /usr/local/bin/entrypoint.sh
}

ensure_data_dirs() {
    mkdir -p "$USER_HOME_DIR"
}

wait_for_container_services() {
    wait_for_ready
    wait_for_ssh_port
}

bootstrap_new_container() {
    run_step "Build image" build_image
    run_step "Prepare data dirs" ensure_data_dirs
    run_step "Create container" create_container "$IMAGE_NAME"
    run_step "Wait for container services" wait_for_container_services
    run_step "Initialize container state" init_home_dir
    run_step "Wait for openclaw gateway" wait_for_gateway || true
}

resume_existing_container() {
    run_step "Prepare data dirs" ensure_data_dirs
    run_step "Start existing container" podman start "$CONTAINER_NAME"
    run_step "Wait for container services" wait_for_container_services
    run_step "Initialize container state" init_home_dir
    run_step "Wait for openclaw gateway" wait_for_gateway || true
}

start_container() {
    if is_running; then
        echo "Container '$CONTAINER_NAME' already running."
        return 0
    fi
    preflight_ports
    if container_exists; then
        resume_existing_container
        return 0
    fi
    bootstrap_new_container
}

stop_container() {
    if ! is_running; then
        echo "Container not running."
        return 0
    fi
    echo "Stopping container..."
    podman stop -t 10 "$CONTAINER_NAME"
    echo "Container stopped. State preserved — use 'start' to resume."
}

destroy_container() {
    stop_container 2>/dev/null || true
    if container_exists; then
        echo "Removing container..."
        podman rm "$CONTAINER_NAME"
        echo "Container removed."
    fi
}

status_container() {
    if ! container_exists; then
        echo "Container: does not exist"
        return 0
    fi
    if is_running; then
        echo "Container: running"
        podman ps --filter "name=$CONTAINER_NAME" --format "table {{.ID}}\t{{.Status}}\t{{.Ports}}"
        if podman exec "$CONTAINER_NAME" pgrep -f 'openclaw gateway' >/dev/null 2>&1; then
            echo "Gateway:   running"
        else
            echo "Gateway:   NOT running (check logs)"
        fi
        local last_exit
        last_exit=$(podman logs --tail 200 "$CONTAINER_NAME" 2>&1 | grep -F 'openclaw gateway exited' | tail -n 1 || true)
        [ -n "$last_exit" ] && echo "Last exit: $last_exit"
    else
        echo "Container: stopped"
    fi
}

show_logs() {
    container_exists || { echo "Container does not exist. Start it first."; return 1; }
    podman logs "$CONTAINER_NAME" 2>&1
}

update_openclaw() {
    is_running || { echo "Container not running. Start it first."; return 1; }
    local old_ver new_ver
    old_ver=$(vm_exec sh -lc 'openclaw --version 2>/dev/null' || echo "unknown")
    if ! run_step "Install openclaw@${OPENCLAW_VERSION}" install_openclaw; then
        echo "Update failed. openclaw remains at $old_ver."
        return 1
    fi
    new_ver=$(vm_exec sh -lc 'openclaw --version 2>/dev/null' || echo "unknown")
    if [ "$old_ver" = "$new_ver" ]; then
        echo "Already at $old_ver. No restart needed."
        return 0
    fi
    echo "Updated: $old_ver → $new_ver. Restarting container..."
    podman restart "$CONTAINER_NAME"
    wait_for_container_services
    init_home_dir
    wait_for_gateway || true
}

show_version() {
    is_running || { echo "Container not running. Start it first."; return 1; }
    local v
    v=$(vm_exec sh -lc 'openclaw --version 2>/dev/null' || true)
    if [ -z "$v" ]; then
        echo "unknown"
        return 1
    fi
    echo "$v"
}

# ── Backup / Restore ──────────────────────────────────────────────────────
backup_container() {
    container_exists || { echo "No container to backup."; return 1; }
    mkdir -p "$BACKUP_DIR"
    chmod 700 "$BACKUP_DIR"
    local was_running=0
    if is_running; then
        was_running=1
        stop_container
    fi
    local ts
    ts=$(date +%Y%m%d_%H%M%S)
    local out="$BACKUP_DIR/openclaw_backup_${ts}.tar.gz"
    local tmp
    tmp=$(create_tmp_dir)
    local fail=0

    echo "Exporting container..."
    podman export "$CONTAINER_NAME" > "$tmp/container.tar" || fail=1
    if [ "$fail" -eq 0 ]; then
        echo "Archiving data..."
        podman unshare tar cf "$tmp/data.tar" -C "$DATA_DIR" . || fail=1
    fi
    if [ "$fail" -eq 0 ]; then
        tar czf "$out.tmp" -C "$tmp" container.tar data.tar || fail=1
    fi
    cleanup_tmp_dir "$tmp"
    [ "$was_running" -eq 1 ] && start_container
    if [ "$fail" -eq 1 ]; then
        rm -f "$out.tmp"
        echo "Backup failed."
        return 1
    fi
    mv "$out.tmp" "$out"
    chmod 600 "$out"
    echo "Backup saved: $out ($(du -h "$out" | cut -f1)) [mode 0600]"
    echo "Note: archive contains .ssh/, .config/, .npmrc, etc. — handle as a secret."
}

restore_container() {
    local archive="$1"
    [ -f "$archive" ] || { echo "File not found: $archive"; return 1; }
    preflight_ports
    local ts
    ts=$(date +%Y%m%d_%H%M%S)
    local tmp
    tmp=$(create_tmp_dir)

    local old_container="${CONTAINER_NAME}_old_${ts}"
    local old_data="${DATA_DIR}_old_${ts}"
    local img="${IMAGE_NAME}:restored_${ts}"
    local renamed=0 moved=0 imported=0 created=0

    # shellcheck disable=SC2317
    rollback_restore() {
        echo "Restore failed, rolling back..."
        [ "$created"  -eq 1 ] && podman rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true
        [ "$imported" -eq 1 ] && podman rmi -f "$img"           >/dev/null 2>&1 || true
        if [ -d "$DATA_DIR" ] && [ "$moved" -eq 1 ]; then
            podman unshare rm -rf "$DATA_DIR" >/dev/null 2>&1 || true
        fi
        [ "$moved"    -eq 1 ] && podman unshare mv "$old_data" "$DATA_DIR" >/dev/null 2>&1 || true
        [ "$renamed"  -eq 1 ] && podman rename "$old_container" "$CONTAINER_NAME" >/dev/null 2>&1 || true
        cleanup_tmp_dir "$tmp"
    }

    if ! tar xzf "$archive" -C "$tmp" \
        || [ ! -f "$tmp/container.tar" ] \
        || [ ! -f "$tmp/data.tar" ]; then
        echo "Invalid backup archive."
        cleanup_tmp_dir "$tmp"
        return 1
    fi

    if container_exists; then
        stop_container 2>/dev/null || true
        if ! podman rename "$CONTAINER_NAME" "$old_container"; then rollback_restore; return 1; fi
        renamed=1
    fi
    if [ -d "$DATA_DIR" ]; then
        if ! podman unshare mv "$DATA_DIR" "$old_data"; then rollback_restore; return 1; fi
        moved=1
    fi

    mkdir -p "$DATA_DIR"
    if ! podman unshare tar xf "$tmp/data.tar" -C "$DATA_DIR"; then rollback_restore; return 1; fi
    if ! podman import "$tmp/container.tar" "$img" >/dev/null; then rollback_restore; return 1; fi
    imported=1
    if ! create_container "$img" >/dev/null; then rollback_restore; return 1; fi
    created=1
    if ! wait_for_ready;    then rollback_restore; return 1; fi
    if ! init_home_dir;     then rollback_restore; return 1; fi
    if ! wait_for_ssh_port; then rollback_restore; return 1; fi
    wait_for_gateway || true

    cleanup_tmp_dir "$tmp"
    echo "Restore complete. Previous container/data kept as ${old_container} / ${old_data}."
    echo "Remove when you've verified the restore: podman rm ${old_container} && podman unshare rm -rf ${old_data}"
}

setup_host() {
    sudo loginctl enable-linger "$(whoami)"
    systemctl --user enable podman-restart.service
    echo "Verifying..."
    loginctl show-user "$(whoami)" | grep Linger
    systemctl --user is-enabled podman-restart.service
    echo "Host setup complete. Containers with --restart=always will auto-start after reboot."
}

# ── Shell helper ──────────────────────────────────────────────────────────
run_shell() {
    is_running || { echo "Container not running. Start it first."; exit 1; }
    if [ $# -eq 0 ]; then
        podman exec -it -u "$VM_USER" "$CONTAINER_NAME" /bin/bash
        return
    fi
    case "$1" in
        --) shift; podman exec -it -u "$VM_USER" "$CONTAINER_NAME" "$@" ;;
        -c) shift; podman exec -it -u "$VM_USER" "$CONTAINER_NAME" bash -lc "$*" ;;
        *)  echo "Usage: $0 shell [-- cmd args… | -c 'string']"; exit 1 ;;
    esac
}

# ── Entrypoint ────────────────────────────────────────────────────────────
case "${1:-start}" in
    start)   start_container ;;
    stop)    stop_container ;;
    restart) stop_container; start_container ;;
    status)  status_container ;;
    shell)   shift; run_shell "$@" ;;
    destroy) destroy_container ;;
    rebuild) shift; rebuild_image "$@" ;;
    update)  update_openclaw ;;
    version) show_version ;;
    logs)    show_logs ;;
    backup)  backup_container ;;
    restore) shift; restore_container "${1:?Usage: $0 restore <backup_file>}" ;;
    setup)   setup_host ;;
    *)       print_help; exit 1 ;;
esac
