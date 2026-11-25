#!/usr/bin/env bash
# Post-apply health and regression verifier for xiaomi-elish optimizations.
set -euo pipefail

PASS=0
WARN=0
FAIL=0

ok()   { echo "[PASS] $*"; PASS=$((PASS + 1)); }
warn() { echo "[WARN] $*"; WARN=$((WARN + 1)); }
fail() { echo "[FAIL] $*"; FAIL=$((FAIL + 1)); }
info() { echo "[INFO] $*"; }

read_sys() {
  local p="$1"
  [[ -r "$p" ]] && tr -d '\0' < "$p" | tr '\n' ' ' | sed 's/[[:space:]]*$//' || echo ""
}

echo "=== elish-linux-tuning: Verification Report ==="

# 1. Hardware & Kernel
MODEL="$(read_sys /proc/device-tree/model)"
if [[ "$(uname -m)" == "aarch64" && "$MODEL" =~ [Ee]lish|Mi\ Pad\ 5\ Pro ]]; then
  ok "Hardware: $MODEL (aarch64, kernel $(uname -r))"
else
  warn "Hardware mismatch: $MODEL ($(uname -m))"
fi

P7_MAX="$(read_sys /sys/devices/system/cpu/cpufreq/policy7/cpuinfo_max_freq)"
if [[ "$P7_MAX" == "3187200" ]]; then
  ok "Prime core 3.19 GHz OPP active (policy7 hw_max=3187200 kHz)"
else
  info "Prime core hw_max=${P7_MAX:-unknown} kHz (stock SM8250-AC 3.19 GHz OPP patch not applied)"
fi

IDLE_GOV="$(read_sys /sys/devices/system/cpu/cpuidle/current_governor)"
if [[ "$IDLE_GOV" == "teo" ]]; then
  ok "cpuidle governor: teo"
else
  info "cpuidle governor: ${IDLE_GOV:-unknown} (teo recommended when supported)"
fi

# 2. sched_ext / scx_cosmos
if [[ -d /sys/kernel/sched_ext ]]; then
  SCX_STATE="$(read_sys /sys/kernel/sched_ext/state)"
  SCX_OPS="$(read_sys /sys/kernel/sched_ext/root/ops)"
  if [[ "$SCX_STATE" == "enabled" && "$SCX_OPS" == cosmos* ]]; then
    ok "sched_ext active: $SCX_OPS"
    P4_MIN="$(read_sys /sys/devices/system/cpu/cpufreq/policy4/scaling_min_freq)"
    P7_MIN="$(read_sys /sys/devices/system/cpu/cpufreq/policy7/scaling_min_freq)"
    if [[ "$P4_MIN" == "710400" && "$P7_MIN" == "844800" ]]; then
      ok "Stock big/prime min_freq preserved for scx_cosmos cpuperf (${P4_MIN}/${P7_MIN} kHz)"
    else
      warn "policy4/policy7 scaling_min_freq=${P4_MIN}/${P7_MIN} kHz (expected 710400/844800 with scx_cosmos)"
    fi
  elif [[ "$SCX_STATE" == "enabled" ]]; then
    info "sched_ext active with non-cosmos scheduler: $SCX_OPS"
  else
    warn "sched_ext kernel supported but currently disabled (state=$SCX_STATE)"
  fi
else
  info "Kernel does not support sched_ext (using native scheduler)"
fi

# 3. Cgroup v2 isolation
UID_NUM="$(id -u)"
CG_USER="/sys/fs/cgroup/user.slice/user-${UID_NUM}.slice/user@${UID_NUM}.service"
if grep -qw cpuset "$CG_USER/cgroup.controllers" 2>/dev/null; then
  ok "cgroup v2 cpuset delegated to user@${UID_NUM}.service"
else
  warn "cgroup v2 cpuset not yet delegated to user@${UID_NUM}.service (re-login/reboot after installing 10-elish-delegate.conf)"
fi

SESS_CPUS="$(systemctl --user show -p AllowedCPUs --value session.slice 2>/dev/null || true)"
BG_CPUS="$(systemctl --user show -p AllowedCPUs --value background.slice 2>/dev/null || true)"
if [[ "$SESS_CPUS" == "4-7" ]]; then
  ok "session.slice AllowedCPUs=4-7"
else
  warn "session.slice AllowedCPUs='${SESS_CPUS:-unset}' (expected 4-7)"
fi
if [[ "$BG_CPUS" == "0-3" ]]; then
  ok "background.slice AllowedCPUs=0-3"
else
  warn "background.slice AllowedCPUs='${BG_CPUS:-unset}' (expected 0-3)"
fi

UCLAMP_VAL="$(read_sys "$CG_USER/app.slice/cpu.uclamp.min")"
if [[ -n "$UCLAMP_VAL" ]]; then
  if [[ "$UCLAMP_VAL" == "35.00" || "$UCLAMP_VAL" == "35" ]]; then
    ok "app.slice cpu.uclamp.min=$UCLAMP_VAL"
  else
    warn "app.slice cpu.uclamp.min=$UCLAMP_VAL (expected 35.00)"
  fi
else
  info "app.slice cpu.uclamp.min not exposed by kernel"
fi

# 4. Responsiveness, VM, Network, GPU PM
MGLRU_TTL="$(read_sys /sys/kernel/mm/lru_gen/min_ttl_ms)"
if [[ -n "$MGLRU_TTL" ]]; then
  if [[ "$MGLRU_TTL" == "1000" ]]; then
    ok "MGLRU min_ttl_ms=1000"
  else
    warn "MGLRU min_ttl_ms=$MGLRU_TTL (expected 1000)"
  fi
