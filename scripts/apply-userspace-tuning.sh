#!/usr/bin/env bash
# Modular, idempotent userspace & sysctl/tmpfiles/udev/cgroup installer for xiaomi-elish.
# Supports --dry-run (never requires sudo) and creates timestamped backups before overwriting.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

DRY_RUN=0
MOD_RESPONSIVENESS=0
MOD_CGROUP=0
MOD_ZRAM=0
MOD_AUDIO=0
MOD_AUDIO_RIGHT_SLOT=0
MOD_DISPLAY_8BPC=0
MOD_KEYBOARD=0
MOD_WEBKIT_SHM=0
MOD_BLACKLIST_FASTRPC=0
ANY_MOD=0

usage() {
  cat << 'EOF'
Usage: ./scripts/apply-userspace-tuning.sh [OPTIONS]

Options:
  --dry-run            Preview every file copy and service action without modifying the system
  --all                Apply core safe modules:
                         --responsiveness --cgroup --zram --audio --keyboard --blacklist-fastrpc
  --responsiveness     sysctl (VM/ZRAM/BBR+FQ), tmpfiles (MGLRU, GPU 500ms, THP, stock min_freq),
                       udev GPU PM rule, TEO cpuidle systemd service
  --cgroup             systemd user@.service cpuset delegation + big/little slice/scope rules
                       + portable (%U) app.slice uclamp.min=35% user service
  --zram               zram0 idle/huge zstd recompression script + timer
  --audio              WirePlumber S16LE/48kHz speaker rule (stops q6asm-dai -22 log storms)
  --audio-right-slot   Install & enable elish-right-slot.service (CS35L41 stereo slot + PLL daemon;
                       opt-in, requires i2c-tools, python3, and CS35L41 kernel patch)
  --display-8bpc       Compile & install libelish-scanout-8bpc.so + GNOME 50 Shell drop-in (opt-in)
  --keyboard           Install & enable elish-keyboard-pinctrl.service (33c0000.pinctrl rebind)
  --webkit-shm         Install ~/.config/environment.d/95-webkit-gpu-shm.conf (opt-in)
  --blacklist-fastrpc  Install /etc/modprobe.d/blacklist-fastrpc.conf
  -h, --help           Show this help

Run as your normal desktop user (NOT sudo ./scripts/...). The script invokes sudo only for /etc and /usr/local/sbin.
EOF
}

for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
    --all)
      MOD_RESPONSIVENESS=1; MOD_CGROUP=1; MOD_ZRAM=1; MOD_AUDIO=1
      MOD_KEYBOARD=1; MOD_BLACKLIST_FASTRPC=1; ANY_MOD=1
      ;;
    --responsiveness)    MOD_RESPONSIVENESS=1; ANY_MOD=1 ;;
    --cgroup)            MOD_CGROUP=1; ANY_MOD=1 ;;
    --zram)              MOD_ZRAM=1; ANY_MOD=1 ;;
    --audio)             MOD_AUDIO=1; ANY_MOD=1 ;;
    --audio-right-slot)  MOD_AUDIO_RIGHT_SLOT=1; ANY_MOD=1 ;;
    --display-8bpc)      MOD_DISPLAY_8BPC=1; ANY_MOD=1 ;;
    --keyboard)          MOD_KEYBOARD=1; ANY_MOD=1 ;;
    --webkit-shm)        MOD_WEBKIT_SHM=1; ANY_MOD=1 ;;
    --blacklist-fastrpc) MOD_BLACKLIST_FASTRPC=1; ANY_MOD=1 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $arg" >&2; usage >&2; exit 2 ;;
  esac
done

if [[ "$ANY_MOD" -eq 0 ]]; then
  if [[ "$DRY_RUN" -eq 1 ]]; then
    # Default --dry-run with no module flags previews --all
    MOD_RESPONSIVENESS=1; MOD_CGROUP=1; MOD_ZRAM=1; MOD_AUDIO=1
    MOD_KEYBOARD=1; MOD_BLACKLIST_FASTRPC=1; ANY_MOD=1
  else
    usage >&2
    exit 2
  fi
