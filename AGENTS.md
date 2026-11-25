# AGENTS.md — Operational Playbook for AI Agents

This repository packages verified Linux optimizations for **Xiaomi Mi Pad 5 Pro (`xiaomi-elish`, Qualcomm Snapdragon 870 / `SM8250-AC`)**.
If you are an AI agent asked to apply these optimizations to a user's `xiaomi-elish` tablet, follow this exact workflow and respect every safety rule below.

---

## 1. Hard Safety Guardrails (NEVER Violate)

1. **Verify hardware first**: Always run `./scripts/check-device.sh` before modifying anything. Confirm:
   - Architecture is `aarch64`
   - Device Tree model contains `Xiaomi Mi Pad 5 Pro` or `elish`
   - Do **NOT** apply SM8250-AC `opp-3187200000` (3.19 GHz) to non-SM8250-AC chips (e.g., SM8250 Snapdragon 865 `nabu` / `pipa` variants that lack the 3.19 GHz OSM LUT entry).
2. **Never blindly flash `boot_a` / `boot_b`**:
   - Detect the exact active display panel (`CSOT` vs `BOE`) from `/proc/device-tree/model` or `cmdline` before selecting the DTB (`sm8250-xiaomi-elish-csot.dtb` vs `sm8250-xiaomi-elish-boe.dtb`).
   - Always dump and SHA256-verify a full backup of the existing boot partition (`boot_a` / `boot_b`) to external or safe storage before flashing a new boot image.
   - **CRITICAL initramfs trap**: Never pack `fastrpc.ko` into initramfs and always keep `kernel/modprobe.d/blacklist-fastrpc.conf` installed. On `xiaomi-elish`, SLPI `fastrpc` probe deadlocks `udev` and hangs boot/shutdown.
   - Preserve existing Adreno firmware (especially `qcom/a650_sqe.fw` / `a650_gmu.bin`) and Cirrus `cs35l41-dsp1-spk-prot*.wmfw/.bin` speaker firmware; do not overwrite them blindly.
3. **Always back up modified files**: Every script in `scripts/` backs up existing targets before writing; do not overwrite earlier `.orig` backups.
4. **Do not assume `UID=1000` or a fixed username**: All user systemd templates here use `%U` / `%h` / `$HOME` dynamically. Keep it portable.
5. **Do not kill the user's running browser/session without asking**: Changing Chrome `.desktop` flags or `venus_drv_video.so` requires the user to fully exit Chrome (`Ctrl+Shift+Q`) and relaunch.
6. **Guard `apt upgrade` on custom kernels**: Armbian's `/etc/kernel/postinst.d/zz-update-abl-kernel` can overwrite `boot_a` if `linux-image-current-sm8250` upgrades. Warn the user or hold the stock kernel package if running a custom kernel.

---

## 2. Decision Tree for Applying Modules

Run `./scripts/check-device.sh` first, then decide which modules apply:

| Condition detected by `check-device.sh` | Recommended Action |
| :--- | :--- |
| Running stock kernel (`PREEMPT_NONE`, `HZ=250`, no `/sys/kernel/sched_ext`) | Apply **userspace tuning** + **VA-API fix** immediately; propose kernel rebuild via `docs/kernel-and-dts.md` if the user wants `scx_cosmos`, `PREEMPT(full)`, `HZ=1000`, `MGLRU`, `UCLAMP`, and 3.19 GHz Prime OPP. |
| `/sys/kernel/sched_ext` exists | Build & install **`scx_cosmos`** (`./scripts/build-install-scx-cosmos.sh`) with `-m 4-7 -P --time-preemption`. **Do NOT use `scx_lavd --autopilot`** (its ARM Energy Model packs interactive Chrome/GNOME threads onto A55 little cores) and **do NOT use `scx_bpfland 1.1.5`** (hits `EDQ insert failed: -22` on Linux 6.18 ARM64). |
| `/sys/kernel/sched_ext` does NOT exist | Skip `scx_cosmos`. Use native EEVDF + cgroup big-core isolation (`--cgroup` + `--responsiveness`) and optionally raise `policy4`/`policy7` `scaling_min_freq` to `1766400`/`2073600` kHz (`docs/scheduler-benchmarks.md`). |
| `/dev/video*` has `qcom-venus` decoder | Run `./scripts/build-install-venus-vaapi.sh` to install the patched Release (`-O3`) `venus_drv_video.so` + `msm_drv_video.so` symlink, then add Chrome flags from `tuning/desktop/chrome-flags.txt`. |
| GNOME 50 Wayland shows corrupted 10-bit scanout or `MUTTER_DEBUG_USE_KMS_MODIFIERS=0` is set | Compile and install `tuning/display/elish-8bpc.c` as `~/.local/lib/libelish-scanout-8bpc.so` + `org.gnome.Shell@.service.d/8bpc.conf`, then remove `MUTTER_DEBUG_USE_KMS_MODIFIERS=0` to restore Adreno 650 UBWC & direct scanout. |
| `dmesg` shows `q6asm-dai ... ASoC error (-22)` spam | Install `tuning/audio/51-elish-speaker-s16le.conf` and mask `fluidsynth.service` (`systemctl --user mask --now fluidsynth.service`) if unused. |
| Magnetic keyboard cover fails to enumerate after reboot (`33c0000.pinctrl` deferred) | Install `tuning/keyboard/elish-keyboard-pinctrl.sh` (or append to late firmware hook). |

