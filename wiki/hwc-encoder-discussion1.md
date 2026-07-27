# HWC Display → GStreamer Encoder: Feasibility Analysis

**Date:** 2026-07-06
**Context:** Can gst-droid encode the HWC (Hardware Composer) display output, so SailfishOS screen content can be streamed/recorded through a GStreamer pipeline?

---

## 1. How the Display Pipeline Works Today

```
Qt App → EGL render → GraphicBuffer → hwc HAL prepare()/set() → Display Hardware
```

The `qt5-qpa-hwcomposer-plugin` (`hwcomposer_backend_v20.cpp`) renders EGL into `GraphicBuffer` slots, then commits them directly to the display hardware via the HWC HAL (`hwc2_compat_display_present()`). There is **no Android SurfaceFlinger compositor** in the rendering path — frames go from EGL straight to the display.

The `EGLNativeWindowType` returned by `createWindow()` is a `HWC2Window` subclass that maintains a triple-buffer slot cache. On each `swap()`, the EGL-rendered `GraphicBuffer` is passed as the HWC client target:

```cpp
// hwcomposer_backend_v20.cpp:193-221
hwc2_compat_display_set_client_target(hwcDisplay, slot, target,
                                      acquireFenceFd, HAL_DATASPACE_UNKNOWN);
hwc2_compat_display_present(hwcDisplay, &presentFence);
```

---

## 2. Why Normal Android Screen Capture Doesn't Work

In standard Android, screen capture goes through one of two paths:

| Path | Mechanism | Android API |
|---|---|---|
| Screenshot | `SurfaceComposerClient::captureScreen()` | single-frame capture |
| Screen recording | Virtual display via `createDisplay()` + `MediaCodec` | continuous streaming |

Both paths rely on **SurfaceFlinger** — the system compositor that receives every frame from every app and renders the final composed output. In SailfishOS with the HWC plugin, SurfaceFlinger isn't doing any composition. The `MiniSurfaceFlinger` service exists only as a **decoy** to prevent Android media services from crashing when they look up `"SurfaceFlinger"` via the Binder service manager.

Every `captureScreen()` overload returns `BAD_VALUE`, every `createDisplay()` returns `NULL`, and `getBuiltInDisplay()` returns `NULL`:

```cpp
// services/services_14_0_0.h
sp<IBinder> createDisplay(const String8&, bool)     { return NULL; }
sp<IBinder> getBuiltInDisplay(int32_t)               { return NULL; }
status_t captureScreen(...)                           { return BAD_VALUE; }  // all overloads
```

**Conclusion: None of the standard Android screen-capture Binder IPC paths work.**

---

## 3. What gst-droid Already Has That's Relevant

### 3.1 `droidcamsrc` — the camera-to-GStreamer bridge

The camera source element already knows how to:
- Receive `GraphicBuffer` objects from a `DroidMediaBufferQueue` (wrapping `BufferQueue`)
- Map them to CPU memory via `gst_buffer_map()`
- Push raw video frames into a GStreamer pad

This is the proven pattern for getting Android `GraphicBuffer` data into GStreamer.

### 3.2 `ConsumerBase.cpp` / `GLConsumer.cpp`

These files (sitting in the gst-droid root, not compiled into the build) implement the consumer-side pattern: connect to an `IGraphicBufferConsumer`, receive `onFrameAvailable()` callbacks, acquire `GraphicBuffer` objects. They are clones of AOSP's `SurfaceTexture` / `GLConsumer` and represent the exact mechanism needed to convert GL-rendered output into a stream.

### 3.3 `DroidMediaBufferQueue` in `droidmedia/`

The `_DroidMediaBufferQueue::releaseMediaBuffer()` path proves cross-process `GraphicBuffer` sharing works. Buffers allocated via `gralloc` are inherently cross-process — the `native_handle_t` is shareable via Binder or Unix domain socket.

### 3.4 `DroidMediaRecorder`

Exists but routes through `libmediandk.so` → Android `MediaCodec`, which is unavailable on the target device.

---

## 4. Two Implementation Approaches

### Approach A: Implement `captureScreen` in MiniSurfaceFlinger (simpler)

**Key insight:** MiniSurfaceFlinger runs **in the same process** as the HWC plugin (via `startMiniSurfaceFlinger()` called from `initLegacyHwComposerQuirks()` in `hwcomposer_backend.cpp`). This means the composited `GraphicBuffer` from the HWC `swap()` is directly accessible — no IPC needed.

**What's needed:**