fi

if [[ "$DRY_RUN" -eq 0 && "$(id -u)" -eq 0 ]]; then
  echo "ERROR: Please run this script as your normal desktop user (not as root)." >&2
  echo "       It will use sudo only for system-wide paths under /etc and /usr/local/sbin." >&2
  exit 1
fi

BACKUP_ROOT="${XDG_STATE_HOME:-$HOME/.local/state}/elish-linux-tuning-backup-$(date +%Y%m%d-%H%M%S)"
BACKUP_CREATED=0

ensure_backup_dir() {
  if [[ "$DRY_RUN" -eq 0 && "$BACKUP_CREATED" -eq 0 ]]; then
    mkdir -p "$BACKUP_ROOT"
    BACKUP_CREATED=1
  fi
}

backup_file() {
  local dst="$1"
  local use_sudo="$2"
  [[ -e "$dst" || -L "$dst" ]] || return 0
  if [[ "$DRY_RUN" -eq 1 ]]; then
    echo "  [DRY-RUN] backup existing $dst -> $BACKUP_ROOT/${dst#/}"
    return 0
  fi
  ensure_backup_dir
  local rel="${dst#/}"
  local bdst="$BACKUP_ROOT/$rel"
  mkdir -p "$(dirname "$bdst")"
  if [[ "$use_sudo" -eq 1 ]]; then
    sudo cp -a "$dst" "$bdst"
    sudo chown "$(id -u):$(id -g)" "$bdst"
  else
    cp -a "$dst" "$bdst"
  fi
}

install_sys_file() {
  local src="$1"
  local dst="$2"
  local mode="${3:-0644}"
  if [[ "$DRY_RUN" -eq 1 ]]; then
    echo "[DRY-RUN] sudo install -m $mode $src -> $dst"
    backup_file "$dst" 1
    return 0
  fi
  backup_file "$dst" 1
  sudo install -D -m "$mode" "$src" "$dst"
  echo "[INSTALLED] $dst"
}

install_user_file() {
  local src="$1"
  local dst="$2"
  local mode="${3:-0644}"
  if [[ "$DRY_RUN" -eq 1 ]]; then
    echo "[DRY-RUN] install -m $mode $src -> $dst"
    backup_file "$dst" 0
    return 0
  fi
  backup_file "$dst" 0
  install -D -m "$mode" "$src" "$dst"
  echo "[INSTALLED] $dst"
}

run_cmd() {
  if [[ "$DRY_RUN" -eq 1 ]]; then
    echo "[DRY-RUN] $*"
  else
    "$@"
  fi
}

echo "=== elish-linux-tuning: apply-userspace-tuning.sh (dry_run=$DRY_RUN) ==="

if [[ "$MOD_RESPONSIVENESS" -eq 1 ]]; then
  echo ""
  echo "--- Module: responsiveness (sysctl, tmpfiles, udev GPU PM, TEO cpuidle) ---"
  install_sys_file "$REPO_ROOT/tuning/sysctl.d/99-vm-zram-parameters.conf" /etc/sysctl.d/99-vm-zram-parameters.conf 0644
  install_sys_file "$REPO_ROOT/tuning/sysctl.d/99-elish-net.conf" /etc/sysctl.d/99-elish-net.conf 0644
  install_sys_file "$REPO_ROOT/tuning/tmpfiles.d/99-elish-responsiveness.conf" /etc/tmpfiles.d/99-elish-responsiveness.conf 0644
  install_sys_file "$REPO_ROOT/tuning/tmpfiles.d/99-elish-thp.conf" /etc/tmpfiles.d/99-elish-thp.conf 0644
  install_sys_file "$REPO_ROOT/tuning/udev/rules.d/91-elish-gpu-pm.rules" /etc/udev/rules.d/91-elish-gpu-pm.rules 0644
  install_sys_file "$REPO_ROOT/tuning/systemd/elish-kernel-tune.service" /etc/systemd/system/elish-kernel-tune.service 0644
  if [[ "$DRY_RUN" -eq 1 ]]; then
    echo "[DRY-RUN] sudo sysctl --system"
  else
    sudo sysctl --system >/dev/null || true
  fi
  run_cmd sudo systemd-tmpfiles --create /etc/tmpfiles.d/99-elish-responsiveness.conf /etc/tmpfiles.d/99-elish-thp.conf || true
  run_cmd sudo udevadm control --reload-rules || true
  run_cmd sudo systemctl daemon-reload
  run_cmd sudo systemctl enable --now elish-kernel-tune.service || true
