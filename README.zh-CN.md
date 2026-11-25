# elish-linux-tuning

[English](README.md) | [AI Agent 执行手册 (`AGENTS.md`)](AGENTS.md)

面向 **小米平板 5 Pro（`xiaomi-elish`，骁龙 870 / `SM8250-AC`）** 主线 Linux（Armbian / Ubuntu / Debian，Linux 6.18+，GNOME Wayland）的一整套模块化、经实机压测验证的优化合集，涵盖：**自定义低延迟内核与设备树、`scx_cosmos` BPF 调度与 cgroup 大小核隔离、高通 Venus VA-API 硬件解码修复、内存/ZRAM/GPU 调优、显示/扬声器/磁吸键盘壳修复**。

仓库专门为 **人类用户与 AI Agent** 双向设计：所有配置声明式拆分、脚本支持 `--dry-run` 与自动备份，并附带完整的只读探测与验收脚本。

---

## 适用硬件

- **设备**：Xiaomi Mi Pad 5 Pro（`xiaomi-elish`）
- **SoC**：Qualcomm Snapdragon 870（`SM8250-AC`：4× A55 @ 1.80 GHz + 3× A77 @ 2.42 GHz + 1× A77 超大核 @ **3.19 GHz**）
- **GPU / 编解码**：Adreno 650（Freedreno）+ Qualcomm Venus（`qcom-venus` stateful V4L2 M2M）
- **屏幕**：2560×1600 @ 120 Hz（注意区分 **CSOT** 与 **BOE** 面板 DTB，切勿混刷）
- **音频**：8× Cirrus Logic CS35L41 功放

---

## 优化模块总览

| 模块 | 目录 | 核心内容 |
| :--- | :--- | :--- |
| **内核配置与设备树补丁** | [`kernel/`](kernel/) | Linux 6.18 Kconfig 片段（`PREEMPT_DYNAMIC(full)`、`HZ=1000`、`SCHED_CLASS_EXT`、`UCLAMP`、`MGLRU`、`ZRAM_MULTI_COMP`、`BBR`+`FQ`、`TEO`）、解锁原厂 **3.19 GHz** 超大核 OPP 补丁（单核 +8.4%）、CS35L41 扬声器上电超时修复补丁、`fastrpc` 黑名单 |
| **`scx_cosmos` 调度与大小核隔离** | [`scheduler/`](scheduler/) | 8 组实测胜出的 `scx_cosmos`（`-m 4-7 -P --time-preemption`）+ systemd cgroup v2 `cpuset` / 权重 / `uclamp` 隔离（`session.slice` 与 Chrome 锁大核 `4-7`、`background.slice` 锁小核 `0-3`、`app.slice` 保留 8 核并设 `uclamp.min=35%`） |
| **VA-API 硬件视频解码修复** | [`vaapi/`](vaapi/) | 针对 [`snowf14k3/venus-vaapi-driver`](https://github.com/snowf14k3/venus-vaapi-driver) 的完整修复补丁（已提上游 [PR #3](https://github.com/snowf14k3/venus-vaapi-driver/pull/3)）与 Release（`-O3`）一键编译安装脚本，根治首帧绿屏、Chrome hover 预览闪绿/跳回旧帧、B 帧 30 秒超时与 `POLLOUT` 空转 |
| **系统响应与内存/GPU 调优** | [`tuning/`](tuning/) | MGLRU `min_ttl_ms=1000`、Adreno 650 `autosuspend_delay_ms=500`（解决 66 ms 休眠唤醒掉帧）、LZ4 ZRAM + 冷页 ZSTD 定时重压缩、`swappiness=35`、`BBR+FQ`、THP `madvise` |
| **显示、扬声器与键盘壳修复** | [`tuning/`](tuning/) | GNOME 50 8-bit 过滤 preload（`elish-8bpc.c`，保留 Adreno UBWC 与全屏直通）、WirePlumber `S16LE/48kHz` 规则（根治 `q6asm-dai` `-22` 刷屏风暴）、CS35L41 立体声槽位与 PLL 守护、LPASS LPI `33c0000.pinctrl` 磁吸键盘壳开机重绑 |
| **自动化与验收脚本** | [`scripts/`](scripts/) | 只读硬件体检、幂等安装脚本（支持 `--dry-run` 与自动备份）、`scx_cosmos` 编译脚本、Venus VA-API 编译脚本、一键状态验证 |

---

## 核心实测收益（骁龙 870，Linux 6.18.44）

- **调度性能与功耗（`scx_cosmos -m 4-7 -P --time-preemption`，原厂底频 `710M/844M`）**：
  - 未绑核交互帧 `UI(0-7)`：大核命中 **100%**，p50 **`3.00 ms`** / p95 **`4.48 ms`** / 唤醒抖动 **`0.11 ms`**（原生 EEVDF 为 43% / 13.80 / 17.10 ms）；
  - 4× 同优先级大核抢占：p50 **`2.56 ms`** / p95 **`3.53 ms`**；
  - 8 核满载吞吐：**`275.3 ms`**（快于原生 EEVDF 的 `291–356 ms`）；
  - 轻载功耗指标：4 颗 A55 小核深度休眠达 **`84.5%`**（原生 EEVDF 为 `21.4%`），超大核均频降到 **`2091 MHz`**。
  - 详见 [`docs/scheduler-benchmarks.md`](docs/scheduler-benchmarks.md)。
- **高通 Venus VA-API 硬解**：
  - 修复前：`mpv --hwdec=vaapi-copy` 解码含 B 帧 H.264 卡死 30 秒报错回退软解；Chrome 刷 X/B 站 hover 预览频繁闪绿并跳回前面帧；
  - 修复后：100% 硬解（`nv12`），**16/16 帧与软解逐像素一致（`MAE = 0.00`，0% 绿帧，0 乱序）**，Release `.so` 体积从 `1.08 MB` 降到 **`217 KB`**，Chrome 可完整启用 `ZeroCopyGL` 硬解。
  - 详见 [`docs/vaapi-venus.md`](docs/vaapi-venus.md)。

---

## 快速上手

```bash
# 1. 只读体检（检查机型、内核特性、面板型号、Venus 节点）
./scripts/check-device.sh

# 2. 预演用户态与系统参数优化（不改动系统）
./scripts/apply-userspace-tuning.sh --dry-run

# 3. 应用系统响应、cgroup 大小核隔离、GPU PM、音频与 ZRAM 调优（自动备份原文件）
./scripts/apply-userspace-tuning.sh --all

# 4. 编译并安装 scx_cosmos（需内核已开启 CONFIG_SCHED_CLASS_EXT=y）
./scripts/build-install-scx-cosmos.sh

# 5. 编译并安装修复后的高通 Venus VA-API 驱动（Release -O3）
./scripts/build-install-venus-vaapi.sh

# 6. 一键核验全部生效状态
./scripts/verify.sh
```

自定义内核重编与设备树（3.19 GHz OPP / CS35L41 / `sched_ext`）详见 [`docs/kernel-and-dts.md`](docs/kernel-and-dts.md)。

---

## 开源协议

本仓库采用最宽松的 **[The Unlicense](LICENSE)**（公有领域奉献声明），可无任何限制地自由使用、修改、二次打包与分发，无需署名。
