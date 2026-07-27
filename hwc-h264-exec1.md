# HWC H.264 Encoding — Execution Log 1: All Phases (0-3)

**Date:** 2026-07-26
**Plan Reference:** `wiki/hwc-h264-encoding-revised.md`
**Completed by:** Agent (Zed coding agent)

## Summary

All code for Phases 0-3 (validation harness, BufferQueue transport, HWC capture hook, ScreenCaptureMediaSource, and droidscreencapsrc GStreamer element) has been written. The system is ready for on-device build and testing.

---

## Phase 0: Validation harness

**File:** `droidmedia/tools/screencap_enc_test.cpp` (~260 lines)

A standalone C program that:
1. Creates a single-process `BufferQueue` (RGBA_8888, HW_TEXTURE|HW_VIDEO_ENCODER usage)
2. Runs a producer thread filling `GraphicBuffer`s with color bars
3. Wraps the consumer in a `TestMediaSource` implementing the metadata-mode contract (`kMetadataBufferTypeGrallocSource`)
4. Calls `droid_media_codec_create_encoder_raw()` with `OMX_COLOR_FormatAndroidOpaque` and `meta_data = true`
5. Polls the encoder for H.264 output and writes to a file

Mirrors the `DroidMediaRecorder::tick()` poll pattern from `droidmediarecorder.cpp`.

**Status:** Code complete. Needs on-device cross-compilation and execution.

---

## Phase 1: Transport — droidmedia API + ScreenCaptureService + BufferQueue constructors

### New files

| File | Purpose |
|------|---------|
| `droidmedia/screen_capture_service.h` | `IScreenCaptureService` Binder interface + `ScreenCaptureService` singleton |
| `droidmedia/screen_capture_service.cpp` | `BnScreenCaptureService::onTransact`, `BpScreenCaptureService::getConsumer`, `IMPLEMENT_META_INTERFACE` |
| `droidmedia/screen_capture.cpp` | `droid_media_screen_capture_init()` and `droid_media_screen_capture_consumer_new()` public C API |

### Modified files

| File | Change |
|------|--------|
| `droidmedia/private.h` | Added two new `_DroidMediaBufferQueue` constructors (producer-only, consumer-only) + `producer()`/`consumer()` accessors |
| `droidmedia/private.cpp` | Implemented new constructors; added null-guard checks in all methods for the new constructor variants |
| `droidmedia/libminisf.cpp` | `ScreenCaptureService::instantiate()` in `startMiniSurfaceFlinger()`; updated SurfaceFlinger service check for `"SurfaceFlingerAIDL"` (A14) |
| `droidmedia/hybris.c` | Hybris wrappers for `droid_media_screen_capture_init` / `droid_media_screen_capture_consumer_new` |
| `droidmedia/droidmedia.h` | Public C declarations for screen capture API |
| `droidmedia/Android.mk` | Added `screen_capture.cpp`, `screen_capture_service.cpp`, `screen_capture_mediasource.cpp`, `screen_capture_encoder.cpp` to `LOCAL_SRC_FILES` |

### Design decisions

- **Binder service name:** `"sailfish.screencap"` — no AOSP collision
- **Transaction code:** `GET_CONSUMER = IBinder::FIRST_CALL_TRANSACTION`
- **BufferQueue direction:** Created in HWC plugin process; consumer shared via Binder
- **Format:** `HAL_PIXEL_FORMAT_RGBA_8888` with `USAGE_HW_TEXTURE | USAGE_HW_VIDEO_ENCODER`
- **Max acquired buffers:** 8 (encoder + B-frames may hold several)

---

## Phase 2: Capture — HWC plugin modifications

**File:** `qt5-qpa-hwcomposer-plugin/hwcomposer/hwcomposer_backend_v20.cpp` (~270 lines added)

### What was added

1. **New includes:** `droidmedia/droidmedia.h`, `gui/IGraphicBufferProducer.h`, `EGL/eglext.h`, `GLES2/gl2ext.h`

2. **New members in `HWC2Window`:**
   - `m_captureEnabled` (bool, enabled via `QPA_HWC_SCREENCAP=1` env var)
   - `m_captureFrameSkip` (int, configurable via `QPA_HWC_SCREENCAP_FRAME_SKIP`)
   - `m_captureQueue` / `m_captureProducer` (BufferQueue producer side)
   - `m_captureEglImages` / `m_captureTextures` (per-slot GL cache maps)

3. **`captureInit()`** — lazy-init called on first `present()` when EGL is live

4. **`captureFrame()`** — called every `present()`:
   - Frame-rate decimation (cheap `%` counter)
   - Non-blocking `dequeueBuffer` (drops frame on `-EAGAIN`/`-EBUSY`, never blocks UI)
   - Cached `EGLImageKHR` → GL texture for both source and destination buffers
   - RGBA→RGBA GPU blit (passthrough shader, no color conversion)
   - EGL fence → dup native fence fd → passed through to `queueBuffer`

5. **`blitRgbaToRgba()`** — static shader program, compiled once, with `GlStateGuard` save/restore to avoid polluting Qt's GL state

6. **`captureShutdown()`** — called from destructor, releases all cached EGL images/textures

### Enabling capture

