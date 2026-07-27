# HWC Display → H.264 Hardware Encoder: Implementation Plan

**Date:** 2026-07-07
**Context:** Enabling hardware-accelerated H.264 encoding of screen content on SailfishOS/hybris. The screen is rendered by the `qt5-qpa-hwcomposer-plugin` into gralloc-allocated `GraphicBuffer` objects. These must be fed — with proper fence synchronization and without CPU copies — into the existing Android `MediaCodec`-backed `droidvenc` GStreamer encoder.

**Constraint:** `droidvenc` requires `memory:DroidVideoMetaData` caps (i.e., `DroidMediaBuffer`-wrapped `GraphicBuffer` handles). It does NOT accept arbitrary CPU-mapped raw data. Buffers must be gralloc-allocated and fenced. Software encoding is out of scope.

---

## 1. Architecture Recap — How Everything Connects

### 1.1 Display Pipeline (Today)

```
Qt App → EGL render → GraphicBuffer (RGBA_8888) → HWC HAL → Display HW
```

The `qt5-qpa-hwcomposer-plugin` (`hwcomposer_backend_v20.cpp`, `HWC2Window::present()` at L162–250) renders EGL directly into triple-buffered `GraphicBuffer` slots. There is **no Android SurfaceFlinger** — Qt's EGLFS integration bypasses it entirely. The composed buffer is handed to the HWC HAL via `hwc2_compat_display_set_client_target()` + `hwc2_compat_display_present()`.

### 1.2 MiniSurfaceFlinger (Today)

`MiniSurfaceFlinger` is a stub Binder service (`services_14_0_0.h` L196–381) registered as `"SurfaceFlingerAIDL"` on A14. It runs **in the same process** as the HWC plugin, launched via `libminisf.so` → `startMiniSurfaceFlinger()` from `initLegacyHwComposerQuirks()` in `hwcomposer_backend.cpp` L73–104. Every meaningful method returns `BAD_VALUE` or `NULL`. Its sole purpose is to prevent Android media services from crashing.

### 1.3 Hardware Encoder Path (Today)

```
gstdroidvenc.c
  └── gst_droidvenc_create_codec() [L120–196]
        └── droid_media_codec_create_encoder(&md)
              └── DroidMediaCodecBuilder::createCodec() [droidmediacodec.cpp L380–530]
                    └── AsyncCodecSource::Create(src, format, isEncoder, flags, window, looper)
                          └── android::MediaCodec (OMX IL / Codec2 HAL)
                                └── Vendor HW encoder (QC Venus, MTK, etc.)
```

#### Two Distinct Encoder Input Paths

**Path A — Raw CPU Data (`gstdroidvenc_handle_frame`):**

```
gstdroidvenc_handle_frame() [L550–639]
  → gst_buffer_map(buffer, &info, GST_MAP_READ)       // CPU maps GstBuffer
  → droid_media_codec_queue(codec, &data, &cb)         // raw pointer + size
    → new InputBuffer(raw_data, size, ...)              // wraps in MediaBuffer
      → m_src->add(buffer)                              // feeds encoder Source
        → encoder internally copies to gralloc buffers
```

Works but involves CPU map → copy overhead. The encoder internally allocates its own gralloc buffers and copies.

**Path B — Gralloc Metadata / Zero-Copy (`DroidMediaRecorder`):**

```
DroidMediaRecorder [droidmediarecorder.cpp]
  → CameraSource::CreateFromCamera()       // produces MediaBuffers with embedded
                                           // GraphicBuffer metadata
  → droid_media_codec_create_encoder_raw(meta, looper, src) [L145–189]
    → AsyncCodecSource::Create(src, format, ...)
      // src.read() → MediaBuffer with valid .graphicBuffer()
      // Encoder reads directly from shared gralloc memory
```

This is the zero-copy path: `CameraSource` produces buffers whose underlying memory is a gralloc `GraphicBuffer`. The encoder accesses the same gralloc memory directly. **This is what we must replicate for screen capture.**

### 1.4 `DroidMediaBuffer` and the Caps Feature

The GStreamer-side memory abstraction:

```
GstMemory (memory:DroidMediaBuffer, memory:DroidVideoMetaData)
  └── DroidMediaBuffer  [droidmediabuffer.cpp]
        └── android::GraphicBuffer (gralloc-allocated)
              └── native_handle_t → shared across processes
```

The format map in `gstdroidmediabuffer.c` (L94–185) maps HAL pixel formats to GStreamer formats. Notably:

| Index | HAL Format | Gst Format | Bytes/Pixel |
|---|---|---|---|
| 0 | `HAL_PIXEL_FORMAT_RGBA_8888` | `RGBA` | 4 |
| 5 | `HAL_PIXEL_FORMAT_YV12` | `YV12` | 1 |
| 7 | `HAL_PIXEL_FORMAT_YCrCb_420_SP` | `NV21` | 1 |
| 9 | `QOMX_COLOR_FormatYUV420PackedSemiPlanar32m` | `YV12` | 1 |
| 10 | `QOMX_COLOR_FormatYUV420PackedSemiPlanar64x32Tile2m8ka` | `NV12_64Z32` | 0 |

