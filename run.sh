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
# Usage:
#   ./run.sh start          Start container (creates on first run, resumes if stopped)
#   ./run.sh stop           Stop container (preserves state and installed packages)
#   ./run.sh restart        Stop + start
#   ./run.sh status         Check if container is running
#   ./run.sh shell [cmd]    Open shell or run command inside container
#   ./run.sh destroy        Remove container entirely (data in .data/ is kept)
#   ./run.sh rebuild        Destroy container + rebuild image from scratch
#   ./run.sh update         Update openclaw to latest version inside running container
#   ./run.sh version        Show installed openclaw version
#   ./run.sh logs           Show container logs
#   ./run.sh backup         Export container + data into a timestamped .tar.gz
#   ./run.sh restore <file> Restore container + data from a backup archive
#   ./run.sh setup          Enable host-level auto-restart prerequisites (linger + podman-restart)
#
set -euo pipefail

print_help() {
    cat <<'EOF'
Usage:
  ./run.sh start          Start container (creates on first run, resumes if stopped)
  ./run.sh stop           Stop container (preserves state and installed packages)
  ./run.sh restart        Stop + start
  ./run.sh status         Check if container is running
  ./run.sh shell [cmd]    Open shell or run command inside container
  ./run.sh destroy        Remove container entirely (data in .data/ is kept)
  ./run.sh rebuild        Destroy container + rebuild image from scratch
  ./run.sh update         Update openclaw to latest version inside running container
  ./run.sh version        Show installed openclaw version
  ./run.sh logs           Show container logs
  ./run.sh backup         Export container + data into a timestamped .tar.gz
  ./run.sh restore <file> Restore container + data from a backup archive
  ./run.sh setup          Enable host-level auto-restart prerequisites (linger + podman-restart)
  ./run.sh help           Show this help
EOF
}

# ── Help (before preflight so it works without podman) ────────────────────
case "${1:-}" in -h|--help|help) print_help; exit 0 ;; esac

# ── Preflight ─────────────────────────────────────────────────────────────
command -v podman >/dev/null 2>&1 || { echo "Error: podman is not installed. Run: sudo apt install -y podman"; exit 1; }
if ! grep -q "^$(whoami):" /etc/subuid 2>/dev/null; then
    echo "Error: rootless podman requires subuid/subgid entries for $(whoami)."
    echo "Fix:   sudo usermod --add-subuids 100000-165535 --add-subgids 100000-165535 $(whoami) && podman system migrate"
    exit 1
fi

# ── Config ──────────────────────────────────────────────────────────────────
DIR="$(cd "$(dirname "$0")" && pwd)"
CONTAINER_NAME="openclaw"
IMAGE_NAME="openclaw-ubuntu"
DATA_DIR="$DIR/.data"
USER_HOME_DIR="$DATA_DIR/openclaw-user-home"
TMP_DIR="$DIR/.tmp"
VM_USER="user"
GATEWAY_PORT="${GATEWAY_PORT:-}"
SSH_PORT="${SSH_PORT:-2222}"

