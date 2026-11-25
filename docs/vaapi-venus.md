# Qualcomm Venus VA-API Hardware Video Decode Fix (`qcom-venus`)

Mainline Linux exposes the Snapdragon 870 (`SM8250`) Qualcomm Venus hardware codec through a **stateful V4L2 M2M** interface (`/dev/video0` decoder, `/dev/video1` encoder), while Linux browsers (Chromium/Chrome, Firefox) and players (`mpv`) expect **VA-API (`libva`)**.

The open-source [`snowf14k3/venus-vaapi-driver`](https://github.com/snowf14k3/venus-vaapi-driver) bridges VA-API to `qcom-venus`, but `v0.12.0` had several critical bugs when used with Chromium (`AcceleratedVideoDecodeLinuxGL` / `ZeroCopyGL`) and `mpv --hwdec=vaapi-copy`:
- **First-frame green screens** (upstream Issue [#2](https://github.com/snowf14k3/venus-vaapi-driver/issues/2))
- **Green flashes and jumping back to earlier frames** on B-frame / hover-preview / looping videos in Chromium (upstream Issue [#1](https://github.com/snowf14k3/venus-vaapi-driver/issues/1))
- **30-second `VA_STATUS_ERROR_HW_BUSY` timeouts** in `mpv` / FFmpeg on B-frame H.264 streams

All fixes have been submitted upstream in **[`snowf14k3/venus-vaapi-driver#3`](https://github.com/snowf14k3/venus-vaapi-driver/pull/3)** and are included in [`vaapi/patches/venus-vaapi-driver-decode-fix.patch`](../vaapi/patches/venus-vaapi-driver-decode-fix.patch).

---

## Root Causes & Fixes

1. **H.264 missing decode-order zero-delay control (`src/v4l2_decoder.c`)**:
   - `V4L2_CID_MPEG_VIDEO_DEC_DISPLAY_DELAY=0` + `DISPLAY_DELAY_ENABLE=1` was only set for HEVC, leaving H.264 in Venus's internal display-order reorder buffer (3–6+ frames lag behind VA-API's own DPB).
   - **Fix**: Enable `DISPLAY_DELAY=0` + `DISPLAY_DELAY_ENABLE=1` for all decode formats. On SM8250 `/dev/video0`, H.264 B-frame streams immediately switch from out-of-order delayed output (`got=0,0,0,[1],[3],[2,5]...[9]`) to **exact 1-to-1 decode order (`[1]..[16]`)**.
2. **Unsynchronized `vaEndPicture()` & `vaExportSurfaceHandle()` (`src/decode.c`, `src/objects.c`)**:
   - Chromium reuses already-exported DMA-BUF surfaces and hands them directly to Viz GL after `vaEndPicture()` without calling `vaSyncSurface()`. Because this driver copies NV12 frames via CPU into MSM GEM DMA-BUFs (no kernel GPU fence), returning early let GL sample uninitialized or stale frames.
   - **Fix**: Tag every decode submission with a monotonic 64-bit tag `(decode_sequence << 8) | surface_slot` so stale frames can never overwrite recycled surfaces, complete the CPU->DMABUF copy in `vaEndPicture()` (~1–3 ms with `DISPLAY_DELAY=0`, short 15 ms non-blocking wait for invisible VP9 `show_frame=0` frames), and sync pending decodes in `vaExportSurfaceHandle()`, `vaDeriveImage()`, and `vaGetImage()`.
3. **All-zero NV12 initialization & per-frame green wipe (`src/objects.c`)**:
   - `memset(..., 0)` produces `Y=0, U=0, V=0`, which renders as **bright green** in YUV→RGB. `venus_surface_copy_from_yuv420()` also zeroed the entire surface before every frame copy.
   - **Fix**: Initialize new NV12/P010 surfaces to true video black (`Y=0x10, UV=0x80` / `0x1000, 0x8000`) and remove the redundant per-frame `memset(..., 0)`.
4. **V4L2 CAPTURE buffer count, leaks, dynamic resolution change & `POLLOUT` spin (`src/v4l2_decoder.c`, `src/backend_internal.h`, `src/h264_annexb.c`)**:
   - Query `V4L2_CID_MIN_BUFFERS_FOR_CAPTURE` (SM8250 H.264 reports `18`, above the hardcoded `16`) and allocate `max(requested, min + 2)` up to 32.
   - Always re-queue non-`LAST` CAPTURE buffers in `dequeue_capture()` even if the callback reports an error.
   - Properly reconfigure CAPTURE (`STREAMOFF` → `release_buffers` → `setup_capture`) on mid-stream `V4L2_EVENT_SOURCE_CHANGE`.
   - Poll `POLLOUT` only when all OUTPUT buffers are queued (eliminates 100% CPU busy-spin while waiting for CAPTURE).
   - Raise pool caps (`16` contexts / `192` surfaces / `1024` buffers) for multi-video feeds and emit H.264 `level_idc=51`.
5. **Release (`-O3`) build**:
   - Upstream `install.sh` defaulted to Meson's debug build (`-g -O0`, `1.08 MB`). Building with `--buildtype=release` produces a `217 KB` optimized `.so`.

---

## Build & Enable in Chromium / Chrome

```bash
./scripts/build-install-venus-vaapi.sh
```

Then add the flags in [`tuning/desktop/chrome-flags.txt`](../tuning/desktop/chrome-flags.txt) to your Chrome `.desktop` launcher (`~/.local/share/applications/google-chrome.desktop`):

```text
--enable-features=AcceleratedVideoDecodeLinuxGL,AcceleratedVideoDecodeLinuxZeroCopyGL,VaapiIgnoreDriverChecks
--enable-gpu-rasterization
--disable-lcd-text
--disable-font-subpixel-positioning
```

> **Note**: Always quit Chrome completely (`Ctrl+Shift+Q` or menu → Exit, not just closing a window or `chrome://restart`) so the GPU process reloads the new `/usr/lib/aarch64-linux-gnu/dri/venus_drv_video.so`. Verify in `chrome://media-internals` that playback uses `VaapiVideoDecoder`.