There is **no NV12** in the format map (index 7 is NV21). The encoder most likely accepts `QOMX_COLOR_FormatYUV420PackedSemiPlanar32m` (Qualcomm's tiled NV12 variant) as input. We'll need to handle format negotiation at runtime.

### 1.5 `DroidMediaBufferQueue` — The Cross-Process Transport

`_DroidMediaBufferQueue` (`private.cpp` L65–99) wraps Android's `BufferQueue`:

```
Producer side (IGraphicBufferProducer):
  dequeueBuffer() → get gralloc buffer → fill → queueBuffer(fence)

Consumer side (IGraphicBufferConsumer):
  acquireBuffer(&item) → get GraphicBuffer item
  → DroidMediaBuffer wraps GraphicBuffer
  → frame_available callback
  → releaseBuffer(slot, fence) when done
```

Critically, `BufferQueue` operates on **gralloc-allocated `GraphicBuffer` objects** — the memory is shared cross-process via the `native_handle_t`. This is the mechanism we use to transport screen frames from the HWC plugin process to the GStreamer process.

### 1.6 Key Files

| File | Role |
|---|---|
| `qt5-qpa-hwcomposer-plugin/hwcomposer/hwcomposer_backend_v20.cpp` | HWC v2.0 render path; `HWC2Window::present()` at L162–250 |
| `qt5-qpa-hwcomposer-plugin/hwcomposer/hwcomposer_backend.cpp` | `initLegacyHwComposerQuirks()` at L73–104 |
| `droidmedia/services/services_14_0_0.h` | `MiniSurfaceFlinger` stub at L196–381 |
| `droidmedia/droidmediacodec.cpp` | Encoder creation at L380–530, `droid_media_codec_queue()` at L933–966, `droid_media_codec_loop()` at L968–1128 |
| `droidmedia/droidmediacodec.h` | `DroidMediaCodecEncoderMetaData` at L77–90 |
| `droidmedia/droidmediarecorder.cpp` | Reference: `CameraSource` → encoder zero-copy path |
| `droidmedia/droidmediabuffer.cpp` | `_DroidMediaBuffer` wrapping `android::GraphicBuffer` |
| `droidmedia/private.cpp` | `_DroidMediaBufferQueue` — BufferQueue consumer wrapping |
| `droidmedia/private.h` | `_DroidMediaBufferQueue` struct with producer/consumer |
| `gst-droid/gst/droidcodec/gstdroidvenc.c` | GStreamer `droidvenc` element; sink pad requires `memory:DroidVideoMetaData` |
| `gst-droid/gst/droidcamsrc/gstdroidcamsrcdev.c` | Reference: camera → GStreamer via `DroidMediaBufferQueue` callbacks |
| `gst-droid/gst-libs/gst/droid/gstdroidmediabuffer.c` | HAL ↔ GStreamer format map, allocator, memory wrapping |
| `gst-droid/gst-libs/gst/droid/gstdroidbufferpool.c` | Buffer pool that binds `DroidMediaBuffer` to `GstBuffer` |
| `gst-droid/gst/plugin.c` | Element registration at L53–115 |

---

## 2. The Core Challenge

Screen buffer: **RGBA_8888** `GraphicBuffer` in the Qt compositor process.  
Encoder input: **NV12/SemiPlanar** `GraphicBuffer` (gralloc) delivered as `DroidMediaBuffer` in GStreamer process.

Four sub-problems, all requiring zero CPU-bottlenecked copies:

1. **Capture** the composed screen `GraphicBuffer` — available after `eglSwapBuffers()` in the HWC plugin (same process as MiniSurfaceFlinger)
2. **Convert** RGBA_8888 → NV12 via **GPU blit** (using EGL/GLES in the HWC plugin's existing GL context)
3. **Transport** the NV12 `GraphicBuffer` cross-process → GStreamer via `BufferQueue` (`IGraphicBufferProducer`/`IGraphicBufferConsumer`)
4. **Fence** everything properly so the GPU/encoder don't stomp on in-use memory
5. **Feed** the `DroidMediaBuffer` into `droidvenc` as metadata-backed input

---

## 3. Detailed Design

### 3.1 Overview: The Capture Pipeline

```
[HWC plugin process — Qt compositor]           [GStreamer process — screen recorder]
                                                    │
 HWC2Window::present()                          droidscreencapsrc (GstPushSrc)
   │                                                  │
   ├── eglSwapBuffers(display, surface)          On start:
   │   → screen GraphicBuffer(RGBA) complete          │
   │                                                  ├── Create BufferQueue:
   ├── GL blit: screen RGBA → capture NV12            │     BufferQueue::createBufferQueue(
   │   (using FBO + shader)                           │       &producer, &consumer)
   │   captureBuf = new GraphicBuffer(                 │
   │       w, h, NV12, HW_TEXTURE | HW_VIDEO_ENC)     ├── Pass producer to HWC plugin
   │                                                  │     via MiniSurfaceFlinger Binder IPC
   ├── producer->queueBuffer(captureBuf, fence)       │
   │   fence = eglCreateSyncKHR(EGL_SYNC_FENCE_KHR)   │   On frame:
   │   eglClientWaitSyncKHR(fence)  // flush GPU      │     ├── consumer->acquireBuffer(&item, 0)
   │   → NV12 buffer now in BufferQueue               │     ├── wrap item → DroidMediaBuffer
   │                                                  │     ├── Bind to GstDroidBufferPool
   │   (Consumer in GStreamer process gets callback)   │     ├── Push GstBuffer downstream
   │                                                  │     └── consumer->releaseBuffer(slot, fence)
   ├── hwc2_compat_display_present(hwcDisplay, fence) │
   │   → screen on hardware                        droidvenc
   │                                                  │
                                                      ├── Receives GstBuffer
                                                      │   (memory:DroidVideoMetaData)
                                                      ├── Encodes gralloc NV12 → H.264
                                                      └── Pushes encoded NAL units downstream
```

### 3.2 Component 1: HWC Plugin — Screen Capture & GPU Blit

**File:** `qt5-qpa-hwcomposer-plugin/hwcomposer/hwcomposer_backend_v20.cpp`

In `HWC2Window::present()` (currently L162–250), add capture logic after `eglSwapBuffers()` and before `hwc2_compat_display_present()`:

```cpp
// After eglSwapBuffers, the screen content is in the current EGL surface
// (which is backed by a GraphicBuffer). We now blit it to an NV12 buffer.

if (g_captureEnabled) {
    // 1. Dequeue an NV12 GraphicBuffer from the capture BufferQueue
    int slot;
    sp<Fence> fence;
    sp<GraphicBuffer> captureBuf;
    g_captureProducer->dequeueBuffer(&slot, &fence, width, height,
                                      HAL_PIXEL_FORMAT_YCbCr_420_SP,
                                      GRALLOC_USAGE_HW_TEXTURE |
                                      GRALLOC_USAGE_HW_VIDEO_ENCODER,
                                      &captureBuf);

    // 2. Wait for the buffer to become available
    if (fence->isValid())
        fence->waitForever();

    // 3. GPU blit: RGBA framebuffer → NV12 GraphicBuffer
    //    Use EGLImage to wrap captureBuf as a GL texture/render target
    EGLImageKHR eglImage = eglCreateImageKHR(eglDisplay, EGL_NO_CONTEXT,
        EGL_NATIVE_BUFFER_ANDROID, (EGLClientBuffer)captureBuf->getNativeBuffer(),
        attrs);
    GLuint captureTex;
    glGenTextures(1, &captureTex);
    glBindTexture(GL_TEXTURE_2D, captureTex);
    glEGLImageTargetTexture2DOES(GL_TEXTURE_2D, eglImage);

    // Bind captureTex as FBO color attachment, render fullscreen quad
    // with RGBA→NV12 conversion shader
    glBindFramebuffer(GL_FRAMEBUFFER, g_captureFBO);
    glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0,
                           GL_TEXTURE_2D, captureTex, 0);
    glViewport(0, 0, width, height);
    glUseProgram(g_rgbaToNv12Program);
    glBindTexture(GL_TEXTURE_2D, g_screenTexture); // input: screen content
    glDrawArrays(GL_TRIANGLE_STRIP, 0, 4);

    glFlush();

    // 4. Create EGLSync fence for the GPU blit
    EGLSyncKHR blitFence = eglCreateSyncKHR(eglDisplay,
        EGL_SYNC_FENCE_KHR, NULL);

    // 5. Queue the NV12 buffer to the producer, with the blit fence
    sp<Fence> qFence(new Fence(eglDupNativeFenceFDANDROID(eglDisplay, blitFence)));
    IGraphicBufferProducer::QueueBufferOutput qbo;
    g_captureProducer->queueBuffer(slot,
        IGraphicBufferProducer::QueueBufferInput(
            timestamp, false /* not auto-timestamp */,
            HAL_DATASPACE_UNKNOWN,
            Rect(width, height),
            NATIVE_WINDOW_SCALING_MODE_FREEZE,
            0 /* transform */, qFence),
        &qbo);

    eglDestroySyncKHR(eglDisplay, blitFence);
    glDeleteTextures(1, &captureTex);
    eglDestroyImageKHR(eglDisplay, eglImage);
}
```

#### Color Conversion Shader

The RGBA → NV12 blit requires a GPU shader. NV12 has a full-resolution Y plane and a subsampled interleaved UV plane. This can be done in a single pass to a target texture twice the height (Y plane top half, UV plane bottom half), or in two passes to two separate render targets. The Y plane stride must match whatever the NV12 buffer's native stride is (typically width rounded up to alignment).

A simpler alternative: blit to an RGBA temporary, then use a compute shader or dual-render-target approach. This depends on the GPU's MRT support.

**Shaders needed:** `rgba_to_nv12.vert` (passthrough) + `rgba_to_nv12.frag` (matrix conversion).

#### Initialization

HWC plugin initialization (`HwComposerBackend_v20` constructor or `initLegacyHwComposerQuirks`):
- Create the capture `BufferQueue` (`BufferQueue::createBufferQueue`)
- Compile the RGBA→NV12 shader
- Allocate the FBO
- Store the `IGraphicBufferProducer` handle — this will be retrieved by the GStreamer source

### 3.3 Component 2: MiniSurfaceFlinger — Producer Handoff via Binder

**File:** `droidmedia/services/services_14_0_0.h`

`MiniSurfaceFlinger` already runs in-process with the HWC plugin. We use it as the Binder endpoint through which the GStreamer process obtains the `IGraphicBufferProducer` for screen capture.

Add a new Binder method (or repurpose an existing one):

```cpp
// In MiniSurfaceFlinger:

sp<IGraphicBufferProducer> getScreenCaptureProducer() {
    // g_captureProducer is set by the HWC plugin during init
    extern sp<IGraphicBufferProducer> g_captureProducer;
    return g_captureProducer;
}
```

This requires adding the method declaration to the `ISurfaceComposer` interface. Since `ISurfaceComposer` is an AOSP-generated interface, we need a different approach:

**Alternative — use a custom Binder service or extend MiniSurfaceFlinger's `getDisplayedContentSample`:**

A cleaner approach: **don't modify the ISurfaceComposer interface at all.** Instead, expose the capture producer via a simple mechanism:

1. **Shared file descriptor approach:** The HWC plugin writes the producer's binder fd to a known location. In practice, Binder tokens can be shared via `Parcel::writeStrongBinder()` — but this is complex.

2. **Unix domain socket in HWC process:** A tiny socket server in the HWC plugin process that returns the `IGraphicBufferProducer` binder token on connect. The GStreamer source connects, receives the binder token, and uses it to dequeue as consumer.

3. **`libminisf` export approach:** Add a function to `libminisf.so` like `getScreenCaptureIGBP()` that returns the `sp<IGraphicBufferProducer>`, callable from the GStreamer process via `android_dlsym`.

4. **Recommended — Shared `BufferQueue` via `droidmedia` public API:** Add to `droidmedia.h`:

```c
DroidMediaBufferQueue *droid_media_buffer_queue_create_screen_capture(void);
void droid_media_buffer_queue_destroy_screen_capture(DroidMediaBufferQueue *q);
```

This is instantiated in the HWC plugin (via MiniSurfaceFlinger's process) and accessed by the GStreamer source element via `droidmedia`. Under the hood:

- The HWC plugin creates the `BufferQueue` and stores it as a singleton
- The `droid_media_buffer_queue_create_screen_capture()` function (called from GStreamer process) Binder-IPCs to the MiniSurfaceFlinger to obtain the `IGraphicBufferConsumer` side of the queue
- The HWC plugin writes to the producer side on each frame

**This is the cleanest approach** — it follows the existing `DroidMediaBufferQueue` pattern (which is already used for camera preview/video), adds minimal new API surface, and hides the Binder complexity inside `droidmedia`.

```cpp
// In droidmedia private.h / droidmedia.h:

// Called by HWC plugin (in Qt compositor process):
void droid_media_screen_capture_init(sp<IGraphicBufferProducer> *outProducer);

// Called by GStreamer source (in recorder process):
DroidMediaBufferQueue *droid_media_screen_capture_queue_new(void);
```

The HWC plugin calls `droid_media_screen_capture_init()` which:
1. Creates a `BufferQueue`
2. Registers the producer with MiniSurfaceFlinger (stored as a singleton)
3. Returns the producer to the HWC plugin

The GStreamer source calls `droid_media_screen_capture_queue_new()` which:
1. Binder-calls MiniSurfaceFlinger to get the consumer side
2. Wraps the consumer in a `DroidMediaBufferQueue`
3. Returns it

This is architecturally identical to how camera preview works (`attachToCameraPreview`).

### 3.4 Component 3: GStreamer `droidscreencapsrc` Element

**New file:** `gst-droid/gst/droidscreencapsrc/gstdroidscreencapsrc.c`
**New file:** `gst-droid/gst/droidscreencapsrc/gstdroidscreencapsrc.h`

#### Element Design

- **Base class:** `GstPushSrc` (provides `create()` → push buffer loop)
- **Source pad caps:** `video/x-raw(memory:DroidMediaBuffer), format=NV12, width=..., height=..., framerate=.../1`
  - Note: The caps feature `memory:DroidMediaBuffer` corresponds to `GST_ALLOCATOR_DROID_MEDIA_BUFFER` — this is the mechanism by which `droidvenc` recognizes the buffer as an Android-native gralloc-backed buffer. We use this rather than `memory:DroidVideoMetaData` because we're producing frames, not wrapping encoded metadata.
  - Actually, looking at this more carefully: `droidvenc`'s sink pad template requires `memory:DroidVideoMetaData` (`GST_CAPS_FEATURE_MEMORY_DROID_VIDEO_META_DATA`). This is for the camera's metadata path where the GPU render is happening elsewhere.
  - For screen capture, **we produce `memory:DroidMediaBuffer`** — the format `droidcamsrc` uses for preview frames — and use `droidvenc` or the camera recorder path to encode.  
  - **Correction:** Looking at `droidvenc_handle_frame`, it does `gst_buffer_map(buffer, &info, GST_MAP_READ)` and then passes raw data. But the camera recorder path (`DroidMediaRecorder`) passes `GraphicBuffer` handles to the encoder via `CameraSource`. We need to use the same mechanism.
  - **The right approach for zero-copy encoding:** Create a custom `MediaSource` subclass (like `CameraSource` does) that produces `MediaBuffer` objects with valid `graphicBuffer()` returns. Feed this to `droid_media_codec_create_encoder_raw()`. This is what the `DroidMediaRecorder` does.
  - This means the GStreamer element would **directly use the droidmedia encoder API** rather than piping through `droidvenc`.

**Revised architecture:**

```
droidscreencapsrc (GstPushSrc)
  │
  ├── On start:
  │     ├── droid_media_screen_capture_queue_new()
  │     │     → DroidMediaBufferQueue wrapping BufferQueue consumer
  │     ├── droid_media_buffer_queue_set_callbacks(queue, &cb, self)
  │     │     → frame_available callback triggers push
  │     ├── Create DroidMediaCodecEncoderMetaData
  │     ├── Create custom ScreenCaptureMediaSource (feeds encoder)
  │     ├── droid_media_codec_create_encoder_raw(meta, looper, src)
  │     │     → AsyncCodecSource wrapping the HW encoder
  │     └── Start encoder loop thread
  │
  ├── frame_available callback (on BufferQueue thread):
  │     ├── consumer->acquireBuffer(&item, 0)
  │     ├── Wrap item → DroidMediaBuffer
  │     ├── Lock DroidMediaBuffer (maps gralloc memory)
  │     ├── Create MediaBuffer with graphicBuffer = item.mGraphicBuffer
  │     ├── Push to ScreenCaptureMediaSource queue
  │     ├── Consumer in encoder thread: read() → encode → output callback
  │     └── Push encoded H.264 to GStreamer src pad
  │
  └── output callback:
        └── Create GstBuffer from encoded data → push downstream
```

#### Element Structure

```c
// gstdroidscreencapsrc.h

typedef struct _GstDroidScreenCapSrc {
    GstPushSrc parent;

    DroidMediaBufferQueue *queue;     // BufferQueue consumer for screen frames
    DroidMediaCodec *codec;           // HW encoder (droidmedia)
    DroidMediaCodecEncoderMetaData md;

    GMutex lock;
    GCond cond;
    GQueue *encoded_frames;           // Encoded H.264 output queue

    gint width, height;
    gint fps_n, fps_d;
    gint target_bitrate;
    gint i_frame_interval;
    gboolean running;
} GstDroidScreenCapSrc;
```

#### Source Pad Caps

```c
static GstStaticPadTemplate src_template =
GST_STATIC_PAD_TEMPLATE ("src",
    GST_PAD_SRC,
    GST_PAD_ALWAYS,
    GST_STATIC_CAPS ("video/x-h264, "
        "stream-format = (string) byte-stream, "
        "alignment = (string) au, "
        "profile = (string) { baseline, main, high }"));
```

#### Properties

```c
enum {
    PROP_0,
    PROP_TARGET_BITRATE,
    PROP_I_FRAME_INTERVAL,
    PROP_FPS,
};

// Default: 8 Mbps, I-frame every 30 frames, 30 fps
```

#### Core Loop

```
create():
  1. Obtain screen capture BufferQueue via droidmedia API
  2. Query HWC for display resolution
  3. Create encoder:
     md.parent.type = "video/avc"
     md.parent.width = display_width
     md.parent.height = display_height
     md.parent.fps = fps
     md.parent.flags = DROID_MEDIA_CODEC_HW_ONLY
     md.color_format = query from encoder supported formats
     md.bitrate = target_bitrate
     md.stride = display_width
     md.slice_height = display_height
     md.meta_data = true  // Use GraphicBuffer metadata path!
     codec = droid_media_codec_create_encoder_raw(&md, looper, screenCaptureSrc)
  4. Start encoder
  5. Start consumer thread (acquireBuffer → feed encoder)

consumer thread:
  while (running):
    item = consumer->acquireBuffer()
    Create MediaBuffer wrapping item.mGraphicBuffer
    Feed to encoder's MediaSource

encoder output callback:
  Receive encoded DroidMediaCodecData
  Create GstBuffer, set PTS/DTS, flags
  Push to GStreamer src pad
```

#### The `ScreenCaptureMediaSource` Class

This is the critical piece — it's an Android `MediaSource` subclass that the encoder pulls frames from:

```cpp
class ScreenCaptureMediaSource : public MediaSource {
public:
    ScreenCaptureMediaSource(sp<IGraphicBufferConsumer> consumer, int width, int height)
        : mConsumer(consumer), mWidth(width), mHeight(height) {}

    status_t start(MetaData*) override { mStarted = true; return OK; }
    status_t stop() override { mStarted = false; return OK; }
    sp<MetaData> getFormat() override {
        sp<MetaData> md = new MetaData;
        md->setCString(kKeyMIMEType, MEDIA_MIMETYPE_VIDEO_RAW);
        md->setInt32(kKeyWidth, mWidth);
        md->setInt32(kKeyHeight, mHeight);
        md->setInt32(kKeyColorFormat, OMX_COLOR_FormatYUV420SemiPlanar);
        return md;
    }

    status_t read(MediaBufferBase **buffer) override {
        // Block until a new screen frame is available from the BufferQueue
        BufferItem item;
        mConsumer->acquireBuffer(&item, 0);

        // Create MediaBuffer backed by the GraphicBuffer
        MediaBuffer *mbuf = new MediaBuffer(item.mGraphicBuffer);
        mbuf->add_ref();
        *buffer = mbuf;

        // Store slot for later release
        mPendingSlot = item.mSlot;
        return OK;
    }

private:
    sp<IGraphicBufferConsumer> mConsumer;
    int mWidth, mHeight;
    bool mStarted = false;
    int mPendingSlot = -1;
};
```

This follows the same pattern as `CameraSource` — the encoder calls `read()` to get a `MediaBuffer` whose underlying data is a gralloc `GraphicBuffer`. The encoder accesses the YUV data directly through gralloc, zero-copy.

### 3.5 Implementation Steps — Detailed Breakdown

#### Step 1: `droidmedia` API Additions

**File:** `droidmedia/droidmedia.h` — add:

```c
// Screen capture BufferQueue:
// Call from HWC plugin process to initialize capture:
void droid_media_screen_capture_register_producer(
    android::sp<android::IGraphicBufferProducer> producer);

// Call from GStreamer process to get the consumer:
DroidMediaBufferQueue *droid_media_screen_capture_queue_new(void);
```

**File:** `droidmedia/screen_capture.cpp` (new) — implement:

```cpp
// Singleton producer, protected by mutex, registered by HWC plugin
static sp<IGraphicBufferProducer> g_screenCapProducer;
static Mutex g_screenCapLock;

void droid_media_screen_capture_register_producer(sp<IGraphicBufferProducer> producer) {
    Mutex::Autolock l(g_screenCapLock);
    g_screenCapProducer = producer;
}

DroidMediaBufferQueue *droid_media_screen_capture_queue_new(void) {
    // Create a new BufferQueue
    sp<IGraphicBufferProducer> producer;
    sp<IGraphicBufferConsumer> consumer;
    BufferQueue::createBufferQueue(&producer, &consumer);

    // Register this producer so HWC plugin can write to it
    droid_media_screen_capture_register_producer(producer);

    // Return consumer wrapped in DroidMediaBufferQueue
    DroidMediaBufferQueue *q = new DroidMediaBufferQueue("ScreenCapture");
    q->setConsumer(consumer);  // needs new method or constructor overload
    return q;
}
```

Wait — this is the wrong direction. The HWC plugin needs the producer, and the GStreamer side needs the consumer. The `BufferQueue::createBufferQueue` creates a linked pair. We need cross-process sharing.

**Corrected approach:**

The `IGraphicBufferProducer` and `IGraphicBufferConsumer` are Binder interfaces — they can be shared across processes. The `BufferQueue` itself lives in the process that creates it.

**Option A: Create in HWC plugin process, share consumer to GStreamer**

```cpp
// In HWC plugin (same process as MiniSurfaceFlinger):
// Create the BufferQueue
sp<IGraphicBufferProducer> mProducer;
sp<IGraphicBufferConsumer> mConsumer;
BufferQueue::createBufferQueue(&mProducer, &mConsumer);

// Store consumer in MiniSurfaceFlinger singleton
MiniSurfaceFlinger::setScreenCaptureConsumer(mConsumer);

// GStreamer calls via Binder:
// sp<IGraphicBufferConsumer> consumer = MiniSurfaceFlinger::getScreenCaptureConsumer();
// Then wrap consumer in a DroidMediaBufferQueue-style object
```

This is the right direction — the BufferQueue lives in the HWC process, the GStreamer process gets the consumer via Binder.

**Option B: Create in GStreamer process, share producer to HWC plugin**

```cpp
// In GStreamer process:
sp<IGraphicBufferProducer> producer;
sp<IGraphicBufferConsumer> consumer;
BufferQueue::createBufferQueue(&producer, &consumer);

// Send producer to MiniSurfaceFlinger via Binder
// MiniSurfaceFlinger::registerScreenCaptureProducer(producer);

// HWC plugin gets the producer from MiniSurfaceFlinger (same process, direct call)
```

This is simpler — the BufferQueue lives in the GStreamer process, the HWC plugin queues buffers to it via Binder. Since the HWC plugin is in the same process as MiniSurfaceFlinger, MiniSurfaceFlinger can hold a reference to the producer and the HWC plugin can access it directly.

**I'll go with Option B** — it's simpler because:
1. The GStreamer process owns the BufferQueue lifecycle
2. The HWC plugin only queues buffers (fire-and-forget per frame)
3. No need for Binder calls on every frame on the GStreamer side

#### Step 2: HWC Plugin Modifications

**File:** `qt5-qpa-hwcomposer-plugin/hwcomposer/hwcomposer_backend_v20.cpp`

1. Add `#include <gui/BufferQueue.h>` and `#include <gui/IGraphicBufferProducer.h>`

2. In `HwComposerBackend_v20` class, add member:
   ```cpp
   android::sp<android::IGraphicBufferProducer> m_captureProducer;
   bool m_captureEnabled;
   ```

3. In constructor or `initLegacyHwComposerQuirks()`, compile shaders:
   ```cpp
   // RGBA → NV12 conversion shader
   static const char *rgba_to_nv12_frag = R"(
       // ... converts single RGBA texel to Y + subsampled UV
   )";
   m_rgbaToNv12Program = createProgram(vertShader, rgba_to_nv12_frag);
   ```

4. In `present()`, after `eglSwapBuffers()` (or after the EGL rendering is done, before `hwc_present`), add the capture blit:

   ```cpp
   if (m_captureEnabled && m_captureProducer != nullptr) {
       int slot;
       sp<Fence> fence;
       sp<GraphicBuffer> nv12Buf;
       status_t err = m_captureProducer->dequeueBuffer(
           &slot, &fence, m_width, m_height,
           HAL_PIXEL_FORMAT_YCbCr_420_SP,  // NV12
           GRALLOC_USAGE_HW_TEXTURE | GRALLOC_USAGE_HW_VIDEO_ENCODER,
           &nv12Buf);

       if (err == NO_ERROR) {
           if (fence->isValid()) fence->waitForever();

           // GPU blit RGBA framebuffer → NV12 GraphicBuffer
           blitRgbaToNv12(m_screenTexture, nv12Buf, m_width, m_height);

           // Create fence for the GPU blit
           EGLSyncKHR sync = eglCreateSyncKHR(eglGetCurrentDisplay(),
               EGL_SYNC_FENCE_KHR, NULL);
           eglClientWaitSyncKHR(eglGetCurrentDisplay(), sync,
               EGL_SYNC_FLUSH_COMMANDS_BIT_KHR, EGL_FOREVER_KHR);

           sp<Fence> qFence(new Fence(eglDupNativeFenceFDANDROID(
               eglGetCurrentDisplay(), sync)));
           eglDestroySyncKHR(eglGetCurrentDisplay(), sync);

           IGraphicBufferProducer::QueueBufferOutput qbo;
           IGraphicBufferProducer::QueueBufferInput qbi(
               timestamp, false,
               HAL_DATASPACE_UNKNOWN,
               Rect(m_width, m_height),
               NATIVE_WINDOW_SCALING_MODE_FREEZE,
               0, qFence);
           m_captureProducer->queueBuffer(slot, qbi, &qbo);
       }
   }
   ```

5. Expose a method to set the capture producer (called by MiniSurfaceFlinger when GStreamer registers):

   ```cpp
   void setCaptureProducer(const sp<IGraphicBufferProducer>& producer) {
       m_captureProducer = producer;
       m_captureEnabled = (producer != nullptr);
   }
   ```

#### Step 3: MiniSurfaceFlinger Modifications

**File:** `droidmedia/services/services_14_0_0.h`

Add to `MiniSurfaceFlinger`:

```cpp
// Store capture producer received from GStreamer process via Binder
sp<IGraphicBufferProducer> m_screenCaptureProducer;

// New method accessible from HWC plugin (same process):
void setCaptureProducer(const sp<IGraphicBufferProducer>& producer) {
    m_screenCaptureProducer = producer;
    // Notify HWC backend (if we have a reference to it, or use a callback)
    // Since MiniSurfaceFlinger is a singleton, the HWC plugin can poll/get it.
}
```

The GStreamer process needs to call this via Binder. We can repurpose the `getProtectedContentSupport` or add a simple custom Binder transaction.

**Actually, a cleaner approach:** Since `MiniSurfaceFlinger` is a `BinderService` singleton, and the HWC plugin has access to it (same process), we can just add a **static method**:

```cpp
class MiniSurfaceFlinger : public BinderService<MiniSurfaceFlinger>, ... {
public:
    // Static accessor — can be called from HWC plugin (same process)
    // or via Binder from GStreamer process
    static void registerCaptureProducer(const sp<IGraphicBufferProducer>& producer);
    static sp<IGraphicBufferProducer> getCaptureProducer();

private:
    static sp<IGraphicBufferProducer> s_captureProducer;
    static Mutex s_captureLock;
};
```

For cross-process access, the GStreamer process can obtain the `ISurfaceComposer` Binder service and call a method. We'll add a custom Binder transaction or reuse `getDisplayedContentSample`.

**Simplest cross-process method:** Use `droidmedia` public API directly — the HWC plugin loads `libdroidmedia.so`, the GStreamer process also loads it. We define a C function in `droidmedia` that the HWC plugin calls locally and the GStreamer process calls through hybris:

```c
// droidmedia.h — new functions:

// Called from HWC plugin (same process as MiniSurfaceFlinger):
// Stores the producer so MiniSurfaceFlinger can return it via Binder.
void droid_media_screen_capture_set_producer(android::sp<android::IGraphicBufferProducer> *outProducer);

// Called from GStreamer process:
// Creates a BufferQueue, registers the producer with MiniSurfaceFlinger,
// and returns the consumer side as a DroidMediaBufferQueue.
DroidMediaBufferQueue *droid_media_screen_capture_create(int width, int height, int format);
```

The implementation in `droidmedia`:

```cpp
// screen_capture.cpp (new file in droidmedia/)

// In-process (HWC plugin calls this):
void droid_media_screen_capture_init(sp<IGraphicBufferProducer> *outProducer) {
    // Create the BufferQueue pair
    sp<IGraphicBufferProducer> producer;
    sp<IGraphicBufferConsumer> consumer;
    BufferQueue::createBufferQueue(&producer, &consumer);
    consumer->setConsumerName(String8("ScreenCapture"));
    consumer->setDefaultBufferSize(displayWidth, displayHeight);
    consumer->setDefaultBufferFormat(HAL_PIXEL_FORMAT_YCbCr_420_SP);
    consumer->setConsumerUsageBits(
        GRALLOC_USAGE_HW_TEXTURE | GRALLOC_USAGE_HW_VIDEO_ENCODER);

    // Store consumer with MiniSurfaceFlinger (in-process, direct call)
    MiniSurfaceFlinger::setScreenCaptureConsumer(consumer);

    *outProducer = producer;
}

// Cross-process (GStreamer calls this):
DroidMediaBufferQueue *droid_media_screen_capture_create(void) {
    // Get ISurfaceComposer service
    sp<ISurfaceComposer> sf = ComposerService::getComposerService();

    // Call MiniSurfaceFlinger to get the consumer
    sp<IGraphicBufferConsumer> consumer = sf->getScreenCaptureConsumer();
    // ^^ This needs a new Binder method on ISurfaceComposer

    if (consumer == NULL) return NULL;

    // Wrap in DroidMediaBufferQueue-style consumer
    DroidMediaBufferQueue *q = new DroidMediaBufferQueue(consumer);
    q->connectListener();
    return q;
}
```

The challenge: `ISurfaceComposer` is an AOSP-generated interface. We need to either:
1. Add a virtual method (changes Binder ABI, dangerous)
2. Use a **separate Binder service** specifically for screen capture
3. Pass the fd of the consumer via a simpler IPC mechanism

**Recommendation — separate Binder service `ScreenCaptureService`:**

Add a small custom Binder service registered alongside MiniSurfaceFlinger:

```cpp
// In droidmedia/services/ (or a new file):

class ScreenCaptureService : public BinderService<ScreenCaptureService>,
                             public BnScreenCapture {
public:
    static char const *getServiceName() { return "sailfish.screencap"; }

    // Called from HWC plugin process:
    static void setConsumer(const sp<IGraphicBufferConsumer>& consumer);

    // Called from GStreamer process via Binder:
    sp<IGraphicBufferConsumer> getConsumer();
};
```

This avoids modifying the `ISurfaceComposer` interface entirely. The service is registered in `libminisf.cpp` alongside `MiniSurfaceFlinger::instantiate()`.

#### Step 4: GStreamer Element Implementation

**New directory:** `gst-droid/gst/droidscreencapsrc/`

**Files:**
- `gstdroidscreencapsrc.h` — element struct definition
- `gstdroidscreencapsrc.c` — element implementation
- `meson.build` — build rules

**Header (`gstdroidscreencapsrc.h`):**

```c
#ifndef __GST_DROID_SCREENCAPSRC_H__
#define __GST_DROID_SCREENCAPSRC_H__

#include <gst/gst.h>
#include <gst/base/gstpushsrc.h>
#include <droidmedia/droidmedia.h>

G_BEGIN_DECLS

#define GST_TYPE_DROIDSCREENCAPSRC (gst_droidscreencapsrc_get_type())
#define GST_DROIDSCREENCAPSRC(obj) (G_TYPE_CHECK_INSTANCE_CAST((obj), GST_TYPE_DROIDSCREENCAPSRC, GstDroidScreenCapSrc))
#define GST_DROIDSCREENCAPSRC_CLASS(klass) (G_TYPE_CHECK_CLASS_CAST((klass), GST_TYPE_DROIDSCREENCAPSRC, GstDroidScreenCapSrcClass))
#define GST_IS_DROIDSCREENCAPSRC(obj) (G_TYPE_CHECK_INSTANCE_TYPE((obj), GST_TYPE_DROIDSCREENCAPSRC))
#define GST_IS_DROIDSCREENCAPSRC_CLASS(klass) (G_TYPE_CHECK_CLASS_TYPE((klass), GST_TYPE_DROIDSCREENCAPSRC))

typedef struct _GstDroidScreenCapSrc GstDroidScreenCapSrc;
typedef struct _GstDroidScreenCapSrcClass GstDroidScreenCapSrcClass;

struct _GstDroidScreenCapSrc {
    GstPushSrc parent;

    /* Capture */
    DroidMediaBufferQueue *queue;
    DroidMediaCodec *encoder;

    /* Encoder config */
    DroidMediaCodecEncoderMetaData md;
    GstDroidCodec *codec_type;

    /* Output */
    GMutex output_lock;
    GCond output_cond;
    GQueue *output_queue;   // DroidMediaCodecData*
    gboolean eos;
    GstFlowReturn downstream_flow_ret;

    /* Properties */
    gint target_bitrate;
    gint i_frame_interval;
    gint fps_n, fps_d;
    gint width, height;
};

struct _GstDroidScreenCapSrcClass {
    GstPushSrcClass parent_class;
};

GType gst_droidscreencapsrc_get_type(void);

G_END_DECLS
#endif
```

**Implementation (`gstdroidscreencapsrc.c`) — key sections:**

```c
/* Sink caps: we don't have a sink pad (it's a source element).
   Source caps: video/x-h264 */
static GstStaticPadTemplate src_template =
GST_STATIC_PAD_TEMPLATE ("src",
    GST_PAD_SRC,
    GST_PAD_ALWAYS,
    GST_STATIC_CAPS ("video/x-h264, "
        "stream-format = (string) byte-stream, "
        "alignment = (string) au, "
        "profile = (string) { baseline, main, high }"));

/* Encoder output callback */
static void
gst_droidscreencapsrc_data_available (void *data, DroidMediaCodecData *encoded)
{
    GstDroidScreenCapSrc *src = GST_DROIDSCREENCAPSRC (data);

    g_mutex_lock (&src->output_lock);
    /* Copy the data (or reference-count it) */
    DroidMediaCodecData *copy = g_new (DroidMediaCodecData, 1);
    *copy = *encoded;
    copy->data.data = g_memdup2 (encoded->data.data, encoded->data.size);
    g_queue_push_tail (src->output_queue, copy);
    g_cond_signal (&src->output_cond);
    g_mutex_unlock (&src->output_lock);
}

/* GstPushSrc create() — called repeatedly by GStreamer to get buffers */
static GstFlowReturn
gst_droidscreencapsrc_create (GstPushSrc *psrc, GstBuffer **outbuf)
{
    GstDroidScreenCapSrc *src = GST_DROIDSCREENCAPSRC (psrc);
    DroidMediaCodecData *encoded;

    g_mutex_lock (&src->output_lock);
    while (g_queue_is_empty (src->output_queue) && !src->eos) {
        g_cond_wait (&src->output_cond, &src->output_lock);
    }

    if (src->eos && g_queue_is_empty (src->output_queue)) {
        g_mutex_unlock (&src->output_lock);
        return GST_FLOW_EOS;
    }

    encoded = (DroidMediaCodecData *) g_queue_pop_head (src->output_queue);
    g_mutex_unlock (&src->output_lock);

    /* Create GstBuffer from encoded data */
    GstBuffer *buf = gst_buffer_new_allocate (NULL, encoded->data.size, NULL);
    GstMapInfo info;
    gst_buffer_map (buf, &info, GST_MAP_WRITE);
    memcpy (info.data, encoded->data.data, encoded->data.size);
    gst_buffer_unmap (buf, &info);

    GST_BUFFER_PTS (buf) = encoded->ts;
    GST_BUFFER_DTS (buf) = encoded->decoding_ts;
    if (!encoded->sync)
        GST_BUFFER_FLAG_SET (buf, GST_BUFFER_FLAG_DELTA_UNIT);

    g_free (encoded->data.data);
    g_free (encoded);

    *outbuf = buf;
    return GST_FLOW_OK;
}

/* Start: set up BufferQueue consumer + encoder */
static gboolean
gst_droidscreencapsrc_start (GstBaseSrc *bsrc)
{
    GstDroidScreenCapSrc *src = GST_DROIDSCREENCAPSRC (bsrc);

    /* 1. Create screen capture consumer via droidmedia API */
    src->queue = droid_media_screen_capture_create();
    if (!src->queue) {
        GST_ELEMENT_ERROR (src, RESOURCE, OPEN_READ,
            ("Failed to create screen capture consumer"),
            ("MiniSurfaceFlinger may not have a producer registered"));
        return FALSE;
    }

    /* 2. Set up BufferQueue callbacks */
    DroidMediaBufferQueueCallbacks cb;
    memset (&cb, 0, sizeof (cb));
    cb.frame_available = gst_droidscreencapsrc_frame_available;
    droid_media_buffer_queue_set_callbacks (src->queue, &cb, src);

    /* 3. Create encoder */
    memset (&src->md, 0, sizeof (src->md));
    src->md.parent.type = gst_droid_codec_get_droid_type (src->codec_type);
    src->md.parent.width = src->width;
    src->md.parent.height = src->height;
    src->md.parent.fps = src->fps_n / src->fps_d;
    src->md.parent.flags = DROID_MEDIA_CODEC_HW_ONLY;
    src->md.color_format = OMX_COLOR_FormatYUV420SemiPlanar; // NV12
    src->md.bitrate = src->target_bitrate;
    src->md.stride = src->width;
    src->md.slice_height = src->height;
    src->md.meta_data = true;  // This is critical — use GraphicBuffer metadata path!

    src->encoder = droid_media_codec_create_encoder (&src->md);
    if (!src->encoder) {
        GST_ELEMENT_ERROR (src, LIBRARY, SETTINGS,
            ("Failed to create hardware encoder"),
            ("Check OMX/Codec2 HAL registration"));
        return FALSE;
    }

    /* 4. Set callbacks */
    DroidMediaCodecCallbacks codec_cb;
    memset (&codec_cb, 0, sizeof (codec_cb));
    codec_cb.signal_eos = gst_droidscreencapsrc_signal_eos;
    codec_cb.error = gst_droidscreencapsrc_error;
    droid_media_codec_set_callbacks (src->encoder, &codec_cb, src);

    DroidMediaCodecDataCallbacks data_cb;
    memset (&data_cb, 0, sizeof (data_cb));
    data_cb.data_available = gst_droidscreencapsrc_data_available;
    droid_media_codec_set_data_callbacks (src->encoder, &data_cb, src);

    /* 5. Start encoder */
    if (!droid_media_codec_start (src->encoder)) {
        GST_ELEMENT_ERROR (src, LIBRARY, INIT,
            ("Failed to start encoder"), (NULL));
        return FALSE;
    }

    /* 6. Start the consumer thread */
    src->running = TRUE;
    /* ... thread creation ... */

    return TRUE;
}

/* Frame available callback from BufferQueue */
static bool
gst_droidscreencapsrc_frame_available (void *user, DroidMediaBuffer *buffer)
{
    GstDroidScreenCapSrc *src = GST_DROIDSCREENCAPSRC (user);
    DroidMediaBufferInfo info;

    droid_media_buffer_get_info (buffer, &info);

    /* Map the GraphicBuffer to get the raw NV12 data pointer */
    void *data = droid_media_buffer_lock (buffer, DROID_MEDIA_BUFFER_LOCK_READ);
    if (!data) return false;

    /* Queue this frame to the encoder */
    DroidMediaCodecData codec_data;
    codec_data.data.data = (uint8_t *) data;
    codec_data.data.size = info.stride * info.height * 3 / 2; // NV12 size
    codec_data.ts = g_get_monotonic_time () / 1000; // microsec
    codec_data.sync = (src->frame_count++ % src->i_frame_interval == 0);

    DroidMediaBufferCallbacks buf_cb;
    memset (&buf_cb, 0, sizeof (buf_cb));
    buf_cb.unref = gst_droidscreencapsrc_release_frame;
    buf_cb.data = buffer;

    droid_media_codec_queue (src->encoder, &codec_data, &buf_cb);

    return true;
}
```

#### Step 5: Build Integration

**New file:** `gst-droid/gst/droidscreencapsrc/meson.build`

```meson
droidscreencapsrc_sources = [
    'gstdroidscreencapsrc.c',
]

droidscreencapsrc_headers = [
    'gstdroidscreencapsrc.h',
]

gstdroidscreencapsrc = library('gstdroidscreencapsrc',
    droidscreencapsrc_sources,
    droidscreencapsrc_headers,
    dependencies: [gst_dep, gst_base_dep, gst_video_dep, droidmedia_dep],
    include_directories: include_directories('..'),
    install: true,
    install_dir: plugins_install_dir,
)
```

**Modify:** `gst-droid/gst/plugin.c` — add to `plugin_init()`:

```c
ok &= gst_element_register (plugin, "droidscreencapsrc", GST_RANK_PRIMARY,
    GST_TYPE_DROIDSCREENCAPSRC);
```

#### Step 6: `droidmedia` Build Integration

**New file:** `droidmedia/screen_capture.cpp`

```cpp
#include <gui/BufferQueue.h>
#include "droidmedia.h"
#include "private.h"

// HWC plugin side (same process):
extern "C" void droid_media_screen_capture_init(
    android::sp<android::IGraphicBufferProducer> *outProducer)
{
    android::sp<android::IGraphicBufferProducer> producer;
    android::sp<android::IGraphicBufferConsumer> consumer;
    android::BufferQueue::createBufferQueue(&producer, &consumer);

    consumer->setConsumerName(android::String8("ScreenCapture"));
    consumer->setDefaultBufferFormat(HAL_PIXEL_FORMAT_YCbCr_420_SP);
    consumer->setConsumerUsageBits(
        android::GraphicBuffer::USAGE_HW_TEXTURE |
        android::GraphicBuffer::USAGE_HW_VIDEO_ENCODER);

    // Register consumer with ScreenCaptureService
    ScreenCaptureService::setConsumer(consumer);

    *outProducer = producer;
}

// GStreamer side (other process):
extern "C" DroidMediaBufferQueue *droid_media_screen_capture_create(void)
{
    android::sp<android::IGraphicBufferConsumer> consumer =
        ScreenCaptureService::getConsumer();

    if (consumer == NULL) return NULL;

    // Wrap consumer in DroidMediaBufferQueue (needs new constructor)
    DroidMediaBufferQueue *q = new DroidMediaBufferQueue("ScreenCapSrc");
    q->setConsumer(consumer);
    q->connectListener();
    return q;
}
```

#### Step 7: `ScreenCaptureService` Binder Service

**New file:** `droidmedia/services/screen_capture_service.h` (or inline in `libminisf.cpp`)

```cpp
class ScreenCaptureService : public BinderService<ScreenCaptureService>,
                             public BnScreenCaptureService {
public:
    static char const *getServiceName() { return "sailfish.screencap"; }

    static void setConsumer(const sp<IGraphicBufferConsumer>& consumer) {
        Mutex::Autolock l(sLock);
        sConsumer = consumer;
    }

    static sp<IGraphicBufferConsumer> getConsumer() {
        Mutex::Autolock l(sLock);
        return sConsumer;
    }

    // Binder implementation:
    sp<IGraphicBufferConsumer> getScreenCaptureConsumer() override {
        return getConsumer();
    }

private:
    static sp<IGraphicBufferConsumer> sConsumer;
    static Mutex sLock;
};
```

Register in `libminisf.cpp`:

```cpp
void startMiniSurfaceFlinger()
{
    // ... existing code ...
    MiniSurfaceFlinger::instantiate();
    ScreenCaptureService::instantiate();  // NEW
    // ...
}
```

---

## 4. Pipeline — End-to-End Example

```sh
gst-launch-1.0 droidscreencapsrc target-bitrate=8000000 fps=30 \
    width=1080 height=2340 ! \
    h264parse ! \
    mp4mux name=mux ! \
    filesink location=/tmp/screen_record.mp4 \
  pulsesrc device=source ! \
    audio/x-raw,rate=48000,channels=2 ! \
    voaacenc bitrate=128000 ! \
    mux.
```

Or for network streaming:

```sh
gst-launch-1.0 droidscreencapsrc target-bitrate=4000000 ! \
    h264parse ! \
    rtph264pay config-interval=1 pt=96 ! \
    udpsink host=192.168.1.100 port=5000
```

---

## 5. Summary of Changes

| Component | File(s) | Change | Effort |
|---|---|---|---|
| `droidmedia` API | `droidmedia.h`, new `screen_capture.cpp` | `droid_media_screen_capture_init()`, `droid_media_screen_capture_create()` | ~80 lines |
| `ScreenCaptureService` | new `services/screen_capture_service.h` (or inline) | Binder service to hand off consumer to GStreamer process | ~50 lines |
| `libminisf.cpp` | `droidmedia/libminisf.cpp` | Register `ScreenCaptureService::instantiate()` | ~3 lines |
| `droidmedia` build | `droidmedia/meson.build` | Add `screen_capture.cpp` and service header | ~5 lines |
| HWC plugin | `hwcomposer_backend_v20.cpp` | GPU blit RGBA→NV12, queue to producer | ~120 lines |
| HWC plugin | `hwcomposer_backend.cpp` | Init capture producer, compile shaders | ~60 lines |
| GStreamer element | new `gst/droidscreencapsrc/gstdroidscreencapsrc.{c,h}` | Source element with integrated HW encoder | ~500 lines |
| GStreamer build | `gst/droidcodec/meson.build` (or new), `gst/plugin.c` | Build rules and element registration | ~15 lines |
| `droidmedia` internal | `private.h`, `private.cpp` | Optional: new `DroidMediaBufferQueue` constructor accepting external consumer | ~30 lines |

**Total estimated effort:** ~850 lines across ~12 files.

---

## 6. Risks & Mitigations

| Risk | Impact | Mitigation |
|---|---|---|
| NV12 encoder input not supported by vendor HAL | Encoder creation fails | Query supported formats at runtime via `droid_media_codec_get_supported_color_formats()`; fall back to NV21, YV12, or Qualcomm-tiled format |
| GPU RGBA→NV12 shader artifacts | Color banding, chroma errors | Verify shader with known test pattern; use ITU-R BT.601 coefficients; test both limited and full range |
| `BufferQueue` consumer stalls causing HWC plugin frame drop | UI stutter | Use non-blocking dequeue in HWC plugin; drop frames if queue full |
| Binder ABI compatibility across Android versions | Service registration fails | Use version-gated `#if ANDROID_MAJOR`; test on target Android version |
| EGLSync fence fd invalid in cross-process context | Encoder accesses buffer before GPU blit complete | Test `eglDupNativeFenceFDANDROID` compatibility; fall back to `eglClientWaitSync` (flush GPU in HWC process before queue) |
| `droid_media_codec_create_encoder` with `meta_data=true` fails | Encoder doesn't support metadata mode | Fall back to CPU-upload path (still zero-copy gralloc, but CPU copies to encoder input) |

---

## 7. Phased Implementation Plan

### Phase 1: Encoder Validation (1 day)

- Test `droidvenc` with a simple pipeline on the target device
- Query supported color formats from the encoder
- Confirm the vendor OMX/Codec2 component is registered

### Phase 2: `droidmedia` API + `ScreenCaptureService` (1–2 days)

- Implement `ScreenCaptureService` Binder service
- Implement `droid_media_screen_capture_init()` / `droid_media_screen_capture_create()`
- Test cross-process `BufferQueue` handoff without any encoding

### Phase 3: HWC Plugin GPU Blit (2–3 days)

- Add RGBA→NV12 shader to HWC plugin
- Hook into `HWC2Window::present()` frame loop
- Test that NV12 frames appear in the BufferQueue consumer

### Phase 4: GStreamer `droidscreencapsrc` Element (3–5 days)

- Implement the source element
- Integrate encoder creation with metadata path
- End-to-end pipeline test: screen → encoder → H.264 file

### Phase 5: Polish & Optimization (2–3 days)

- Handle display on/off, resolution changes
- Tune bitrate control, I-frame interval
- Audio capture integration
- RPM packaging

---

## 8. Open Questions

1. **What is the target display resolution?** Query from HWC `getActiveConfig()` dynamically.

2. **What color format does the HW encoder accept for metadata mode?** Query at runtime. Typical: `OMX_COLOR_FormatYUV420SemiPlanar` (NV12), `OMX_QCOM_COLOR_FormatYUV420PackedSemiPlanar32m` (QC tiled).

3. **Can the GPU on the target SoC do efficient RGBA→NV12 in a single pass?** Depends on GPU MRT support and render target format compatibility.

4. **Should we encode at full resolution or offer downscaling?** Full-res recording (e.g., 1080×2340) needs significant encoder bandwidth. Add a `scale-factor` property.

5. **Does the device have `libI420colorconvert.so` or equivalent?** Could be used as a CPU fallback for color conversion.

6. **What alignment does the NV12 GraphicBuffer have?** Stride alignment affects the GL blit shader's output layout. Query from the dequeue'd buffer's `stride` field.