# ── Containerfile Generation ────────────────────────────────────────────────
generate_containerfile() {
    cat > "$DIR/Containerfile" << 'EOF'
FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive

# core tools
RUN apt-get update && apt-get install -y --no-install-recommends \
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
    && rm -rf /var/lib/apt/lists/* \
    && sed -i '/en_US.UTF-8/s/^# //' /etc/locale.gen \
    && locale-gen

ENV LANG=en_US.UTF-8
ENV LC_ALL=en_US.UTF-8

# node.js 22
RUN curl -fsSL https://deb.nodesource.com/setup_22.x | bash - \
    && apt-get install -y nodejs \
    && rm -rf /var/lib/apt/lists/*

# github cli
RUN curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
        | dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
        > /etc/apt/sources.list.d/github-cli.list \
    && apt-get update && apt-get install -y gh \
    && rm -rf /var/lib/apt/lists/*

# yq
RUN ARCH=$(dpkg --print-architecture) \
    && curl -fsSL "https://github.com/mikefarah/yq/releases/download/v4.45.4/yq_linux_${ARCH}" \
        -o /usr/local/bin/yq \
    && chmod +x /usr/local/bin/yq

# user setup
RUN useradd -m -s /bin/bash -G sudo user \
    && echo "user:openclaw" | chpasswd \
    && echo "user ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/user

# sudo wrapper — auto-prepends sudo unless already present
RUN echo '#!/bin/bash\n[[ "$*" == *sudo* ]] && exec "$@" || exec sudo "$@"' > /usr/local/bin/user_sudo.sh \
    && chmod 755 /usr/local/bin/user_sudo.sh

# openclaw — install system-wide to avoid first-boot races with mounted home
RUN npm install -g openclaw@latest

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

# ── Image Management ───────────────────────────────────────────────────────
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
    podman build -t "$IMAGE_NAME" -f "$DIR/Containerfile" "$DIR"
}

remove_image_if_present() {
    podman rmi -f "$IMAGE_NAME" 2>/dev/null || true
}

rebuild_image() {
    run_step "Remove existing container" destroy_container
    run_step "Remove existing image" remove_image_if_present
    run_step "Generate Containerfile" generate_containerfile
    run_step "Build image from scratch" podman build --no-cache -t "$IMAGE_NAME" -f "$DIR/Containerfile" "$DIR"
    run_step "Start rebuilt container" start_container
}

# ── Container Exec ─────────────────────────────────────────────────────────
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
    echo "Warning: container not ready after 15 seconds."
    return 1
}

wait_for_ssh_port() {
    echo "Waiting for SSH on port $SSH_PORT..."
    for _ in $(seq 1 20); do
        if (exec 3<>"/dev/tcp/127.0.0.1/$SSH_PORT") 2>/dev/null; then
            exec 3<&-
            exec 3>&-
            echo "SSH is reachable."
            return 0
        fi
        sleep 1
    done
    echo "Warning: SSH port $SSH_PORT is not reachable yet."
    return 1
}

create_tmp_dir() {
    mkdir -p "$TMP_DIR"
    mktemp -d "$TMP_DIR/openclaw.XXXXXX"
}

cleanup_tmp_dir() {
    local tmp_dir="$1"
    [ -n "$tmp_dir" ] && rm -rf "$tmp_dir"
}

run_step() {
    local label="$1"
    shift
    echo "==> $label"
    "$@"
    echo "Done: $label"
}

# ── Home Directory Init ─────────────────────────────────────────────────────
init_home_dir() {
    podman exec "$CONTAINER_NAME" chown -R "$VM_USER:$VM_USER" "/home/$VM_USER"
    if ! vm_exec test -f "/home/$VM_USER/.bashrc"; then
        echo "Initializing home directory..."
        vm_exec sh -c "cp /etc/skel/.bashrc /etc/skel/.profile /etc/skel/.bash_logout ~ 2>/dev/null || true"
    fi
    vm_exec sh -c 'mkdir -p ~/.ssh && chmod 700 ~/.ssh'
    if ! vm_exec sh -lc 'command -v openclaw >/dev/null 2>&1'; then
        install_openclaw
    fi
}

install_openclaw() {
    echo "Installing openclaw..."
    podman exec "$CONTAINER_NAME" sh -lc 'set -e; npm install -g openclaw@latest; command -v openclaw >/dev/null 2>&1'
}

# ── Lifecycle ───────────────────────────────────────────────────────────────
is_running() {
    podman container exists "$CONTAINER_NAME" 2>/dev/null \
        && [ "$(podman inspect -f '{{.State.Running}}' "$CONTAINER_NAME" 2>/dev/null)" = "true" ]
}

container_exists() {
    podman container exists "$CONTAINER_NAME" 2>/dev/null
}

create_container() {
    local image="$1"
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

ensure_user_home_dir_exists() {
    mkdir -p "$USER_HOME_DIR"
}

start_existing_container_process() {
    podman start "$CONTAINER_NAME"
}

wait_for_container_services() {
    wait_for_ready
    wait_for_ssh_port
}

initialize_container_state() {
    init_home_dir
}

bootstrap_new_container() {
    run_step "Build image" build_image
    run_step "Prepare user home mount" ensure_user_home_dir_exists
    run_step "Create container" create_container "$IMAGE_NAME"
    run_step "Wait for container services" wait_for_container_services
    run_step "Initialize container state" initialize_container_state
}

resume_existing_container() {
    run_step "Start existing container" start_existing_container_process
    run_step "Wait for container services" wait_for_container_services
    run_step "Initialize container state" initialize_container_state
}

start_container() {
    if is_running; then
        echo "Container '$CONTAINER_NAME' already running."
        return 0
    fi

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
    if is_running; then
        echo "Container running."
        podman ps --filter "name=$CONTAINER_NAME" --format "table {{.ID}}\t{{.Status}}\t{{.Ports}}"
    else
        echo "Container not running."
    fi
}

show_logs() {
    container_exists || { echo "Container does not exist. Start it first."; return 1; }
    podman logs "$CONTAINER_NAME" 2>&1
}

update_openclaw() {
    is_running || { echo "Container not running. Start it first."; return 1; }
    run_step "Install latest OpenClaw" install_openclaw
    run_step "Restart container" podman restart "$CONTAINER_NAME"
    run_step "Wait for container services" wait_for_container_services
    run_step "Initialize container state" initialize_container_state
}

show_version() {
    is_running || { echo "Container not running. Start it first."; return 1; }
    vm_exec sh -lc 'openclaw --version 2>/dev/null || npm list -g openclaw --depth=0 2>/dev/null | tail -n 1 || echo "unknown"'
}

backup_container() {
    container_exists || { echo "No container to backup."; return 1; }
    local was_running=0
    if is_running; then
        was_running=1
        stop_container
    fi
    local ts
    ts=$(date +%Y%m%d_%H%M%S)
    local out="$DIR/openclaw_backup_${ts}.tar.gz"
    local tmp
    tmp=$(create_tmp_dir)

    echo "Exporting container..."
    podman export "$CONTAINER_NAME" > "$tmp/container.tar" || {
        cleanup_tmp_dir "$tmp"
        [ "$was_running" -eq 1 ] && start_container
        return 1
    }
    echo "Archiving data..."
    podman unshare tar cf "$tmp/data.tar" -C "$DATA_DIR" . || {
        cleanup_tmp_dir "$tmp"
        [ "$was_running" -eq 1 ] && start_container
        return 1
    }
    tar czf "$out" -C "$tmp" container.tar data.tar || {
        cleanup_tmp_dir "$tmp"
        [ "$was_running" -eq 1 ] && start_container
        return 1
    }
    cleanup_tmp_dir "$tmp"
    [ "$was_running" -eq 1 ] && start_container

    echo "Backup saved: $out ($(du -h "$out" | cut -f1))"
}

restore_container() {
    local archive="$1"
    [ -f "$archive" ] || { echo "File not found: $archive"; return 1; }
    local ts
    ts=$(date +%Y%m%d_%H%M%S)
    local tmp
    tmp=$(create_tmp_dir)

    tar xzf "$archive" -C "$tmp"
    if [ ! -f "$tmp/container.tar" ] || [ ! -f "$tmp/data.tar" ]; then
        cleanup_tmp_dir "$tmp"
        echo "Invalid backup archive."
        return 1
    fi

    if container_exists; then
        stop_container 2>/dev/null || true
        podman rename "$CONTAINER_NAME" "${CONTAINER_NAME}_old_${ts}"
    fi
    [ -d "$DATA_DIR" ] && podman unshare mv "$DATA_DIR" "${DATA_DIR}_old_${ts}"

    mkdir -p "$DATA_DIR"
    podman unshare tar xf "$tmp/data.tar" -C "$DATA_DIR"

    local img="${IMAGE_NAME}:restored_${ts}"
    podman import "$tmp/container.tar" "$img" >/dev/null || {
        cleanup_tmp_dir "$tmp"
        return 1
    }
    create_container "$img" >/dev/null || {
        podman rmi -f "$img" >/dev/null 2>&1 || true
        cleanup_tmp_dir "$tmp"
        return 1
    }
    wait_for_ready || {
        destroy_container >/dev/null 2>&1 || true
        podman rmi -f "$img" >/dev/null 2>&1 || true
        cleanup_tmp_dir "$tmp"
        return 1
    }
    init_home_dir
    wait_for_ssh_port || {
        destroy_container >/dev/null 2>&1 || true
        podman rmi -f "$img" >/dev/null 2>&1 || true
        cleanup_tmp_dir "$tmp"
        return 1
    }
    cleanup_tmp_dir "$tmp"
    echo "Restore complete. Old container/data saved with _old_${ts} suffix."
}

setup_host() {
    sudo loginctl enable-linger "$(whoami)"
    systemctl --user enable podman-restart.service
    echo "Verifying..."
    loginctl show-user "$(whoami)" | grep Linger
    systemctl --user is-enabled podman-restart.service
    echo "Host setup complete. Containers with --restart=always will auto-start after reboot."
}

# ── Entrypoint ──────────────────────────────────────────────────────────────
case "${1:-start}" in
    start)   start_container ;;
    stop)    stop_container ;;
    restart) stop_container; start_container ;;
    status)  status_container ;;
    shell)   is_running || { echo "Container not running. Start it first."; exit 1; }; shift; if [ $# -eq 0 ]; then podman exec -it -u "$VM_USER" "$CONTAINER_NAME" /bin/bash; elif [ "${1:-}" = "--" ]; then shift; vm_exec "$@"; else vm_exec bash -lc "$*"; fi ;;
    destroy) destroy_container ;;
    rebuild) rebuild_image ;;
    update)  update_openclaw ;;
    version) show_version ;;
    logs)    show_logs ;;
    backup)  backup_container ;;
    restore) shift; restore_container "${1:?Usage: $0 restore <backup_file>}" ;;
    setup)   setup_host ;;
    *)       print_help; exit 1 ;;
esac