fi

if [[ "$MOD_CGROUP" -eq 1 ]]; then
  echo ""
  echo "--- Module: cgroup v2 big.LITTLE isolation & uclamp ---"
  install_sys_file "$REPO_ROOT/scheduler/etc/systemd/system/user@.service.d/10-elish-delegate.conf" \
    /etc/systemd/system/user@.service.d/10-elish-delegate.conf 0644

  UDIR="$HOME/.config/systemd/user"
  install_user_file "$REPO_ROOT/scheduler/user-systemd/session.slice.d/10-elish-big-cores.conf" \
    "$UDIR/session.slice.d/10-elish-big-cores.conf" 0644
  install_user_file "$REPO_ROOT/scheduler/user-systemd/background.slice.d/10-elish-little-cores.conf" \
    "$UDIR/background.slice.d/10-elish-little-cores.conf" 0644
  install_user_file "$REPO_ROOT/scheduler/user-systemd/app.slice.d/10-elish-priority.conf" \
    "$UDIR/app.slice.d/10-elish-priority.conf" 0644
  install_user_file "$REPO_ROOT/scheduler/user-systemd/app-com.google.Chrome-.scope.d/10-elish-big-cores.conf" \
    "$UDIR/app-com.google.Chrome-.scope.d/10-elish-big-cores.conf" 0644
  install_user_file "$REPO_ROOT/scheduler/user-systemd/app-gnome-google\x2dchrome-.scope.d/10-elish-big-cores.conf" \
    "$UDIR/app-gnome-google\x2dchrome-.scope.d/10-elish-big-cores.conf" 0644
  install_user_file "$REPO_ROOT/scheduler/user-systemd/elish-uclamp.service" \
    "$UDIR/elish-uclamp.service" 0644

  run_cmd sudo systemctl daemon-reload
  run_cmd systemctl --user daemon-reload
  run_cmd systemctl --user enable --now elish-uclamp.service || true
  echo "Note: user@.service Delegate=cpuset takes full effect after next login/reboot if not previously delegated."
fi

if [[ "$MOD_ZRAM" -eq 1 ]]; then
  echo ""
  echo "--- Module: zram0 cold-page zstd recompression ---"
  install_sys_file "$REPO_ROOT/tuning/zram/elish-zram-recomp.sh" /usr/local/sbin/elish-zram-recomp.sh 0755
  install_sys_file "$REPO_ROOT/tuning/zram/elish-zram-recomp.service" /etc/systemd/system/elish-zram-recomp.service 0644
  install_sys_file "$REPO_ROOT/tuning/zram/elish-zram-recomp.timer" /etc/systemd/system/elish-zram-recomp.timer 0644
  run_cmd sudo systemctl daemon-reload
  run_cmd sudo systemctl enable --now elish-zram-recomp.timer || true
  echo "Note: See tuning/zram/armbian-zram-config.snippet to configure LZ4 primary swap in /etc/default/armbian-zram-config."
fi

if [[ "$MOD_AUDIO" -eq 1 ]]; then
  echo ""
  echo "--- Module: audio (WirePlumber S16LE/48kHz rule) ---"
  install_user_file "$REPO_ROOT/tuning/audio/51-elish-speaker-s16le.conf" \
    "$HOME/.config/wireplumber/wireplumber.conf.d/51-elish-speaker-s16le.conf" 0644
  run_cmd systemctl --user restart wireplumber.service || true
fi

