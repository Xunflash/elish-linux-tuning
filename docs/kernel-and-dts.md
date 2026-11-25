# Kernel 6.18 & Device Tree Guide (`xiaomi-elish` / SM8250-AC)

This guide covers building a low-latency, `sched_ext`-capable Linux 6.18 kernel with stock Snapdragon 870 (**3.19 GHz**) Prime OPP and Cirrus Logic CS35L41 speaker fixes for the **Xiaomi Mi Pad 5 Pro (`xiaomi-elish`)**.

---

## 1. Base Sources

1. **Upstream Linux 6.18.x** tarball (`cdn.kernel.org`, tested on `linux-6.18.44`).
2. **Armbian `sm8250-6.18` patchset & DT files**: from `armbian/build` (`patch/kernel/archive/sm8250-6.18/`).
3. **Starting `.config`**: copy the existing working `/boot/config-6.18.*-current-sm8250` from the device so all Qualcomm SM8250 drivers stay intact.

---

## 2. Kernel Kconfig Fragment (`kernel/kconfig/sm8250-elish-scx.fragment`)

Apply on top of the stock Armbian SM8250 config using Linux's `scripts/kconfig/merge_config.sh`:

```bash
cp /boot/config-6.18.*-current-sm8250 .config
./scripts/kconfig/merge_config.sh -m .config /path/to/elish-linux-tuning/kernel/kconfig/sm8250-elish-scx.fragment
make olddefconfig
```

Key changes vs Armbian stock `PREEMPT_NONE` / `HZ=250` server config:

| Area | Change | Rationale |
| :--- | :--- | :--- |
| Preemption & Tick | `PREEMPT=y`, `PREEMPT_DYNAMIC=y`, `HZ_1000=y` | Eliminates desktop/input latency spikes on 2560×1600@120Hz (8.33 ms frame budget) |
| Scheduling | `SCHED_CLASS_EXT=y`, `DEBUG_INFO_BTF=y`, `UCLAMP_TASK=y`, `UCLAMP_TASK_GROUP=y`, `RT_GROUP_SCHED=n` | Enables BPF `sched_ext` (`scx_cosmos`) and per-cgroup utilization clamping |
| CPU Topology & Idle | `NR_CPUS=8`, `NUMA=n`, `CPU_IDLE_GOV_TEO=y`, `CPU_FREQ_DEFAULT_GOV_SCHEDUTIL=y` | Trims per-CPU overhead; TEO handles mobile/tablet bursty idle states better than `menu` |
| Memory & ZRAM | `LRU_GEN=y`, `LRU_GEN_ENABLED=y`, `TRANSPARENT_HUGEPAGE_MADVISE=y`, `ZRAM_MULTI_COMP=y`, `USERFAULTFD=y` | MGLRU working-set protection + LZ4 active swap with ZSTD cold-page recompression |
| Block & FS | `BLK_WBT=y`, `IOSCHED_BFQ=m`, `SQUASHFS_DECOMP_MULTI_PERCPU=y` + LZ4/ZSTD/LZO, `NTFS3_FS=m`, `CIFS=m`, `NFSD=m`, `FSCACHE=y`, `USB_UAS=m` | Faster AppImage/Snap squashfs decompression, writeback throttling, NAS/USB storage support |
| Networking & BT | `TCP_CONG_BBR=y`, `NET_SCH_FQ=y`, `DEFAULT_FQ=y`, `NET_SCH_CAKE=m`, `BT_RFCOMM=m`, `BT_BNEP=m` | Lower tail latency under Wi-Fi congestion; full Bluetooth profile support |
| Android/Waydroid | `ANDROID_BINDERFS=y` | Ready for Waydroid / container workloads |

---

## 3. Device Tree & Driver Patches

### 3.1 Unlock Stock Snapdragon 870 3.19 GHz Prime OPP
- Patch: [`kernel/patches/0001-arm64-dts-qcom-elish-add-3187mhz-opp.patch`](../kernel/patches/0001-arm64-dts-qcom-elish-add-3187mhz-opp.patch)
- **Not overclocking**: `3187200000 Hz` (`3.19 GHz`) is Qualcomm's factory top bin for Snapdragon 870 (`SM8250-AC`). `qcom-cpufreq-hw` validates every DT OPP against the hardware OSM LUT burned into the SoC; on `SM8250-AC`, `3091200000` (SD865+) is rejected (`avail=N`) while `3187200000` matches (`avail=Y`).
- Measured single-core SHA256 throughput jumped from `1640.7 MB/s` (2.84 GHz) to **`1777.8 MB/s` (+8.4%)**.

### 3.2 Cirrus Logic CS35L41 Internal Boost `PUP_DONE` Timeout Fix
- Patch: [`kernel/patches/0002-asoc-cs35l41-fix-global-enable-irq-status.patch`](../kernel/patches/0002-asoc-cs35l41-fix-global-enable-irq-status.patch)
- On Linux 6.18, `cs35l41_global_enable()` polls the masked `CS35L41_IRQ1_STATUS1` (`0x10010`) instead of `CS35L41_IRQ1_RAW_STATUS1` (`0x10090`) and aborts DAPM on `-ETIMEDOUT` (`-110`), leaving all 8 speakers muted.
- Switching to `CS35L41_IRQ1_RAW_STATUS1` and returning `0` after logging on timeout restores speaker power-up cleanly.

---

## 4. Critical Boot Image & Initramfs Checklist (DO NOT SKIP)

1. **Match your display panel DTB**:
   - Check `/proc/device-tree/model` or `/proc/cmdline` (`msm_drm.dsi_display0=...`) to verify **CSOT** (`sm8250-xiaomi-elish-csot.dtb`) vs **BOE** (`sm8250-xiaomi-elish-boe.dtb`).
2. **Exclude `fastrpc.ko` from initramfs & blacklist it**:
   - Install [`kernel/modprobe.d/blacklist-fastrpc.conf`](../kernel/modprobe.d/blacklist-fastrpc.conf) to `/etc/modprobe.d/blacklist-fastrpc.conf` **before** running `update-initramfs` and verify `lsinitramfs /boot/initrd.img-<ver> | grep fastrpc` returns **nothing**.
   - Without this, SLPI's `fastrpc` probe returns `EINVAL` and triggers a `device_del` deadlock inside `rpmsg_destroy_ept`, hanging `udev` and `systemd-shutdown`.
3. **Preserve boot partition backup & SHA256 verify**:
   - Back up `/dev/disk/by-partlabel/boot_a` (or active slot) before flashing, and compare `sha256sum` of the written partition back against your boot image file.
4. **Watch out for `apt upgrade`**:
   - Armbian's `/etc/kernel/postinst.d/zz-update-abl-kernel` will re-flash `boot_a` if the stock `linux-image-current-sm8250` package upgrades. Consider `sudo apt-mark hold linux-image-current-sm8250` while running a custom kernel.
