#!/usr/bin/env bash
# Read-only hardware, kernel, and desktop pre-flight probe for Xiaomi Mi Pad 5 Pro (xiaomi-elish).
set -euo pipefail

STRICT=0
for arg in "$@"; do
  case "$arg" in
    --strict) STRICT=1 ;;
    -h|--help)
      echo "Usage: $0 [--strict]"
      echo "  Read-only hardware & kernel capability check for xiaomi-elish."
      echo "  --strict   Exit non-zero if hardware does not match aarch64 + xiaomi-elish."
      exit 0
      ;;
    *) echo "Unknown option: $arg" >&2; exit 2 ;;
  esac
done

read_sys() {
  local p="$1"
  if [[ -r "$p" ]]; then
    tr '\0\n' '  ' < "$p" | sed 's/[[:space:]]\+/ /g; s/[[:space:]]*$//'
  else
    echo "N/A"
  fi
}

ARCH="$(uname -m)"
KERNEL="$(uname -r)"
MODEL="$(read_sys /proc/device-tree/model)"
COMPAT="$(read_sys /proc/device-tree/compatible)"

IS_ELISH=0
if [[ "$ARCH" == "aarch64" ]] && [[ "$MODEL$COMPAT" =~ [Ee]lish|Mi\ Pad\ 5\ Pro ]]; then
  IS_ELISH=1
fi

PANEL="unknown"
if [[ "$MODEL$COMPAT" =~ [Cc][Ss][Oo][Tt] ]]; then
  PANEL="CSOT (sm8250-xiaomi-elish-csot.dtb)"
elif [[ "$MODEL$COMPAT" =~ [Bb][Oo][Ee] ]]; then
  PANEL="BOE (sm8250-xiaomi-elish-boe.dtb)"
fi

echo "=== elish-linux-tuning: Device Pre-Flight Check ==="
echo "Architecture        : $ARCH"
echo "DT Model            : $MODEL"
echo "DT Compatible       : $COMPAT"
echo "Detected Panel      : $PANEL"
echo "Kernel              : $KERNEL ($(uname -v | awk '{print $1, $2, $3, $4}'))"
echo ""

echo "--- CPU & Scheduler ---"
for p in 0 4 7; do
  if [[ -d "/sys/devices/system/cpu/cpufreq/policy${p}" ]]; then
    mn="$(read_sys /sys/devices/system/cpu/cpufreq/policy${p}/scaling_min_freq)"
    mx="$(read_sys /sys/devices/system/cpu/cpufreq/policy${p}/scaling_max_freq)"
    av="$(read_sys /sys/devices/system/cpu/cpufreq/policy${p}/cpuinfo_max_freq)"
    echo "cpufreq policy${p}     : min=${mn} kHz  max=${mx} kHz  hw_max=${av} kHz"
  fi
done
echo "cpuidle governor    : $(read_sys /sys/devices/system/cpu/cpuidle/current_governor) (avail: $(read_sys /sys/devices/system/cpu/cpuidle/available_governors))"
if [[ -d /sys/kernel/sched_ext ]]; then
  echo "sched_ext           : SUPPORTED (state=$(read_sys /sys/kernel/sched_ext/state), ops=$(read_sys /sys/kernel/sched_ext/root/ops))"
else
  echo "sched_ext           : NOT SUPPORTED in current kernel (need CONFIG_SCHED_CLASS_EXT=y)"
fi
UCLAMP_PATH="/sys/fs/cgroup/user.slice/user-$(id -u).slice/user@$(id -u).service/app.slice/cpu.uclamp.min"
if [[ -e "$UCLAMP_PATH" ]]; then
  echo "cgroup uclamp.min   : SUPPORTED (app.slice=$(read_sys "$UCLAMP_PATH"))"
else
  echo "cgroup uclamp.min   : NOT EXPOSED ($UCLAMP_PATH missing)"
fi
echo ""