if [[ "$MOD_AUDIO_RIGHT_SLOT" -eq 1 ]]; then
  echo ""
  echo "--- Module: audio-right-slot (CS35L41 stereo slot & PLL helper) ---"
  if [[ "$DRY_RUN" -eq 0 ]] && ! command -v i2ctransfer >/dev/null 2>&1; then
    echo "ERROR: i2ctransfer not found. Install with: sudo apt install i2c-tools" >&2
    exit 1
  fi
  install_sys_file "$REPO_ROOT/tuning/audio/elish-right-slot.sh" /usr/local/sbin/elish-right-slot.sh 0755
  install_sys_file "$REPO_ROOT/tuning/audio/elish-right-slot.service" /etc/systemd/system/elish-right-slot.service 0644
  run_cmd sudo systemctl daemon-reload
  run_cmd sudo systemctl enable --now elish-right-slot.service
fi

if [[ "$MOD_DISPLAY_8BPC" -eq 1 ]]; then
  echo ""
  echo "--- Module: display-8bpc (GNOME 50 8-bit scanout filter) ---"
  SO_DST="$HOME/.local/lib/libelish-scanout-8bpc.so"
  if [[ "$DRY_RUN" -eq 1 ]]; then
    echo "[DRY-RUN] compile $REPO_ROOT/tuning/display/elish-8bpc.c -> $SO_DST"
  else
    if ! command -v gcc >/dev/null 2>&1; then
      echo "ERROR: gcc not found. Install with: sudo apt install gcc libdrm-dev" >&2
      exit 1
    fi
    DRM_CFLAGS="$(pkg-config --cflags libdrm 2>/dev/null || echo '-I/usr/include/libdrm')"
    mkdir -p "$HOME/.local/lib"
    backup_file "$SO_DST" 0
    # shellcheck disable=SC2086
    gcc -O2 -shared -fPIC $DRM_CFLAGS -o "$SO_DST" "$REPO_ROOT/tuning/display/elish-8bpc.c" -ldl
    echo "[BUILT] $SO_DST"
  fi
  install_user_file "$REPO_ROOT/tuning/display/org.gnome.Shell-8bpc.conf.template" \
    "$HOME/.config/systemd/user/org.gnome.Shell@.service.d/8bpc.conf" 0644
  run_cmd systemctl --user daemon-reload
  echo "Note: Log out and back in to reload GNOME Shell. Remove MUTTER_DEBUG_USE_KMS_MODIFIERS=0 if set."
fi

if [[ "$MOD_KEYBOARD" -eq 1 ]]; then
  echo ""
  echo "--- Module: keyboard (LPASS LPI 33c0000.pinctrl rebind) ---"
  install_sys_file "$REPO_ROOT/tuning/keyboard/elish-keyboard-pinctrl.sh" /usr/local/sbin/elish-keyboard-pinctrl.sh 0755
  install_sys_file "$REPO_ROOT/tuning/keyboard/elish-keyboard-pinctrl.service" /etc/systemd/system/elish-keyboard-pinctrl.service 0644
  run_cmd sudo systemctl daemon-reload
  run_cmd sudo systemctl enable --now elish-keyboard-pinctrl.service || true
fi

if [[ "$MOD_WEBKIT_SHM" -eq 1 ]]; then
  echo ""
  echo "--- Module: webkit-shm (Adreno 650 WebKitGTK SHM transport) ---"
  install_user_file "$REPO_ROOT/tuning/desktop/95-webkit-gpu-shm.conf" \
    "$HOME/.config/environment.d/95-webkit-gpu-shm.conf" 0644
fi

if [[ "$MOD_BLACKLIST_FASTRPC" -eq 1 ]]; then
  echo ""
  echo "--- Module: blacklist-fastrpc ---"
  install_sys_file "$REPO_ROOT/kernel/modprobe.d/blacklist-fastrpc.conf" /etc/modprobe.d/blacklist-fastrpc.conf 0644
fi

echo ""
if [[ "$DRY_RUN" -eq 1 ]]; then
  echo "Dry run complete. No files were modified."
else
  if [[ "$BACKUP_CREATED" -eq 1 ]]; then
    echo "Backups of overwritten files saved in: $BACKUP_ROOT"
  fi
  echo "Done. Run ./scripts/verify.sh to confirm active state."
fi
