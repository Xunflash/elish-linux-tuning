# elish-linux-tuning

[简体中文](README.zh-CN.md) | [Agent Playbook (`AGENTS.md`)](AGENTS.md)

A modular, benchmark-backed collection of **Linux kernel, Device Tree, `sched_ext` (`scx_cosmos`), Qualcomm Venus VA-API, memory/ZRAM, GPU PM, display, audio, and keyboard** optimizations for the **Xiaomi Mi Pad 5 Pro (`xiaomi-elish`, Snapdragon 870 / `SM8250-AC`)** running mainline Linux (Armbian / Ubuntu / Debian, Linux 6.18+, GNOME Wayland).

Designed to be easy for both **humans and AI coding/ops agents** to inspect, dry-run, apply selectively, verify, and roll back cleanly.

---

## Hardware Target

- **Device**: Xiaomi Mi Pad 5 Pro (`xiaomi-elish`)
- **SoC**: Qualcomm Snapdragon 870 (`SM8250-AC`: 4× Cortex-A55 @ 1.80 GHz + 3× Cortex-A77 @ 2.42 GHz + 1× Cortex-A77 Prime @ **3.19 GHz**)
- **GPU / Video**: Adreno 650 (Freedreno) + Qualcomm Venus (`qcom-venus` stateful V4L2 M2M)
- **Display**: 2560×1600 @ 120 Hz (CSOT & BOE panels — **always match your own panel DTB!**)
- **Audio**: 8× Cirrus Logic CS35L41 smart amplifiers over I2C + Tertiary TDM

---

## What's Inside