fi

GPU_AS="$(read_sys /sys/devices/platform/soc@0/3d00000.gpu/power/autosuspend_delay_ms)"
if [[ "$GPU_AS" == "500" ]]; then
  ok "Adreno 650 autosuspend_delay_ms=500"
else
  warn "Adreno 650 autosuspend_delay_ms=${GPU_AS:-N/A} (expected 500)"
fi

SWAPPINESS="$(read_sys /proc/sys/vm/swappiness)"
PAGE_CL="$(read_sys /proc/sys/vm/page-cluster)"
if [[ "$SWAPPINESS" == "35" && "$PAGE_CL" == "0" ]]; then
  ok "VM sysctl: swappiness=35, page-cluster=0"
else
  warn "VM sysctl: swappiness=${SWAPPINESS:-?}, page-cluster=${PAGE_CL:-?} (expected 35, 0)"
fi

THP="$(read_sys /sys/kernel/mm/transparent_hugepage/enabled)"
if [[ "$THP" == *"[madvise]"* ]]; then
  ok "THP enabled: [madvise]"
else
  warn "THP enabled: ${THP:-unknown} (expected [madvise])"
fi

TCP_CC="$(read_sys /proc/sys/net/ipv4/tcp_congestion_control)"
QDISC="$(read_sys /proc/sys/net/core/default_qdisc)"
if [[ "$TCP_CC" == "bbr" && "$QDISC" == "fq" ]]; then
  ok "Network: BBR + FQ active"
else
  info "Network: tcp_cc=${TCP_CC:-?}, qdisc=${QDISC:-?}"
fi

# 5. ZRAM
if [[ -d /sys/block/zram0 ]]; then
  ALG="$(read_sys /sys/block/zram0/comp_algorithm)"
  if systemctl is-active elish-zram-recomp.timer >/dev/null 2>&1; then
    ok "zram0 active (alg: $ALG) + elish-zram-recomp.timer enabled"
  else
    info "zram0 active (alg: $ALG); elish-zram-recomp.timer not active"
  fi
fi

# 6. VA-API (Qualcomm Venus)
DRI_DIR="/usr/lib/aarch64-linux-gnu/dri"
if [[ -f "$DRI_DIR/venus_drv_video.so" && -L "$DRI_DIR/msm_drv_video.so" ]]; then
  SZ="$(stat -c '%s' "$DRI_DIR/venus_drv_video.so")"
  ok "Venus VA-API installed ($SZ bytes) with msm_drv_video.so symlink"
  if command -v vainfo >/dev/null 2>&1; then
    VA_OUT="$(LIBVA_DRIVER_NAME=venus vainfo 2>&1 || true)"
    if grep -q 'VAProfileH264' <<< "$VA_OUT" && grep -q 'VAEntrypointVLD' <<< "$VA_OUT"; then
      ok "vainfo opens Venus VA-API with H.264 VLD decode"
    else
      fail "vainfo failed to report H.264 VLD on venus driver"
    fi
  fi
else
  warn "Venus VA-API driver or msm_drv_video.so symlink missing under $DRI_DIR"
fi

# 7. Audio, Display, Keyboard & fastrpc safety
if [[ -f "$HOME/.config/wireplumber/wireplumber.conf.d/51-elish-speaker-s16le.conf" || -f /etc/wireplumber/wireplumber.conf.d/51-elish-speaker-s16le.conf ]]; then
  ok "WirePlumber S16LE/48kHz speaker rule present"
else
  warn "WirePlumber S16LE/48kHz speaker rule missing"
fi

if [[ -e /sys/bus/platform/devices/33c0000.pinctrl/driver ]]; then
  ok "LPASS LPI 33c0000.pinctrl bound (magnetic keyboard USB PHY ready)"
elif [[ -d /sys/bus/platform/devices/33c0000.pinctrl ]]; then
  warn "LPASS LPI 33c0000.pinctrl is UNBOUND"
fi

if [[ -f /etc/modprobe.d/blacklist-fastrpc.conf ]]; then
  ok "fastrpc blacklist installed"
else
  warn "/etc/modprobe.d/blacklist-fastrpc.conf missing"
fi

# 8. Kernel log regression spot-check (best-effort if readable without sudo)
if journalctl -k -b -n 1 >/dev/null 2>&1; then
  KLOG="$(journalctl -k -b --no-pager 2>/dev/null || true)"
  SCX_ERRS="$(grep -c 'scx_bpf_error\|sched_ext:.*error' <<< "$KLOG" || true)"
  GPU_HANGS="$(grep -ci 'gpu hang\|ringbuffer.*hang' <<< "$KLOG" || true)"
  if [[ "$SCX_ERRS" -eq 0 && "$GPU_HANGS" -eq 0 ]]; then
    ok "Kernel boot log: 0 sched_ext errors, 0 GPU hangs"
  else
    warn "Kernel boot log shows scx_errors=$SCX_ERRS, gpu_hangs=$GPU_HANGS (inspect journalctl -k -b)"
  fi
else
  info "Skipping kernel log scan (current user lacks systemd-journal read permission)"
fi

echo ""
echo "Summary: PASS=$PASS  WARN=$WARN  FAIL=$FAIL"
[[ "$FAIL" -eq 0 ]]
