# CPU Scheduler & big.LITTLE Benchmarks (`SM8250-AC`)

All measurements below were captured on a **Xiaomi Mi Pad 5 Pro (`xiaomi-elish`)** running **Linux `6.18.44-scx-sm8250`** (`PREEMPT(full)`, `HZ=1000`, `schedutil`, `TEO` cpuidle).

## Hardware Topology (`cpu_capacity`)

| CPUs | Microarchitecture | Frequency Range | Kernel `cpu_capacity` | Relative Single-Thread Speed |
| :--- | :--- | :--- | :--- | :--- |
| `cpu0–3` | 4× Cortex-A55 (in-order) | 0.30 – 1.80 GHz | `253` | 1.0× |
| `cpu4–6` | 3× Cortex-A77 (OoO Big) | 0.71 – 2.42 GHz | `777` | ~3.1× |
| `cpu7` | 1× Cortex-A77 (OoO Prime) | 0.84 – 3.19 GHz | `1024` | ~4.0–5.0× |

Because Cortex-A55 cores are **4–5× slower** than Cortex-A77 big/prime cores on JS/DOM/compositor bursts, letting interactive browser or Wayland threads land on `cpu0–3` turns a 3 ms frame into a 13–19 ms stutter (missing the 8.33 ms 120 Hz frame budget).

---

## Why `scx_lavd --autopilot` Hurt Web Browsing on SM8250

With default `--autopilot` (`no_use_em: false`), `scx_lavd 1.1.5` reads the ARM Energy Model, which ranks A55 cores as most energy-efficient per capacity unit:
- Core compaction packed `primary CPUs = [0, 1, 2, 3]` first and kept `cpu7` (3.19 GHz) in `overflow CPUs` until 8-core load exceeded **70%**.
- Live observation caught Chrome's heaviest renderer (54.3% CPU), Chrome GPU (9.6%), and `gnome-shell` (11.0%) all pinned onto A55 `cpu0–3` at 1804 MHz while `cpu4–7` idled at low clocks, driving CPU PSI (`some`) to ~3.8%.
- Even with `--performance` or `--cpu-pref-order 7,4,5,6,0,1,2,3`, `scx_lavd 1.1.5`'s sticky `prev_cpu` placement trapped tasks spawned on A55 cores unless manually pinned via cgroups.

---

## 8-Way Head-to-Head Benchmark (`sched-ext/scx v1.1.5` vs Native EEVDF)

Workloads:
1. **`UI(0-7)`**: Unpinned (`0-7`) 30× interactive burst (15k LCG iters / 15 ms sleep) — tests native big.LITTLE intelligence without manual pinning.
2. **`1T-Heavy`**: Unpinned (`0-7`) 15× single-thread burst (60k iters / 5 ms sleep).
3. **`4x-Cont`**: 4× same-priority (`nice 0`) CPU hogs on `4-7` competing with an interactive UI burst on `4-7`.
4. **`8C-Thru`**: 8-worker parallel compute throughput (16× 250k iters, lower ms = faster).
5. **`Power3s`**: 3 s quiet desktop window measuring `cpuidle` `state1` (`cpu-sleep`) deep-sleep residency, average cluster clock, and total CPU busy%.

