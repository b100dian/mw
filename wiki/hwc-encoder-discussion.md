Human:
I want to enable video encoding in h264 of the screen in sailfishos based on hybris.

The folder hybris/mw we're into has some of the middleware of sailishos, some related to display, some to telephony.
The outside hadk folder is a slimmed down Android 14 checkout, with some "hybris-patches" applied.

Sailfishos:
My understanding of the Sailfishos stack is that it is based on Android vendor services that talk to some slim kernel drivers, and those expose interfaces (such as binder) that are more standardized, and used by e.g. ofono-droid and pulseaudio-droid and qpa-hwcomposer and gstreamer-droid plugins. To use them, hybris makes the bionic to libc call convention switch.
The kernel is modified to be able to boot a sailfish init script that continues with systemd and at one point, systemd starts a serice that kicks in android's init, with many services disabled, so only those needed (audio, hwc, telephony) are running. That service (droid-hal-init) might fail if some services are missing so some stubs are created.
/End of sailfishos understanding of mine

Now there are multiple pieces of how QT from sailfishos dispays to HWComposer, some being in this folder, like qt5-qpa stuff or nemo- and qtmultimedia (maybe). Same goes for video decoding, gst-droid.

Then there are some notes in hwc-encoder-plan.md that were made from a previous investigation. This is just saved to give you an idea about what's boing an, and to corroborate them with the above notes.

Back to the problem;
gst-droid and droidmedia only ever "encode" buffers coming from camera. It should be possible to have buffers coming from the display encoded.

What I want from you:
Plese write a plan on how would you go around and implement the screen video recording using accelerted encoding, so presumably using android APIs.

Make a high level description of the plan and then enter into some details about how would you do, but don't start the implemenation yet.

Include in your plan the requirements above.

Plan file: hwc-h264-encoding.md in current mw root

Output plan
----

HWC Display → H.264 Hardware Encoder: Implementation Plan

**Date:** 2026-07-07
**Context:** Enabling hardware-accelerated H.264 encoding of screen content on SailfishOS/hybris by feeding the HWC display output into the existing Android `MediaCodec`-backed encoder infrastructure.

---

## 1. Architecture Recap (from codebase analysis)

### 1.1 Display Pipeline

```
Qt App → EGL render → GraphicBuffer (RGBA_8888) → HWC HAL → Display HW
```

The `qt5-qpa-hwcomposer-plugin` (`hwcomposer_backend_v20.cpp`, `HWC2Window::present()`) renders EGL directly into `GraphicBuffer` slots via triple-buffering. There is **no SurfaceFlinger** — Qt's EGLFS integration bypasses it entirely.

### 1.2 MiniSurfaceFlinger

A stub Binder service running **in the same process** as the HWC plugin (launched via `libminisf.so` → `startMiniSurfaceFlinger()` from `initLegacyHwComposerQuirks()` in `hwcomposer_backend.cpp`). Currently all meaningful methods return `BAD_VALUE` or `NULL`:
- `captureScreen()` → `BAD_VALUE`
- `createDisplay()` → `NULL`
- `getBuiltInDisplay()` → `NULL`
- `getStaticDisplayInfo()` → `BAD_VALUE`

### 1.3 Hardware Encoder Path

```
gst-droid (gstdroidvenc.c)
  └── droid_media_codec_create_encoder(&md)
        └── DroidMediaCodecBuilder::createCodec()     [droidmediacodec.cpp:380-530]
              └── AsyncCodecSource::Create(src, format, isEncoder, ...)
                    └── android::MediaCodec (OMX IL / Codec2 HAL)
                          └── Vendor HW encoder
```

Key insight: `droidvenc` creates a `MediaCodecSource` with an **arbitrary** `MediaSource` — it does NOT depend on `CameraSource`. The encoder should work with any properly formatted YUV frames.

### 1.4 Key Files Already Referenced

| File | Role |
|---|---|
| `qt5-qpa-hwcomposer-plugin/hwcomposer/hwcomposer_backend_v20.cpp` | HWC v2.0 render path, `present()` at L162-250 |
| `qt5-qpa-hwcomposer-plugin/hwcomposer/hwcomposer_backend.cpp` | `initLegacyHwComposerQuirks()` at L73-104 |
| `droidmedia/services/services_14_0_0.h` | `MiniSurfaceFlinger` stub at L196-381 |
| `droidmedia/droidmediacodec.cpp` | Encoder creation at L380-530 |
| `droidmedia/droidmediacodec.h` | `DroidMediaCodecEncoderMetaData` at L77-90 |
| `gst-droid/gst/droidcodec/gstdroidvenc.c` | GStreamer encoder element (full file) |
| `gst-droid/gst/droidcamsrc/gstdroidcamsrcdev.c` | Camera→GStreamer reference via `BufferQueue` |
| `droidmedia/droidmediabuffer.cpp` | `_DroidMediaBuffer` wrapping `GraphicBuffer` |
| `gst-droid/gst-libs/gst/droid/gstdroidmediabuffer.h` | Supports RGBA among other formats |
| `gst-droid/gst/plugin.c` | Element registration, `plugin_init()` at L53-115 |