| Module | Directory | Highlights |
| :--- | :--- | :--- |
| **Kernel & Device Tree** | [`kernel/`](kernel/) | Linux 6.18 Kconfig fragment (`PREEMPT_DYNAMIC(full)`, `HZ=1000`, `SCHED_CLASS_EXT`, `UCLAMP`, `MGLRU`, `ZRAM_MULTI_COMP`, `BBR`+`FQ`, `TEO`), stock **3.19 GHz** SM8250-AC Prime OPP DTS patch (+8.4% single-core), CS35L41 speaker `PUP_DONE` timeout patch, `fastrpc` initramfs/modprobe blacklist |
| **CPU Scheduler (`scx_cosmos`)** | [`scheduler/`](scheduler/) | `scx_cosmos` (`-m 4-7 -P --time-preemption`) + systemd cgroup v2 `cpuset` / `CPUWeight` / `uclamp` big.LITTLE isolation (`session.slice` & Chrome on `4-7`, `background.slice` on `0-3`, `app.slice` on `0-7` with `uclamp.min=35%`) |
| **VA-API Hardware Video Decode** | [`vaapi/`](vaapi/) | Patch & Release (`-O3`) build script for [`snowf14k3/venus-vaapi-driver`](https://github.com/snowf14k3/venus-vaapi-driver) (upstream [PR #3](https://github.com/snowf14k3/venus-vaapi-driver/pull/3)): fixes H.264 B-frame green flashes, backward frame jumps, 30s sync timeouts, `POLLOUT` busy-spin, and ABR resolution changes |
| **System Responsiveness** | [`tuning/`](tuning/) | MGLRU `min_ttl_ms=1000`, Adreno 650 `autosuspend_delay_ms=500` (fixes 66 ms cold-wakeup hitches), LZ4 ZRAM + idle ZSTD recompression timer, `swappiness=35`, BBR+FQ, THP `madvise` |
| **Display, Audio & Keyboard** | [`tuning/`](tuning/) | GNOME 50 8bpc scanout filter (`elish-8bpc.c`, preserves Adreno UBWC & direct scanout), WirePlumber `S16LE/48kHz` rule (stops `q6asm-dai` `-22` log storms), CS35L41 stereo slot/PLL helper, LPASS LPI `33c0000.pinctrl` keyboard USB recovery |
| **Scripts & Verification** | [`scripts/`](scripts/) | Pre-flight hardware check, idempotent installer with `--dry-run` & backups, `scx_cosmos` builder, Venus VA-API builder, post-apply health verification |

---

## Measured Results (SM8250-AC, Linux 6.18.44)

### 1. 8-Way Scheduler Benchmark (`scx_cosmos` vs `scx_lavd` / `flash` / `cake` / `pandemonium` / `bpfland` / Native EEVDF)

| Scheduler | Unpinned UI `0-7`<br>(big% / p50 / p95 / wake95) | Single-Thread Heavy<br>(p50 / p95) | 4× Same-Prio Contention on `4-7`<br>(p50 / p95 / wake95) | 8-Core Throughput<br>(lower = faster) | Light-Load Power Proxy<br>(A55 deep-sleep / Prime avg / busy%) |
| :--- | :--- | :--- | :--- | :--- | :--- |
| Native EEVDF (stock min) | 43% / 13.80 / 17.10 / 0.35 ms | 14.08 / 41.90 ms | 2.69 / 6.91 / 1.79 ms | 356.1 ms | 21.4% / 2535 MHz / 38.9% |
| Native EEVDF (min 1.77G/2.07G) | 40% / 18.77 / 22.04 / 0.48 ms | 14.24 / 53.00 ms | 2.32 / 5.31 / 1.65 ms | 291.1 ms | 20.4% / 2927 MHz / 39.3% |
| `scx_lavd --autopilot` | packs Chrome/GNOME onto A55 | — | — | — | A55 pegged at 1804 MHz |
| `scx_bpfland 1.1.5` | BPF `EDQ insert failed: -22` | — | — | — | Incompatible on 6.18 ARM64 |
| `scx_cake 1.4.3` | 60% / 2.60 / 13.68 / 0.37 ms | 45.54 / 53.10 ms | 3.90 / 5.62 / 0.76 ms | 501.8 ms | 44.2% / 3187 MHz / 36.1% |
| `scx_pandemonium 5.25` | 40% / 13.12 / 13.37 / 0.32 ms | 10.75 / 52.37 ms | 3.60 / 4.58 / 0.09 ms | 509.4 ms | 40.3% / 3187 MHz / 29.0% |
| `scx_flash -m 0xf0 -f -I -1` | 93% / 3.58 / 7.67 / 0.25 ms | 11.49 / 13.73 ms | 2.59 / 3.81 / 0.64 ms | **272.6 ms** | 61.9% / 2440 MHz / 14.4% |
| **`scx_cosmos -m 4-7 -P --time-preemption`** | **100% / 3.00 / 4.48 / 0.11 ms** | **11.82 / 14.15 ms** | **2.56 / 3.53 / 0.94 ms** | **275.3 ms** | **84.5% / 2091 MHz / 16.1%** |

Full details: [`docs/scheduler-benchmarks.md`](docs/scheduler-benchmarks.md).

### 2. Qualcomm Venus VA-API Hardware Video Decode

- **Before**: `mpv --hwdec=vaapi-copy` hung 30s (`Failed to sync surface 0x3000001: 34 (HW busy now)`) on B-frame H.264 MP4s; Chromium flashed green frames and jumped back to earlier frames on X/Bilibili hover previews.
- **After**: 100% hardware decode (`nv12`), **16/16 consecutive B-frame H.264 frames bit-exact to software (`MAE = 0.00`, 0% green, 0 reordered frames)**; Release (`-O3`) `.so` shrunk from `1.08 MB` to `217 KB`; Chromium works cleanly with `AcceleratedVideoDecodeLinuxGL,AcceleratedVideoDecodeLinuxZeroCopyGL,VaapiIgnoreDriverChecks`.

Full details: [`docs/vaapi-venus.md`](docs/vaapi-venus.md).

---

## Quickstart

### For AI Agents
Read [`AGENTS.md`](AGENTS.md) first. It contains exact pre-flight checks, safety constraints, non-interactive commands, and verification criteria.

### For Humans

```bash
# 1. Inspect hardware & current kernel capabilities (read-only)
./scripts/check-device.sh

# 2. Preview userspace tuning changes without modifying anything
./scripts/apply-userspace-tuning.sh --dry-run

# 3. Apply userspace responsiveness, cgroup isolation, audio & GPU PM tuning
#    (backs up overwritten files automatically)
./scripts/apply-userspace-tuning.sh --all

# 4. Build & install scx_cosmos (requires a kernel with CONFIG_SCHED_CLASS_EXT=y)
./scripts/build-install-scx-cosmos.sh

# 5. Build & install patched Qualcomm Venus VA-API driver (Release -O3)
./scripts/build-install-venus-vaapi.sh

# 6. Verify everything is active and healthy
./scripts/verify.sh
```

Kernel build & DTS instructions (3.19 GHz OPP, `sched_ext`, `PREEMPT(full)`, `HZ=1000`, CS35L41): see [`docs/kernel-and-dts.md`](docs/kernel-and-dts.md).

---

## License

Released into the public domain under **[The Unlicense](LICENSE)**. Use, modify, fork, bundle, or redistribute freely without attribution.