| Component | Change | Effort |
|---|---|---|
| `MiniSurfaceFlinger::captureScreen()` | Implement buffer dequeue → memcpy screen framebuffer → queue cycle | ~100 lines |
| `MiniSurfaceFlinger::getBuiltInDisplay()` | Return a valid Binder token (not NULL) | ~5 lines |
| `MiniSurfaceFlinger::getDisplayInfo()` / `getStaticDisplayInfo()` / `getDynamicDisplayInfo()` | Return real display dimensions, format, refresh rate from HWC config | ~20 lines |
| HWC plugin hook | After `eglSwapBuffers()`, store the latest `GraphicBuffer*` in a shared global/static accessible by MiniSurfaceFlinger | ~10 lines |
| Format conversion | The caller may request `I420`/`NV12` but the screen is `RGBA_8888` — needs a conversion path (`droidmediaconvert` or CPU swizzle) | ~50 lines |

**Architecture:**

```
[HWC plugin swap()]
     │
     ├── eglSwapBuffers(display, surface)
     │   └── GraphicBuffer now contains composed screen
     │
     ├── g_screenBuffer = mLastBuffer;      // NEW: expose to MiniSurfaceFlinger
     │
     └── hwc2_compat_display_present()

[MiniSurfaceFlinger::captureScreen(producer, crop, w, h, …)]
     │
     ├── producer->dequeueBuffer(&slot, &fence, w, h, RGBA_8888, …)
     ├── fence->waitForever()
     ├── producer->requestBuffer(slot, &captureBuf)
     ├── void* src = g_screenBuffer->getNativeBuffer()  // same process, direct access
     ├── void* dst = captureBuf->getNativeBuffer()
     ├── memcpy(dst, src, w * h * 4)                    // or GPU blit for scaling
     ├── producer->queueBuffer(slot, …, &qbo, nullptr)
     └── return NO_ERROR
```

**Caller side (GStreamer, Android apps, etc.):**

```cpp
sp<IGraphicBufferProducer> producer;
sp<IGraphicBufferConsumer> consumer;
BufferQueue::createBufferQueue(&producer, &consumer);

// Ask MiniSurfaceFlinger to capture to our producer
sp<ISurfaceComposer> sf = ComposerService::getComposerService();
sf->captureScreen(displayToken, producer, crop, w, h, …, rotation);

// Read the frame from our consumer
BufferItem item;
consumer->acquireBuffer(&item, 0);
void* pixels = item.mGraphicBuffer->lock(GRALLOC_USAGE_SW_READ_OFTEN, &rect);
// … encode pixels …
item.mGraphicBuffer->unlock();
consumer->releaseBuffer(item.mSlot, item.mFrameNumber, …);
```

**Limitation:** Single-frame (screenshot-style) capture only. For continuous streaming, you'd need to call `captureScreen` in a loop, which is racy — you might miss frames or get duplicates.

---

### Approach B: Implement `createDisplay` for continuous capture (harder)

**What's needed:**

| Component | Change | Effort |
|---|---|---|
| MiniSurfaceFlinger virtual display state machine | Track a list of active virtual displays, each with its own BufferQueue, state, and thread | ~300 lines |
| Per-frame callback from HWC plugin | On every vsync/swap, call `MiniSurfaceFlinger::onFrameComposed(graphicBuffer, fence, timestamp)` | ~20 lines |
| Buffer lifecycle management | Maintain a pool of `GraphicBuffer` slots per virtual display; handle backpressure when consumer is slow (drop frames, throttle) | ~200 lines |
| Fence synchronization | Thread the acquire fence from `dequeueBuffer` and the release fence from `hwc_present` correctly so the GPU driver doesn't stomp on in-use memory | ~100 lines |
| V-Sync alignment | The capture framerate must be driven by the display's vsync signal; MiniSurfaceFlinger subscribes to HWC vsync events | ~50 lines |

**Architecture:**

```
[HWC plugin]                         [MiniSurfaceFlinger]              [GStreamer consumer]
     │                                       │                               │
     ├── eglSwapBuffers()                    │                               │
     │   g_screenBuffer = buf               │                               │
     │                                       │                               │
     ├── hwc_present() → fence              │                               │
     │                                       │                               │
     │                                       ├── HWC vsync interrupt ──────►│
     │                                       │                               │
     │                                       ├── for each virtual display:   │
     │                                       │     dequeueBuffer(&slot, …) ─►│
     │                                       │     requestBuffer(captureBuf) │
     │                                       │     fence->wait()             │
     │                                       │     memcpy(captureBuf,        │
     │                                       │            g_screenBuffer)    │
     │                                       │     queueBuffer(slot, …, qbo)─►│
     │                                       │                               │
     │                                       │                               ├── consumer acquires
     │                                       │                               ├── pushes to Gst pad
     │                                       │                               └── releases buffer
```