---

## 2. The Core Challenge

Screen buffer = **RGBA_8888** `GraphicBuffer` in HWC plugin process.  
Encoder input = **YV12** (or NV12) raw frames in a GStreamer process.

Four sub-problems:

1. **Capture** screen buffer from the HWC plugin
2. **Convert** RGBA_8888 → YV12/NV12  
3. **Transport** frame from Qt compositor process to GStreamer process
4. **Feed** to `droidvenc` for HW encoding

---

## 3. Implementation Approaches

### 3.1 Approach A: `captureScreen()` in MiniSurfaceFlinger (Screenshot → Polling)

**Key advantage:** MiniSurfaceFlinger and HWC plugin share the same process — no IPC needed for buffer access.

**Changes needed:**

1. **HWC plugin hook** (`hwcomposer_backend_v20.cpp`): After `eglSwapBuffers()`, store the latest `GraphicBuffer` in a process-global variable behind a mutex.

2. **MiniSurfaceFlinger** (`services_14_0_0.h`):
   - `getBuiltInDisplay()` → return a valid `BBinder` token
   - `getStaticDisplayInfo()` → return real width/height/refresh
   - `getDynamicDisplayInfo()` → return refresh rate from HWC config
   - `captureScreen(producer, crop, w, h, ...)` → dequeue from producer, copy screen buffer, queue

3. **GStreamer side**: Poll `captureScreen()` in a loop → `videoconvert` → `droidvenc`

**Effort:** ~200 lines. **Risk:** Medium (frame pacing, polling misses/duplicates frames).

### 3.2 Approach B: New GStreamer `droidscreencapsrc` via Shared Memory

**Concept:** HWC plugin writes frames to a POSIX `shm_open()` ring buffer on each `swap()`. A new GStreamer source element reads them.

Since `GraphicBuffer` handles are cross-process (gralloc-allocated), the underlying `native_handle_t` fd can be shared via Unix domain socket `SCM_RIGHTS` for **zero-copy** pixel transport.

**Effort:** ~500-800 lines across HWC plugin (50 lines) + shared memory protocol (80 lines) + GStreamer element (400 lines) + build (50 lines).

**Risk:** Medium (shared memory sync, fd lifecycle across processes).

### 3.3 Approach C: `createDisplay()` Virtual Display in MiniSurfaceFlinger

**Concept:** Full virtual display state machine in MiniSurfaceFlinger. HWC plugin calls `onFrameComposed()` per frame (direct C++ call, same process). MiniSurfaceFlinger pushes to registered virtual display `BufferQueue`s with proper fence sync.

**Effort:** ~700 lines. **Risk:** High (multi-threaded, fence management, backpressure).

### 3.4 Approach D: `glReadPixels` + Pipe (Quick Prototype)

30 lines in the HWC plugin. Slow (stalls GPU), framing issues with pipe. **For initial POC only.**

---

## 4. Recommended Phased Plan

### Phase 1: Validate encoder with non-camera input (1 day)

```sh
gst-launch-1.0 videotestsrc ! video/x-raw,format=YV12,width=1080,height=2340,framerate=30/1 ! \
  droidvenc bitrate=8000000 ! video/x-h264,stream-format=byte-stream ! filesink location=/tmp/test.h264
```

If it fails: check OMX/Codec2 HAL registration in `/vendor/etc/media_codecs.xml`, try NV12/YV12/NV21, check SELinux. Fallback: software `x264enc`.

### Phase 2: `captureScreen` in MiniSurfaceFlinger + polling GStreamer source (2-3 days)

Deliverable: Working screenshot + basic continuous capture via polling.

### Phase 3: Push-based continuous capture (3-5 days)

Preferred: `onFrameComposed()` callback in MiniSurfaceFlinger → virtual display `BufferQueue`. Fallback: shared memory ring buffer.

### Phase 4: HW encoding integration & optimization (2-3 days)

- NEON-optimized RGBA→NV12 conversion
- Stride/alignment handling
- End-to-end pipeline with audio

### Phase 5: Polish & packaging (1-2 days)

---

## 5. Key Technical Details

**Color conversion:** RGBA_8888 → NV12 is ideal (NV12 is most widely supported HW encoder input). Start with GStreamer `videoconvert` for correctness; optimize with NEON later.

**Fence synchronization:** The HWC `presentFence` signals when the previous frame's buffer is free. Capture only after the fence signals to avoid reading in-use GPU memory.

**Frame rate:** Display may be 60/90/120 Hz — encode at a lower rate (e.g., 30 fps) via frame dropping or a timer.

**Android version compatibility:** `services/` has per-version headers (`services_10_0_0.h` through `services_14_0_0.h`). On A14 the service name is `"SurfaceFlingerAIDL"` not `"SurfaceFlinger"`.

---

## 6. Summary of Changes

