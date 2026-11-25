# Display, Audio, GPU PM & Keyboard Fixes (`xiaomi-elish`)

## 1. GNOME 50 8-bit Scanout Filter + Adreno 650 UBWC (`tuning/display/`)

- **Problem**: GNOME 50 / Mutter selects 10-bit DRM scanout formats (`XR30` / `XRGB2101010`) before 8-bit formats, causing garbled output on `xiaomi-elish`'s DPU. The older workaround `MUTTER_DEBUG_USE_KMS_MODIFIERS=0` fixed the corruption but **disabled Adreno 650 UBWC hardware compression and fullscreen Direct Scanout**, wasting memory bandwidth.
- **Fix**: Compile [`tuning/display/elish-8bpc.c`](../tuning/display/elish-8bpc.c) into `~/.local/lib/libelish-scanout-8bpc.so` and preload it **only** for `org.gnome.Shell@.service` via [`org.gnome.Shell-8bpc.conf.template`](../tuning/display/org.gnome.Shell-8bpc.conf.template) (`ELISH_8BPC=1`). It rewrites 10-bit format entries in `DRM_IOCTL_MODE_GETPROPBLOB` to `DRM_FORMAT_XRGB8888`, allowing Mutter to keep UBWC compression and fullscreen direct scanout enabled.
- Make sure `MUTTER_DEBUG_USE_KMS_MODIFIERS=0` is **removed/commented out** from `~/.config/environment.d/`.

## 2. Adreno 650 GPU Runtime Autosuspend (`tuning/tmpfiles.d/`, `tuning/udev/`)

- **Problem**: Linux `drm/msm` defaults Adreno 650 (`3d00000.gpu`) `power/autosuspend_delay_ms` to **66 ms** (~4 frames at 60 Hz). Whenever the screen sits still for >0.066 s while reading a webpage or chat, the GPU + GMU enter runtime suspend; the next click or scroll drops the first frames waiting for GMU wakeup.
- **Fix**: Raise `autosuspend_delay_ms` to **`500` ms** via `99-elish-responsiveness.conf` and `91-elish-gpu-pm.rules`. Idle screen still suspends the GPU after 0.5 s, while interactive reading/clicking stays warm.

## 3. Built-in 8× CS35L41 Stereo Speakers & Stopping `q6asm-dai` Error Storms (`tuning/audio/`)

- **Problem 1 (`q6asm-dai` `-22` log storm)**: PipeWire / `fluidsynth.service` opening the speaker sink with `S24_32` triggers `q6asm-dai: ASoC error (-22)` every ~30 ms (~100 kernel log lines/sec), starving UFS if a crash/oops logger syncs kmsg.
  - **Fix**: Install [`51-elish-speaker-s16le.conf`](../tuning/audio/51-elish-speaker-s16le.conf) to lock `alsa_output.platform-sound.*` to `S16LE / 48000 Hz` (matching the 16-bit TDM slot width), and mask `fluidsynth.service` if unused (`systemctl --user mask --now fluidsynth.service`).
- **Problem 2 (Stereo routing + PLL lock on 6.18)**: Without `CONFIG_REGMAP_ALLOW_WRITE_DEBUGFS`, all 8 CS35L41 amplifiers default to RX slot 0 (left channel only) and `PLL_CLK_CTRL` stays unlocked until `REFCLK_FREQ=0x33` (12.288 MHz BCLK).
  - **Fix**: [`elish-right-slot.sh`](../tuning/audio/elish-right-slot.sh) + [`elish-right-slot.service`](../tuning/audio/elish-right-slot.service) keep `i2c-1` (`0x40..0x43`, right side) on RX slot `0x02`, `i2c-3` (`0x40..0x43`, left side) on `0x00`, and verify PLL lock. (Requires kernel CS35L41 `PUP_DONE` patch + UCM `PCM Source` = `ASP` + Xiaomi `v0.33.0` speaker firmware; avoid max volume since ASP bypasses DSP speaker protection.)

## 4. Magnetic Keyboard Cover USB Enumeration Fix (`tuning/keyboard/`)

- **Problem**: The Xiaomi magnetic keyboard cover sits on secondary USB (`a800000.usb` → `88e4000.phy`), whose pinctrl (`keyboard-default-state`) lives on `33c0000.pinctrl` (`qcom-sm8250-lpass-lpi-pinctrl`). During early boot before ADSP finishes initializing, `33c0000.pinctrl` can fail probe with `-ETIMEDOUT` (`-110`), leaving the keyboard and touchpad permanently deferred.
- **Fix**: [`elish-keyboard-pinctrl.sh`](../tuning/keyboard/elish-keyboard-pinctrl.sh) checks whether `33c0000.pinctrl` is unbound after late boot and rebinds it (up to 5 retries), automatically bringing up `88e4000.phy` → `a800000.usb` → `xhci-hcd`.

## 5. Memory, MGLRU & ZRAM Tuning (`tuning/sysctl.d/`, `tuning/tmpfiles.d/`, `tuning/zram/`)

- `vm.swappiness = 35`, `vm.page-cluster = 0`, `vm.watermark_scale_factor = 200`, `vm.vfs_cache_pressure = 75`
- MGLRU `/sys/kernel/mm/lru_gen/min_ttl_ms = 1000` (protects active desktop working set from premature eviction)
- Transparent Huge Pages = `madvise` (avoids synchronous compaction stutters from `always`)
- ZRAM active algorithm = `lz4` (fast swap-in latency) + optional `elish-zram-recomp.timer` (recompresses idle/huge pages with `zstd` every 45 min at `Nice=19` / `IOSchedulingClass=idle` when `CONFIG_ZRAM_MULTI_COMP=y` is enabled).
