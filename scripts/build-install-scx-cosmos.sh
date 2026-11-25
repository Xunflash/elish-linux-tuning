#!/usr/bin/env bash
# Build and install scx_cosmos from sched-ext/scx and configure it for xiaomi-elish (SM8250-AC).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

SCX_TAG="v1.1.5"
DRY_RUN=0

for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
    --version=*) SCX_TAG="${arg#*=}" ;;
    -h|--help)
      echo "Usage: $0 [--version=v1.1.5] [--dry-run]"
      echo "  Clones sched-ext/scx, builds scx_cosmos (--release), installs /usr/local/bin/scx_cosmos,"
      echo "  installs /etc/default/scx + /etc/systemd/system/scx.service, and enables scx.service."
      exit 0
      ;;
    *) echo "Unknown option: $arg" >&2; exit 2 ;;
  esac
done

if [[ ! -d /sys/kernel/sched_ext ]]; then
  echo "ERROR: /sys/kernel/sched_ext does not exist." >&2
  echo "       Your current kernel ($(uname -r)) does not have CONFIG_SCHED_CLASS_EXT=y." >&2
  echo "       See docs/kernel-and-dts.md to build a sched_ext-enabled kernel, or use native EEVDF + cgroups." >&2
  exit 1
fi

if [[ "$DRY_RUN" -eq 1 ]]; then
  echo "[DRY-RUN] Would clone https://github.com/sched-ext/scx.git ($SCX_TAG)"
  echo "[DRY-RUN] Would run: cargo build --release -p scx_cosmos"
  echo "[DRY-RUN] Would install binary -> /usr/local/bin/scx_cosmos"
  echo "[DRY-RUN] Would install $REPO_ROOT/scheduler/etc/default/scx -> /etc/default/scx"
  echo "[DRY-RUN] Would install $REPO_ROOT/scheduler/etc/systemd/system/scx.service -> /etc/systemd/system/scx.service"
  echo "[DRY-RUN] Would run: sudo systemctl daemon-reload && sudo systemctl enable --now scx.service"
  exit 0
fi

MISSING=()
for tool in git cargo clang pkg-config; do
  command -v "$tool" >/dev/null 2>&1 || MISSING+=("$tool")
done
if [[ "${#MISSING[@]}" -gt 0 ]]; then
  echo "ERROR: Missing build tools: ${MISSING[*]}" >&2
  echo "Install prerequisites, e.g.:" >&2
  echo "  sudo apt install git clang llvm pkg-config libelf-dev libzstd-dev libseccomp-dev" >&2
  echo "  (and Rust toolchain via rustup / cargo)" >&2
  exit 1
fi

WORKDIR="$(mktemp -d -t elish-scx-build-XXXXXX)"
trap 'rm -rf "$WORKDIR"' EXIT

echo "Cloning sched-ext/scx ($SCX_TAG) into $WORKDIR..."
git clone --depth 1 --branch "$SCX_TAG" https://github.com/sched-ext/scx.git "$WORKDIR/scx"

echo "Building scx_cosmos (--release)..."
(cd "$WORKDIR/scx" && cargo build --release -p scx_cosmos)

BIN="$WORKDIR/scx/target/release/scx_cosmos"
if [[ ! -x "$BIN" ]]; then
  echo "ERROR: Expected binary not found at $BIN" >&2
  exit 1
fi

if command -v strip >/dev/null 2>&1; then
  strip "$BIN" || true
fi

BACKUP_ROOT="${XDG_STATE_HOME:-$HOME/.local/state}/elish-linux-tuning-backup-$(date +%Y%m%d-%H%M%S)"
for existing in /usr/local/bin/scx_cosmos /etc/default/scx /etc/systemd/system/scx.service; do
  if [[ -e "$existing" ]]; then
    mkdir -p "$BACKUP_ROOT/$(dirname "${existing#/}")"
    sudo cp -a "$existing" "$BACKUP_ROOT/${existing#/}"
    sudo chown "$(id -u):$(id -g)" "$BACKUP_ROOT/${existing#/}"
  fi
done

# Stop running scx.service cleanly before replacing binary
sudo systemctl stop scx.service 2>/dev/null || true

sudo install -D -m 0755 "$BIN" /usr/local/bin/scx_cosmos
sudo install -D -m 0644 "$REPO_ROOT/scheduler/etc/default/scx" /etc/default/scx
sudo install -D -m 0644 "$REPO_ROOT/scheduler/etc/systemd/system/scx.service" /etc/systemd/system/scx.service

sudo systemctl daemon-reload
sudo systemctl enable --now scx.service
sleep 2

STATE="$(cat /sys/kernel/sched_ext/state 2>/dev/null || echo unknown)"
OPS="$(cat /sys/kernel/sched_ext/root/ops 2>/dev/null || echo unknown)"
echo "sched_ext state : $STATE"
echo "sched_ext ops   : $OPS"
if [[ "$STATE" != "enabled" || "$OPS" != cosmos* ]]; then
  echo "WARNING: scx_cosmos did not report expected active ops; inspect: sudo journalctl -u scx.service -n 40" >&2
  exit 1
fi
echo "SUCCESS: scx_cosmos is active (-m 4-7 -P --time-preemption)."
