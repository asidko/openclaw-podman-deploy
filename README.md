# OpenClaw VM

Deploy and run [OpenClaw](https://openclaw.org) in under a minute. One script, one command — production-ready gateway running in an isolated Podman container with auto-restart, persistent storage, and zero root required.

## Quick Start

```sh
# install podman
sudo apt install -y podman    # Debian/Ubuntu
sudo dnf install -y podman    # Fedora/RHEL

# start (builds image on first run)
./run.sh start

# open a shell inside the container
./run.sh shell
```

## Commands

```
./run.sh start          Start container (creates on first run, resumes if stopped)
./run.sh stop           Stop container (preserves state)
./run.sh restart        Stop + start
./run.sh status         Check if container is running
./run.sh shell [cmd]    Open shell or run a command inside container
./run.sh logs           Show container logs
./run.sh backup         Export container + data to timestamped .tar.gz
./run.sh restore <file> Restore from backup archive
./run.sh destroy        Remove container (data in .data/ is kept)
./run.sh rebuild        Destroy + rebuild image from scratch
./run.sh setup          Enable auto-restart after host reboot
```

## How It Works

- **Single file**: `run.sh` generates the Containerfile inline and manages the full lifecycle
- **Persistent home**: `/home/user` is mounted to `.data/home/` — survives stop/start and destroy/rebuild
- **Auto-restart**: `openclaw gateway` restarts with exponential backoff (1s to 60s); container restarts via `--restart=always`
- **Network isolated**: `slirp4netns` with host loopback disabled — container cannot reach host services
- **Rootless**: runs entirely without root via Podman user namespaces

## Backup & Restore

```sh
./run.sh backup
# creates openclaw_backup_20260314_120000.tar.gz

./run.sh restore openclaw_backup_20260314_120000.tar.gz
# existing container/data renamed with _old_ suffix, not deleted
```

## Auto-Restart After Reboot

Run once on the host to enable container auto-start after reboot:

```sh
./run.sh setup
```

This enables systemd linger and `podman-restart.service` for your user.

## Pre-installed Tools

Python 3, Node.js 22, git, uv, gh, ripgrep, fd, fzf, jq, yq, build-essential, and more. Full list in the generated Containerfile (see `run.sh`).