echo "--- Memory, ZRAM, Network & GPU PM ---"
echo "MGLRU min_ttl_ms    : $(read_sys /sys/kernel/mm/lru_gen/min_ttl_ms)"
echo "THP enabled         : $(read_sys /sys/kernel/mm/transparent_hugepage/enabled)"
echo "vm.swappiness       : $(read_sys /proc/sys/vm/swappiness)"
echo "vm.page-cluster     : $(read_sys /proc/sys/vm/page-cluster)"
echo "TCP congestion ctrl : $(read_sys /proc/sys/net/ipv4/tcp_congestion_control) (qdisc=$(read_sys /proc/sys/net/core/default_qdisc))"
if [[ -d /sys/block/zram0 ]]; then
  echo "zram0 comp_alg      : $(read_sys /sys/block/zram0/comp_algorithm)"
  echo "zram0 recomp_alg    : $(read_sys /sys/block/zram0/recomp_algorithm)"
fi
echo "Adreno autosuspend  : $(read_sys /sys/devices/platform/soc@0/3d00000.gpu/power/autosuspend_delay_ms) ms"
echo ""

echo "--- Video (Qualcomm Venus VA-API) ---"
VENUS_DEC="none"
for v in /sys/class/video4linux/video*/name; do
  [[ -r "$v" ]] || continue
  nm="$(cat "$v" 2>/dev/null || true)"
  if [[ "$nm" == *venus*dec* ]]; then
    VENUS_DEC="/dev/$(basename "$(dirname "$v")") ($nm)"
    break
  fi
done
echo "Venus V4L2 decoder  : $VENUS_DEC"
DRI_DIR="/usr/lib/aarch64-linux-gnu/dri"
if [[ -f "$DRI_DIR/venus_drv_video.so" ]]; then
  sz="$(stat -c '%s bytes, mtime %y' "$DRI_DIR/venus_drv_video.so" | cut -d. -f1)"
  echo "venus_drv_video.so  : PRESENT ($sz)"
else
  echo "venus_drv_video.so  : MISSING"
fi
if [[ -L "$DRI_DIR/msm_drv_video.so" ]]; then
  echo "msm_drv_video.so    : symlink -> $(readlink "$DRI_DIR/msm_drv_video.so")"
else
  echo "msm_drv_video.so    : NOT A SYMLINK"
fi
echo ""

echo "--- Display, Audio, Keyboard & Safety ---"
if [[ -f "$HOME/.config/systemd/user/org.gnome.Shell@.service.d/8bpc.conf" ]]; then
  echo "GNOME 8bpc preload  : configured"
else
  echo "GNOME 8bpc preload  : not configured"
fi
if grep -rqs '^MUTTER_DEBUG_USE_KMS_MODIFIERS=0' "$HOME/.config/environment.d" /etc/environment 2>/dev/null; then
  echo "WARNING             : MUTTER_DEBUG_USE_KMS_MODIFIERS=0 is active (disables Adreno UBWC/direct scanout)"
fi
if [[ -f "$HOME/.config/wireplumber/wireplumber.conf.d/51-elish-speaker-s16le.conf" || -f /etc/wireplumber/wireplumber.conf.d/51-elish-speaker-s16le.conf ]]; then
  echo "Speaker S16LE rule  : installed"
else
  echo "Speaker S16LE rule  : not installed"
fi
if systemctl --user is-active fluidsynth.service >/dev/null 2>&1; then
  echo "fluidsynth.service  : ACTIVE (consider masking if unused to avoid q6asm-dai error spam)"
else
  echo "fluidsynth.service  : inactive/masked"
fi
if [[ -e /sys/bus/platform/devices/33c0000.pinctrl/driver ]]; then
  echo "Keyboard pinctrl    : BOUND (33c0000.pinctrl -> $(basename "$(readlink /sys/bus/platform/devices/33c0000.pinctrl/driver)"))"
elif [[ -d /sys/bus/platform/devices/33c0000.pinctrl ]]; then
  echo "Keyboard pinctrl    : UNBOUND (magnetic keyboard USB PHY likely deferred!)"
else
  echo "Keyboard pinctrl    : device not present"
fi
if [[ -f /etc/modprobe.d/blacklist-fastrpc.conf ]]; then
  echo "fastrpc blacklist   : installed"
else
  echo "fastrpc blacklist   : MISSING (recommended before rebuilding initramfs!)"
fi

echo ""
if [[ "$IS_ELISH" -eq 1 ]]; then
  echo "RESULT: Verified Xiaomi Mi Pad 5 Pro (xiaomi-elish, aarch64)."
else
  echo "WARNING: This machine does not look like a Xiaomi Mi Pad 5 Pro (xiaomi-elish, aarch64)."
  if [[ "$STRICT" -eq 1 ]]; then
    exit 1
  fi
fi
