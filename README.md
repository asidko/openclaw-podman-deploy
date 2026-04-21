# OpenClaw Podman Deploy

[![lint](https://github.com/asidko/openclaw-podman-deploy/actions/workflows/lint.yml/badge.svg)](https://github.com/asidko/openclaw-podman-deploy/actions/workflows/lint.yml)

[OpenClaw](https://openclaw.org) is an open-source gateway for accessing AI models. This repo deploys it with one script — a production-ready gateway running in an isolated Podman container with auto-restart, persistent storage, and zero root required.

## 🤔 Why a container?

You could install OpenClaw on your host. A container gives you:

- **Blast radius = the container.** Gateway misbehaviour cannot touch your home, keys, or system.
- **Same environment everywhere.** Ubuntu 24.04 + known toolchain, identical on every Linux host.
- **Clean install/uninstall, one-command backup.** No host dotfiles or systemd leftovers; `./run.sh backup` → single tarball.
- **Network-isolated by default.** Host loopback blocked; opt in with `GATEWAY_PORT`.

## 📋 Requirements

- **OS**: Linux (Debian/Ubuntu, Fedora/RHEL, Arch)
- **Podman**: v4.0+ (rootless mode)
- **Disk**: ~2 GB for the container image

## 🚀 Quick Start

**1. Install Podman** (skip if already installed)

```sh
sudo apt install -y podman    # Debian/Ubuntu
sudo dnf install -y podman    # Fedora/RHEL
```

**2. Clone and start**

```sh
git clone https://github.com/asidko/openclaw-podman-deploy.git
cd openclaw-podman-deploy
./run.sh start    # ← builds image and starts container on first run
```

**3. Run the setup wizard** (configures the gateway inside the container)

```sh
./run.sh shell
openclaw setup
exit
```

**4. Enable auto-restart after reboot** (run once)

```sh
./run.sh setup    # ← enables systemd linger + podman-restart service
```

**5. Verify**

```sh
./run.sh status   # ← container + gateway state, last exit reason
./run.sh version  # ← installed openclaw version
```

After setup, the gateway runs automatically. On subsequent boots, the container starts on its own. SSH is also exposed on host port `2222` by default, so you can connect and forward ports through the container when needed.

## 🛠 Commands

```
./run.sh start               Start container (creates on first run, resumes if stopped)
./run.sh stop                Stop container (preserves state)
./run.sh restart             Stop + start
./run.sh status              Show container + gateway state, last exit reason
./run.sh shell               Interactive shell inside container
./run.sh shell -- cmd args…  Run argv directly (no shell parsing)
./run.sh shell -c 'string'   Run command string via bash -lc
./run.sh update              Update openclaw; print version diff
./run.sh version             Show installed openclaw version
./run.sh logs                Show container logs
./run.sh backup              Stop briefly, export to .backups/ (mode 0600)
./run.sh restore <file>      Restore container + data; rolls back on failure
./run.sh destroy             Remove container (data in .data/ is kept)
./run.sh rebuild [--yes]     Destroy + rebuild image from scratch
./run.sh setup               Enable auto-restart after host reboot
```

Environment overrides:

```
SSH_PORT=2222              Host port for container SSH
GATEWAY_PORT=3000          Expose gateway port from container to host
OPENCLAW_VERSION=latest    npm tag/version pinned at build + install time
```

## 📝 Logs

```sh
./run.sh logs
podman logs -f --tail 50 openclaw   # follow last 50 lines
```

Each `openclaw gateway exited (…)` supervisor line is timestamped, including restart count. `./run.sh status` surfaces the most recent exit line so a crash-looping gateway is visible at a glance.

If OpenClaw writes its own log files under the user home, they are also available under `.data/openclaw-user-home/` on the host.

## ⚙️ How It Works

- `run.sh` manages everything and generates the image definition on demand
- Your data lives in `.data/openclaw-user-home/` and survives restarts, destroys, and rebuilds
- On `start`, the entrypoint waits for a host-written sentinel before launching the gateway, so home-directory init can complete without a race
- If `openclaw gateway run` crashes, it auto-restarts with exponential backoff; backoff resets on a clean exit or after a healthy run
- If the host reboots, the container auto-starts
- SSH runs inside the container on port `2222` for shell access and tunneling
- Runs without root via Podman rootless mode
- Container logs are size-limited to avoid unbounded growth

## 🔐 SSH Access

The container runs an SSH server and exposes it on host loopback port `2222` by default:

```sh
ssh user@127.0.0.1 -p 2222
```

Default password inside the container:

```text
openclaw
```

Example port forwarding through the SSH connection:

```sh
ssh -N -L 3000:127.0.0.1:3000 user@127.0.0.1 -p 2222
```

You can then reach the forwarded service on your host at `127.0.0.1:3000`.

If you want `./run.sh shell` to preserve exact argv without going through `bash -lc`, use:

```sh
./run.sh shell -- python3 -m http.server 3456
```

## 🌐 Port Exposure

If you want to expose the gateway directly outside the container, set `GATEWAY_PORT` before starting:

```sh
GATEWAY_PORT=3000 ./run.sh start
```

This maps the same host/container port through Podman. SSH stays available on `2222`.

## 🛡 Security

The container is the blast radius, so OpenClaw guards that exist to protect a bare host can be relaxed inside without reaching your system:

```sh
./run.sh shell
openclaw config set agents.defaults.sandbox.mode off
openclaw config set tools.elevated.enabled true
openclaw config set tools.elevated.allowFrom.telegram '["111111111", "222222222"]'
openclaw config set tools.exec.host gateway
openclaw config set tools.exec.security full
openclaw config set tools.exec.ask off
cat > ~/.openclaw/exec-approvals.json <<'EOF'
{
  "version": 1,
  "defaults": {
    "security": "full",
    "ask": "off",
    "askFallback": "full"
  }
}
EOF
exit
```

Keep the `allowFrom` allowlist tight — it's still the authorization surface for anyone who can reach your bot, and the container doesn't change that.

## 💾 Backup & Restore

```sh
./run.sh backup
# creates .backups/openclaw_backup_20260314_120000.tar.gz (mode 0600)

./run.sh restore .backups/openclaw_backup_20260314_120000.tar.gz
# existing container/data renamed with _old_ suffix; auto-rollback on failure
```

Backups include the full container filesystem and user data, preserving custom packages and configuration. The archive contains `.ssh/`, `.config/`, `.npmrc` and similar — treat it as a secret. The backup flow briefly stops the container for a consistent snapshot, then starts it again if it was running before. Restore is atomic: on any failure (bad archive, tar error, container creation) the previous container and data are restored.

## 🧰 Pre-installed Tools

Python 3, Node.js 22, OpenClaw, git, uv, gh, ripgrep, fd, bat, fzf, jq, yq, tmux, sqlite3, build-essential, ffmpeg, rsync, rclone, moreutils (`ts`, `sponge`, `chronic`, …), poppler-utils (`pdftotext`, …), OpenSSH server, and more. The image also enables UTF-8 locales and includes a `user_sudo.sh` helper inside the container.