---

## 3. Exact Execution Order

```bash
# Step 1: Read-only pre-flight check
./scripts/check-device.sh

# Step 2: Dry-run userspace & sysctl/tmpfiles/udev/cgroup tuning
./scripts/apply-userspace-tuning.sh --dry-run

# Step 3: Apply selected or all safe userspace modules
./scripts/apply-userspace-tuning.sh --all

# Step 4 (if /sys/kernel/sched_ext exists): Build & enable scx_cosmos
./scripts/build-install-scx-cosmos.sh

# Step 5 (if qcom-venus decoder exists): Build & install patched Venus VA-API
./scripts/build-install-venus-vaapi.sh

# Step 6: Verify live state
./scripts/verify.sh
```

---

## 4. Verification Criteria (What "Done" Looks Like)

After running `./scripts/verify.sh`, confirm:
- **Scheduler**: If `scx_cosmos` is installed, `/sys/kernel/sched_ext/state` is `enabled`, `ops` starts with `cosmos_`, `policy4`/`policy7` `scaling_min_freq` are at stock `710400`/`844800` (since `scx_cosmos` manages `cpuperf` dynamically), and `journalctl -u scx.service` shows `Preferred CPUs: [7, 4, 5, 6, 0, 1, 2, 3]` and `Primary CPUs: [4, 5, 6, 7]`.
- **Cgroups**: `user@.service` delegates `cpuset` + `cpu`; `session.slice` has `AllowedCPUs=4-7`; `background.slice` has `AllowedCPUs=0-3`; `app.slice` has `cpu.uclamp.min` = `35.00` (if `CONFIG_UCLAMP_TASK_GROUP=y`).
- **Responsiveness & GPU PM**: `/sys/kernel/mm/lru_gen/min_ttl_ms` = `1000` (if MGLRU enabled), `/sys/devices/platform/soc@0/3d00000.gpu/power/autosuspend_delay_ms` = `500`, `vm.swappiness` = `35`, `vm.page-cluster` = `0`, `THP` = `[madvise]`.
- **VA-API**: `vainfo` opens `venus_drv_video.so` cleanly (`VAEntrypointVLD` for H.264 / VP8 / VP9) and `mpv --no-config --hwdec=vaapi-copy --vo=null --ao=null --frames=30 <h264-mp4>` prints `Using hardware decoding (vaapi-copy)` with zero `HW busy now` errors.
- **No regressions**: `journalctl -k -b` has 0 new SMMU faults, 0 GPU hangs, 0 `scx` rejections, and 0 `q6asm-dai` error storms.

---

## 5. Rollback

- **Disable `scx_cosmos`** (instant, returns to native EEVDF):
  ```bash
  sudo systemctl disable --now scx.service
  ```
- **Revert userspace/system files**: Every modified system/user file is backed up under `~/.local/state/elish-linux-tuning-backup-<timestamp>/`. Restore from that directory and reload `systemd` / `sysctl --system` / `systemd-tmpfiles --create`.
- **Revert VA-API driver**: Restore `venus_drv_video.so.orig` from the backup directory into `/usr/lib/aarch64-linux-gnu/dri/venus_drv_video.so`.