This **is** essentially a mini-SurfaceFlinger. The key complexity is buffer lifecycle: if the consumer releases buffers too slowly, MiniSurfaceFlinger must handle the stall without blocking the HWC plugin's render loop (which would freeze the UI).

---

## 5. GlReadPixels Alternative (No HAL Changes)

A simpler path that avoids touching MiniSurfaceFlinger or any Android HAL code:

In the HWC plugin's `swap()`, after `eglSwapBuffers()`:

```cpp
// Read the current framebuffer back via EGL
glReadPixels(0, 0, width, height, GL_RGBA, GL_UNSIGNED_BYTE, buffer);
// Write buffer to a pipe or shared memory segment
write(capture_pipe_fd, buffer, width * height * 4);
```

Then on the GStreamer side:
```sh
gst-launch-1.0 -e \
  filesrc location=/tmp/hwc_capture_pipe ! \
  video/x-raw,format=RGBA,width=1080,height=2520,framerate=30/1 ! \
  videoconvert ! x264enc ! h264parse ! \
  tcpclientsink host=192.168.1.25 port=9999
```

**Pros:**
- No GStreamer element needed (`filesrc` or `appsrc` works)
- No MiniSurfaceFlinger changes
- No Android HAL/Binder knowledge required
- Works with any software encoder

**Cons:**
- `glReadPixels` is slow (stalls the GPU pipeline)
- Pipe-based delivery has framing issues (same `filesrc`+FIFO problem from the earlier `droidvenc` testing)
- `appsrc` with explicit frame-based signaling is better but requires a feeder process

---

## 6. The Encoding Problem Remains

Regardless of how the screen content is captured, **gst-droid's `droidvenc` hardware encoder is unavailable** on the target device because `libmediandk.so` is not present. Captured screen frames must be encoded via software codecs:

| Encoder | GStreamer element | Available? | Notes |
|---|---|---|---|
| x264 | `x264enc` | package `gstreamer1.0-plugins-ugly` | CPU-based, good quality |
| OpenH264 | `openh264enc` | package `gstreamer1.0-plugins-bad` | CPU-based, BSD-licensed |
| VA-API | `vaapih264enc` | requires VA drivers | GPU-assisted, if supported |
| droidvenc | `droidvenc` | ❌ | Needs `libmediandk.so` |

---

## 7. Recommendations

| Priority | Task | Why |
|---|---|---|
| 1 | Prototype `glReadPixels` capture in HWC plugin → `appsrc` → software encoder | Fastest path to working end-to-end screen streaming; no HAL or gst-droid changes |
| 2 | Implement `captureScreen` in MiniSurfaceFlinger | Enables screenshot use cases and is the prerequisite for Android API compatibility |
| 3 | If continuous streaming is needed, evolve `captureScreen` into `createDisplay`-backed virtual display capture | Proper frame pacing, no missed/duplicate frames |
| 4 | If hardware encoding becomes important, source `libmediandk.so` from the device's Android HAL layer and retest `droidvenc` | Offload encoding from CPU |

---

## 8. Key Files Referenced

| File | Role |
|---|---|
| `gst-droid/droidmedia/services/services_*_0_0.h` | MiniSurfaceFlinger stub implementations per Android version |
| `gst-droid/droidmedia/libminisf.cpp` | `startMiniSurfaceFlinger()` — launches the stub in-process |
| `gst-droid/qt5-qpa-hwcomposer-plugin/hwcomposer/hwcomposer_backend.cpp` | `initLegacyHwComposerQuirks()` — calls `startMiniSurfaceFlinger` from the HWC plugin |
| `gst-droid/qt5-qpa-hwcomposer-plugin/hwcomposer/hwcomposer_backend_v20.cpp` | HWC v2.0 backend — `HWC2Window::present()`, the actual screen rendering path |
| `gst-droid/droidmedia/private.cpp` | `_DroidMediaBufferQueue` — BufferQueue consumer pattern used by `droidcamsrc` |
| `gst-droid/droidmedia/droidmediabuffer.cpp` | `_DroidMediaBuffer` — wraps `android::GraphicBuffer` for GStreamer |
| `gst-droid/ConsumerBase.cpp`, `GLConsumer.cpp` | AOSP SurfaceTexture consumer pattern (referenced but not compiled into gst-droid) |
| `gst-droid/gst/droidcamsrc/gstdroidcamsrcdev.c` | Reference implementation: camera `GraphicBuffer` → GStreamer pipeline |
| `gst-droid/gst/droidcodec/gstdroidvenc.c` | Hardware video encoder element (non-functional without `libmediandk.so`) |