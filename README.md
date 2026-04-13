# OpenClaw Podman Deploy

[![lint](https://github.com/asidko/openclaw-podman-deploy/actions/workflows/lint.yml/badge.svg)](https://github.com/asidko/openclaw-podman-deploy/actions/workflows/lint.yml)

[OpenClaw](https://openclaw.org) is an open-source gateway for accessing AI models. This repo deploys it with one script — a production-ready gateway running in an isolated Podman container with auto-restart, persistent storage, and zero root required.

## 📋 Requirements

- **OS**: Linux (Debian/Ubuntu, Fedora/RHEL, Arch). WSL works.
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
./run.sh status   # ← should show "Container running."
./run.sh version  # ← shows installed openclaw version
```

After setup, the gateway runs automatically. On subsequent boots, the container starts on its own. SSH is also exposed on host port `2222` by default, so you can connect and forward ports through the container when needed.

## 🛠 Commands

```
./run.sh start          Start container (creates on first run, resumes if stopped)
./run.sh stop           Stop container (preserves state)
./run.sh restart        Stop + start
./run.sh status         Check if container is running
./run.sh shell [cmd]    Open shell or run a command inside container
./run.sh update         Update openclaw to latest version
./run.sh version        Show installed openclaw version
./run.sh logs           Show container logs
./run.sh backup         Export container + data to timestamped .tar.gz
./run.sh restore <file> Restore from backup archive
./run.sh destroy        Remove container (data in .data/ is kept)
./run.sh rebuild        Destroy + rebuild image from scratch
./run.sh setup          Enable auto-restart after host reboot
```

## 📝 Logs

Gateway logs are available from the container directly:

```sh
podman logs openclaw
podman logs -f --tail 50 openclaw   # follow last 50 lines

# or via helper
./run.sh logs
```

If OpenClaw writes its own log files under the user home, they are also available under `.data/openclaw-user-home/` on the host.

## ⚙️ How It Works

- `run.sh` manages everything and generates the image definition on demand
- Your data lives in `.data/openclaw-user-home/` and survives restarts, destroys, and rebuilds
- If `openclaw gateway run` crashes, it auto-restarts with exponential backoff
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

## 💾 Backup & Restore

```sh
./run.sh backup
# creates openclaw_backup_20260314_120000.tar.gz

./run.sh restore openclaw_backup_20260314_120000.tar.gz
# existing container/data renamed with _old_ suffix, not deleted
```

Backups include the full container filesystem and user data, preserving any custom packages or modifications made inside the container.
The backup flow briefly stops the container to keep the archive consistent, then starts it again if it was running before.

## 🧰 Pre-installed Tools

Python 3, Node.js 22, OpenClaw, git, uv, gh, ripgrep, fd, fzf, jq, yq, tmux, sqlite3, build-essential, ffmpeg, OpenSSH server, and more. The image also enables UTF-8 locales and includes a `user_sudo.sh` helper inside the container.