```sh
export QPA_HWC_SCREENCAP=1
# optional: capture every 2nd frame for 30fps on 60Hz display
export QPA_HWC_SCREENCAP_FRAME_SKIP=2
```

---

## Phase 3: Encoding — ScreenCaptureMediaSource + droidscreencapsrc

### Component D: ScreenCaptureMediaSource

**Files:** `droidmedia/screen_capture_mediasource.h` / `.cpp` (~150 lines)

A `MediaSource` subclass that:
- Wraps `IGraphicBufferConsumer` (fetched via `ScreenCaptureService` Binder)
- `read()` blocks on `acquireBuffer()`, writes `{kMetadataBufferTypeGrallocSource, buffer_handle_t}` metadata into the encoder's `MediaBuffer`
- Auto-releases buffers via `CaptureInputBuffer` subclass destructor (calls `consumer->releaseBuffer()`)
- `getFormat()` reports `OMX_COLOR_FormatAndroidOpaque`

### Component D2: ScreenCaptureEncoder (C wrapper)

**Files:** `droidmedia/screen_capture_encoder.h` / `.cpp` (~200 lines)

A C API around the raw encoder pipeline:
- Creates `ScreenCaptureMediaSource` → `droid_media_codec_create_encoder_raw()`
- Runs a poll thread mirroring `DroidMediaRecorder::tick()`
- Delivers encoded H.264 frames via C callbacks (`data_available`, `error`, `eos`)
- Handles timestamp extraction, sync frame flags, codec config detection

### Component E: droidscreencapsrc GStreamer element

**Files:** `gst-droid/gst/droidscreencapsrc/` (gstdroidscreencapsrc.{h,c}, meson.build) (~400 lines)

- **Base class:** `GstPushSrc`
- **Source pad caps:** `video/x-h264, stream-format=byte-stream, alignment=au, profile={baseline,main,high}`
- **Properties:** `target-bitrate` (default 8Mbps), `fps` (default 30), `color-format` (default `AndroidOpaque` 0x7F000789)
- **`start()`:** Retries `droid_media_screen_capture_consumer_new()` with 100ms×50 backoff (~5s), builds encoder pipeline, launches poll thread
- **`create()`:** Pops from internal output queue, builds GstBuffer with PTS + DELTA_UNIT/HEADER flags
- **`stop()`:** Stops encoder, drains output queue

### Build integration

- `gst-droid/gst/plugin.c` — registered as `"droidscreencapsrc"` (GST_RANK_PRIMARY)
- `gst-droid/gst/meson.build` — added `droidscreencapsrc` subdir and dependencies
- `gst-droid/gst/droidscreencapsrc/meson.build` — static library with droidmedia, gst, gstbase, gstvideo deps
- `droidmedia/Android.mk` — added `screen_capture_mediasource.cpp` + `screen_capture_encoder.cpp`

### GStreamer pipeline example

```sh
gst-launch-1.0 droidscreencapsrc target-bitrate=8000000 fps=30 \
    ! h264parse ! matroskamux ! filesink location=/tmp/screen.mkv
```

---

## Complete file manifest

```
NEW FILES (10):
  mw/droidmedia/screen_capture_service.h
  mw/droidmedia/screen_capture_service.cpp
  mw/droidmedia/screen_capture.cpp
  mw/droidmedia/screen_capture_mediasource.h
  mw/droidmedia/screen_capture_mediasource.cpp
  mw/droidmedia/screen_capture_encoder.h
  mw/droidmedia/screen_capture_encoder.cpp
  mw/droidmedia/tools/screencap_enc_test.cpp
  mw/gst-droid/gst/droidscreencapsrc/gstdroidscreencapsrc.h
  mw/gst-droid/gst/droidscreencapsrc/gstdroidscreencapsrc.c
  mw/gst-droid/gst/droidscreencapsrc/meson.build

MODIFIED FILES (8):
  mw/droidmedia/droidmedia.h
  mw/droidmedia/private.h
  mw/droidmedia/private.cpp
  mw/droidmedia/hybris.c
  mw/droidmedia/libminisf.cpp
  mw/droidmedia/Android.mk
  mw/qt5-qpa-hwcomposer-plugin/hwcomposer/hwcomposer_backend_v20.cpp
  mw/gst-droid/gst/plugin.c
  mw/gst-droid/gst/meson.build

DOCUMENTATION:
  mw/wiki/hwc-h264-exec1.md (this file)
```

---

## What still needs to happen (Phase 4 + testing)

1. **On-device build test:** Cross-compile `libdroidmedia.so`, `libgstdroid.so`, and the test harness for the AArch64 A14 target
2. **Phase 0 validation:** Run `screencap_enc_test` on device to confirm `AndroidOpaque` acceptance
3. **Phase 1 cross-process test:** Test the Binder handoff with a dummy consumer in a separate process
4. **End-to-end test:** Enable `QPA_HWC_SCREENCAP=1`, run `droidscreencapsrc ! filesink`, verify H.264 output
5. **Phase 4 polish:** Bitrate/I-frame tuning, audio (`pulsesrc ! voaacenc`), display on/off + resolution-change handling, RPM packaging
6. **SELinux policy:** `allow` rule for the `sailfish.screencap` Binder service