| Scheduler & Flags | Big-Core Min Freq | `UI(0-7)` big% / p50 / p95 / wake95 | `1T-Heavy` p50 / p95 | `4x-Cont` p50 / p95 / wake95 | `8C-Thru` | `Power3s` A55 sleep / p4 / p7 / busy% |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- |
| Native EEVDF (tuned min) | 1.77G / 2.07G | 40% / 18.77 / 22.04 / 0.48 ms | 14.24 / 53.00 ms | 2.32 / 5.31 / 1.65 ms | 291.1 ms | 20.4% / 1934 / 2927 MHz / 39.3% |
| Native EEVDF (stock min) | 710M / 844M | 43% / 13.80 / 17.10 / 0.35 ms | 14.08 / 41.90 ms | 2.69 / 6.91 / 1.79 ms | 356.1 ms | 21.4% / 1143 / 2535 MHz / 38.9% |
| `scx_bpfland 1.1.5` | 710M / 844M | *BPF abort: `EDQ insert failed: -22`* | — | — | — | Disqualified on 6.18 ARM64 |
| `scx_cake 1.4.3` | 710M / 844M | 60% / 2.60 / 13.68 / 0.37 ms | 45.54 / 53.10 ms | 3.90 / 5.62 / 0.76 ms | 501.8 ms | 44.2% / 2419 / 3187 MHz / 36.1% |
| `scx_pandemonium 5.25` | 710M / 844M | 40% / 13.12 / 13.37 / 0.32 ms | 10.75 / 52.37 ms | 3.60 / 4.58 / 0.09 ms | 509.4 ms | 40.3% / 2419 / 3187 MHz / 29.0% |
| `scx_flash -m 0xf0 -f -I -1` | 710M / 844M | 93% / 3.58 / 7.67 / 0.25 ms | 11.49 / 13.73 ms | 2.59 / 3.81 / 0.64 ms | **272.6 ms** | 61.9% / 2158 / 2440 MHz / 14.4% |
| **`scx_cosmos -m 4-7 -P --time-preemption`** | **710M / 844M** | **100% / 3.00 / 4.48 / 0.11 ms** | **11.82 / 14.15 ms** | **2.56 / 3.53 / 0.94 ms** | **275.3 ms** | **84.5% / 2046 / 2091 MHz / 16.1%** |

*(Note: `scx_flash`'s default `-I 32` sets a 32 µs PM QoS idle-resume lock that blocks SM8250's 891 µs / 1763 µs `cpu-sleep` C-states completely (`0.0%` deep sleep) unless `-I -1` is passed.)*

---

## Final Recommended Architecture

1. **Primary BPF Scheduler**: `scx_cosmos -m 4-7 -P --time-preemption`
   - `-m 4-7`: Sets the 4× Cortex-A77 cores as the primary domain (`--primary-overload-us 1000` spills parallel builds cleanly onto `0-3` after 1 ms backlog for full 8-core throughput).
   - `-P`: Preferred idle scan orders cores `[7, 4, 5, 6, 0, 1, 2, 3]` automatically.
   - `--time-preemption`: High-resolution timer preemption keeps contention tail latency under 3.6 ms.
   - Built-in BPF `scx_bpf_cpuperf_set()` scaling allows keeping **stock `min_freq` (`710 MHz / 844 MHz`)** while letting A55 little cores stay in hardware deep sleep **84.5%** of the time.
2. **Synergistic systemd cgroup v2 Guardrails** (works both with `scx_cosmos` and as a strong fallback if running native EEVDF without `sched_ext`):
   - `session.slice` (GNOME Shell, Wayland, PipeWire): `AllowedCPUs=4-7`, `CPUWeight=300`
   - Chrome scopes (`app-com.google.Chrome-.scope` & `app-gnome-google\x2dchrome-.scope`): `AllowedCPUs=4-7`, `CPUWeight=200`
   - `app.slice` (terminals, IDEs, general apps): `AllowedCPUs=0-7`, `CPUWeight=200`, `cpu.uclamp.min=35%` (> A55 max capacity `253/1024 = 24.7%`)
   - `background.slice` (`localsearch-3`, indexers): `AllowedCPUs=0-3`, `CPUWeight=50`
3. **Fallback Without `sched_ext` (Native EEVDF Only)**:
   - If your kernel does not enable `CONFIG_SCHED_CLASS_EXT=y`, keep the systemd cgroup isolation above and raise `policy4`/`policy7` `scaling_min_freq` to `1766400`/`2073600` in `/etc/tmpfiles.d/99-elish-responsiveness.conf` to avoid `schedutil` cold-ramp lag on waking bursts (measured `2.56 ms / 2.59 ms` under 4× contention).
