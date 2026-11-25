#!/usr/bin/env bash
# Build and install patched Qualcomm Venus VA-API driver (Release -O3) for xiaomi-elish.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PATCH_FILE="$REPO_ROOT/vaapi/patches/venus-vaapi-driver-decode-fix.patch"

DRY_RUN=0
FORCE=0
UPSTREAM_URL="https://github.com/snowf14k3/venus-vaapi-driver.git"

for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
    --force)   FORCE=1 ;;
    -h|--help)
      echo "Usage: $0 [--dry-run] [--force]"
      echo "  Clones snowf14k3/venus-vaapi-driver, applies vaapi/patches/venus-vaapi-driver-decode-fix.patch"
      echo "  (if not already merged upstream), builds Release (-O3), backs up the existing driver,"
      echo "  installs /usr/lib/aarch64-linux-gnu/dri/venus_drv_video.so + msm_drv_video.so symlink."
      exit 0
      ;;
    *) echo "Unknown option: $arg" >&2; exit 2 ;;
  esac
done

VENUS_FOUND=0
for v in /sys/class/video4linux/video*/name; do
  [[ -r "$v" ]] || continue
  if grep -qi 'venus.*dec' "$v" 2>/dev/null; then
    VENUS_FOUND=1
    break
  fi
done
if [[ "$VENUS_FOUND" -eq 0 && "$FORCE" -eq 0 ]]; then
  echo "WARNING: No qcom-venus V4L2 decoder node detected in /sys/class/video4linux." >&2
  echo "         Re-run with --force to build anyway." >&2
  exit 1
fi

DRI_DIR="/usr/lib/aarch64-linux-gnu/dri"
if [[ "$DRY_RUN" -eq 1 ]]; then
  echo "[DRY-RUN] Would clone $UPSTREAM_URL"
  echo "[DRY-RUN] Would apply $PATCH_FILE (if not already present upstream)"
  echo "[DRY-RUN] Would run: meson setup build --prefix=/usr --buildtype=release && ninja -C build"
  echo "[DRY-RUN] Would install -> $DRI_DIR/venus_drv_video.so and symlink $DRI_DIR/msm_drv_video.so"
  exit 0
fi

MISSING=()
for tool in git meson ninja pkg-config cc; do
  command -v "$tool" >/dev/null 2>&1 || MISSING+=("$tool")
done
if ! pkg-config --exists libva libdrm 2>/dev/null; then
  MISSING+=("libva-dev/libdrm-dev")
fi
if [[ "${#MISSING[@]}" -gt 0 ]]; then
  echo "ERROR: Missing build dependencies: ${MISSING[*]}" >&2
  echo "Install with:" >&2
  echo "  sudo apt install git meson ninja-build build-essential pkg-config libva-dev libdrm-dev vainfo" >&2
  exit 1
fi

WORKDIR="$(mktemp -d -t elish-venus-vaapi-XXXXXX)"
trap 'rm -rf "$WORKDIR"' EXIT

echo "Cloning $UPSTREAM_URL into $WORKDIR..."
git clone --depth 20 "$UPSTREAM_URL" "$WORKDIR/venus-vaapi-driver"

cd "$WORKDIR/venus-vaapi-driver"
if grep -q 'decode_sequence' src/venus_driver.h 2>/dev/null && grep -q 'V4L2_CID_MPEG_VIDEO_DEC_DISPLAY_DELAY' src/venus_v4l2.c 2>/dev/null; then
  echo "Upstream already includes the decode-order & surface-tag fix; skipping local patch."
else
  echo "Applying patch: $PATCH_FILE"
  git apply --check "$PATCH_FILE"
  git apply "$PATCH_FILE"
fi

echo "Building Release (-O3) with Meson + Ninja..."
meson setup build --prefix=/usr --buildtype=release
ninja -C build

SO_BUILT="$(find build -maxdepth 3 -name 'venus_drv_video.so' -type f | head -n 1)"
if [[ -z "$SO_BUILT" || ! -f "$SO_BUILT" ]]; then
  echo "ERROR: Built venus_drv_video.so not found under build/" >&2
  exit 1
fi

BACKUP_ROOT="${XDG_STATE_HOME:-$HOME/.local/state}/elish-linux-tuning-backup-$(date +%Y%m%d-%H%M%S)"
if [[ -f "$DRI_DIR/venus_drv_video.so" ]]; then
  mkdir -p "$BACKUP_ROOT"
  cp -a "$DRI_DIR/venus_drv_video.so" "$BACKUP_ROOT/venus_drv_video.so.orig"
  echo "Backed up previous driver -> $BACKUP_ROOT/venus_drv_video.so.orig"
fi

sudo install -D -m 0755 "$SO_BUILT" "$DRI_DIR/venus_drv_video.so"
sudo ln -sfn venus_drv_video.so "$DRI_DIR/msm_drv_video.so"

ls -lh "$DRI_DIR/venus_drv_video.so" "$DRI_DIR/msm_drv_video.so"

if command -v vainfo >/dev/null 2>&1; then
  echo ""
  echo "Verifying with vainfo..."
  LIBVA_DRIVER_NAME=venus vainfo 2>&1 | grep -E 'Driver version|VAProfile(H264|VP8|VP9|HEVC)' || true
fi

echo ""
echo "SUCCESS: Patched Venus VA-API driver installed."
echo "Next steps:"
echo "  1. Add Chrome flags from tuning/desktop/chrome-flags.txt to your Chrome launcher."
echo "  2. Fully quit Chrome (Ctrl+Shift+Q) and relaunch so the GPU process reloads venus_drv_video.so."