| Component | Change | Effort | Phase |
|---|---|---|---|
| `hwcomposer_backend_v20.cpp` | Export screen buffer to global state | ~40 lines | 2 |
| `services_*_0_0.h` (MiniSurfaceFlinger) | Implement `captureScreen`, `getBuiltInDisplay`, `getDisplayInfo` | ~250 lines | 2 |
| New `gstdroidscreencapsrc.c` (GStreamer) | Screen capture source element | ~500 lines | 2-3 |
| MiniSurfaceFlinger `createDisplay` (optional) | Virtual display + frame callback | ~500 lines | 3 |
| `gstdroidvenc.c` | Better error handling, try NV12 | ~30 lines | 1 |
| `plugin.c` | Register new element | ~5 lines | 2 |

## 7. Risks & Mitigations

| Risk | Mitigation |
|---|---|
| `droidvenc` HW encoder doesn't work | Fallback to `x264enc` (CPU) |
| RGBA→YV12 conversion bottleneck | NEON SIMD, or zero-copy if encoder supports opaque format |
| Shared memory ring buffer stalls UI | Triple-buffered, non-blocking write (drop frames) |
| Binder ABI mismatch across Android versions | `#if ANDROID_MAJOR` gated code per version header |

## 8. Open Questions

1. Does `/vendor/etc/media_codecs.xml` list an AVC encoder component?
2. What color format does the encoder actually accept? (Query at runtime via `droid_media_codec_get_supported_color_formats()`)
3. Is `libI420colorconvert.so` available on the device?
4. Screen resolution? (Query from HWC `getActiveConfig` dynamically)
5. Encode at full resolution or downscale? (Add a `scale-factor` property)

---

Human:
I'll add some more details: I dont think drodvenc works with any buffer. There are specific metadata attached (DroidVideoMetaData) to signal just that.
So we need a native buffer solution, that is also already gralloc'd. I do not want software encoding.
Probably the droidscreencapsrc with fence you're suggesting.

---
Refined Understanding

You're right — `droidvenc`'s sink pad requires `memory:DroidVideoMetaData` (`GST_CAPS_FEATURE_MEMORY_DROID_VIDEO_META_DATA`), and looking deeper into the code path, I see there are **two distinct encoder input paths** in the codebase:

### Path 1 (current `droidvenc`): Raw CPU Data
```
gstdroidvenc_handle_frame()
  → gst_buffer_map(buffer, &info, GST_MAP_READ)      // CPU maps the GstBuffer
  → droid_media_codec_queue(codec, &data, &cb)        // passes raw pointer
    → InputBuffer(raw_data, size, ...)                 // wraps in MediaBuffer with raw data
      → m_src->add(buffer)                             // feeds encoder
```
This works but has a CPU map/copy — the encoder then internally copies to its own gralloc buffers.

### Path 2 (camera recorder): Gralloc Metadata (Zero-Copy)
```
DroidMediaRecorder
  → CameraSource::CreateFromCamera()                  // CameraSource produces MediaBuffers
                                                       // containing GraphicBuffer metadata
  → droid_media_codec_create_encoder_raw(meta, looper, src)
    → AsyncCodecSource::Create(src, format, isEncoder, flags, window, looper)
      // src.read() returns MediaBuffers with .graphicBuffer() → valid GraphicBuffer
      // Encoder accesses gralloc memory directly — zero copy
```

This second path is what you want: **gralloc-allocated `GraphicBuffer` handles passed directly to the encoder's metadata input**, bypassing any CPU mapping.

---

## The Core Architecture for Screen Recording

```
[HWC plugin process]                          [GStreamer process]
       │                                              │
  EGL render to                                    droidscreencapsrc
  GraphicBuffer(RGBA)                                  │
       │                                          Reads from consumer
  GL blit RGBA→NV12                                    │
  to new GraphicBuffer                              Pushes GstBuffers
  (gralloc NV12)                                   (memory:DroidVideoMetaData)
       │                                               │
  Enqueue to                                          droidvenc
  BufferQueue                                         │
  (producer side)                                  HW encodes NV12
       │                                          → H.264 output
  hwc_present() → fence
```

The key design decisions:

1. **Color conversion must happen on the GPU** in the HWC plugin process (which has an active EGL context), converting the screen's RGBA `GraphicBuffer` to an NV12 `GraphicBuffer` (the format most HW encoders accept).

2. **The NV12 `GraphicBuffer` is enqueued to a `BufferQueue`** — the producer side lives in the HWC plugin, the consumer side is in the GStreamer process.

3. **Fence synchronization**: the HWC `presentFence` tells us when the screen buffer is free. We use that to ensure the NV12 copy is complete and safe before enqueuing.

4. **The `droidscreencapsrc` GStreamer element** dequeues from the `BufferQueue` consumer, wraps the `DroidMediaBuffer` (which wraps the `GraphicBuffer`) as GStreamer memory, and pushes it downstream to `droidvenc`.


Human:
A couple of quick questions:
Why are you looking for NV12, is that H264?
How do you know Qt's is RGBA_8888  ?
Is Android Hardware already capable of pulling out NV12 frames from the presented window?
