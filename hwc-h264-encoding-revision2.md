# HWC Display → H.264 Encoder: Revision 2 (Post Phase-0 / Post-Implementation Review)

**Date:** 2026-07-27
**Supersedes:** `wiki/hwc-h264-encoding-revised.md` (2026-07-26) — does not replace it; this is a delta / corrective plan on top of the staged implementation.
**Inputs reviewed:**
- `wiki/hwc-h264-encoding-revised.md` (the plan)
- `wiki/hwc-h264-exec1.md`, `wiki/hwc-h264-exec2.md` (implementation logs)
- `wiki/hwc-h264-test-notes-phase0.md` (Phase-0 on-device test results)
- The staged code in `mw/droidmedia/`, `mw/gst-droid/gst/droidscreencapsrc/`, `mw/qt5-qpa-hwcomposer-plugin/hwcomposer/hwcomposer_backend_v20.cpp`

**Stated goal (carried from revision 1):** encode the screen with **minimal or zero copy.**

---

## 1. Executive summary

The implementation does **not** build in the target SDK environment, and the only artifact that has been run (`screencap_enc_test`) crashes before producing any H.264 output. Concretely:

1. **The build is broken.** The exec logs (`hwc-h264-exec1.md`, `exec2.md`) claim everything compiles, but the user confirms the build does not pass in their environment. The most likely cause is the QPA plugin's undeclared `droidmedia` dependency (§3.F.1): `hwcomposer_backend_v20.cpp` does `#include <droidmedia/droidmedia.h>` and calls `droid_media_screen_capture_init()` / `_consumer_new()` / `_get_dimensions()`, but `hwcomposer.pro` has no `PKGCONFIG += droidmedia` and the spec has no `BuildRequires`. Chosen fix: move the producer-side capture API into `libminisf.so` (already `android_dlopen`'d by the plugin), so the QPA link line doesn't change — see §4.F.

2. **Phase-0 produced zero output.** `hwc-h264-test-notes-phase0.md` records "Attempt B: SUCCESS" and "PHASE-0 PASSED", but the user confirms `screencap_enc_test` did **not** produce a non-zero file. The harness crashed on `MediaBuffer.cpp:97 CHECK_EQ(mRefCount, 0) failed: 1 vs. 0` before writing anything. The exec notes' claim that this crash is "test-harness-only" and that production is safe is **wrong** — production `ScreenCaptureMediaSource::read()` uses the same `new MediaBuffer(size)` allocation pattern (`screen_capture_mediasource.cpp:134`). This crash is the confirmed #1 blocker (§3.C.4), not a "probably reproduces later" item.

3. **Phase-0 refuted the central zero-copy assumption anyway.** On this device's Codec2/A14 stack, `droid_media_codec_create_encoder_raw()` returns NULL when `meta_data=1` (metadata-input / `GraphicBuffer`-handle pass-through). Only `meta_data=0` (RGBA `memcpy` into the encoder input buffer) is even *accepted* — and per item 2, even that has not produced output yet. See `hwc-h264-test-notes-phase0.md` lines 12-17.

4. **All production code still hardcodes the rejected `meta_data=1` path.** `screen_capture_encoder.cpp:178` sets `md.meta_data = 1`; `screen_capture_mediasource.cpp:131` writes a `VideoGrallocMetadata` (handle-only) into the encoder buffer; `droidscreencapsrc.c:65` defaults to `AndroidOpaque` with metadata semantics. Even if the build and the crash were fixed, the end-to-end `droidscreencapsrc` pipeline would fail at `screen_capture_encoder_new()` on the actual device.

5. **With `meta_data=0`, the staged architecture performs TWO copies per frame, not the one the user is targeting.** The HWC plugin does a GPU blit (RGBA screen buffer → RGBA capture `GraphicBuffer`), and the consumer then does a CPU `lock()`+`memcpy` of that capture buffer into the encoder's input. The GPU blit is wasted work. The chosen v1 path is 4.B.3 (consumer copies directly from the source screen buffer via `attachBuffer`, no GPU blit) with 4.B.2 (fix the blit) as fallback — see §4.B.

6. There are several additional **concrete correctness bugs** in the staged code that will surface as soon as the end-to-end path runs: a 1×1 viewport in the GPU blit (§3.B.1), a `waitForever()` on the UI thread (§3.B.2), static FBO/program leak (§3.B.3), an unsignaled `acquireBuffer` block on `stop()` (§3.C.3), a `droidscreencapsrc` `stop()`/`create()` deadlock (§3.E.1), no SELinux policy for `sailfish.screencap` (§3.G.1), and more. Catalogued in §3 with file:line references.

**Decisions locked in with the user (2026-07-28):**
- v1 target = **one CPU copy** of the screen buffer into the HW encoder. Zero-copy is deferred to a future Phase-5′ (Codec2 `C2GraphicBlock`).
- **No audio** in v1.
- Capture API moves into **`libminisf.so`** (option b) — also fixes the broken build.
- Minimal-copy path = **4.B.3 `attachBuffer`**, with **4.B.2 (fix the blit, two copies)** as fallback if `attachBuffer`/gralloc-import is rejected on device.
- Only `screencap_enc_test` has ever been run; it produced zero output. The end-to-end `droidscreencapsrc` has never run.

**Bottom line:** the path to v1 (one-copy screen recording) on this device is: (1) fix the build via the libminisf refactor, (2) fix the `MediaBuffer` crash so `screencap_enc_test` produces a *decodable* H.264 with `meta_data=0`, (3) make production dual-mode and default to copy, (4) replace the GPU blit with `attachBuffer` (or fall back), (5) wire `droidscreencapsrc` and run end-to-end. True zero-copy needs Codec2 `C2GraphicBlock` and is out of scope for v1.

---

## 2. What the staged implementation got right

| Area | Status | Evidence |
|---|---|---|
| Binder service `sailfish.screencap` (A14, `SurfaceFlingerAIDL` dual check) | ✅ Correct | `screen_capture_service.{h,cpp}`, `libminisf.cpp:38-50` |
| BufferQueue direction (producer in HWC proc, consumer via Binder) | ✅ Correct | `screen_capture.cpp:38-60` |
| `IGraphicBufferConsumer` cross-process handoff via `writeStrongBinder` | ✅ Correct | `screen_capture_service.cpp:40-46, 80-86` |
| RGBA format + `USAGE_HW_TEXTURE \| USAGE_HW_VIDEO_ENCODER` on the capture queue | ✅ Correct | `screen_capture.cpp:49-52` |
| `_DroidMediaBufferQueue` constructor overloads (producer-only / consumer-only) | ✅ Compiles | `private.cpp:105-125` |
| Non-blocking `dequeueBuffer` (drop on `-EAGAIN`/`-EBUSY`) | ✅ Correct intent | `hwcomposer_backend_v20.cpp:458-461` |
| Per-`buffer_handle_t` EGLImage/texture cache (avoids per-frame churn) | ✅ Correct | `ensureEglImage` L367-404 |
| `GlStateGuard` save/restore around the blit | ✅ Good idea | L408-439 |
| Frame-rate decimation counter | ✅ Correct | `hwcomposer_backend_v20.cpp:445` |
| Hybris symbol wrappers for the new C API (incl. 8-arg manual wrapper) | ✅ Correct | `hybris.c:259-281` |
| Plan's Open Question #1 (slot bookkeeping) resolved by `CaptureInputBuffer` subclass | ✅ Good | `screen_capture_mediasource.cpp:42-65` (matches AOSP `CameraSource` pattern) |

---

## 3. Issues found in the staged code

Severity labels: 🔴 critical (will not run / data loss), 🟠 major (wrong behavior, likely crash), 🟡 medium (latent / edge case), ⚪ minor.

### 3.A. Architectural — metadata-mode rejection

#### 🔴 3.A.1 Production hardcodes `meta_data=1`, which Phase-0 proved is rejected on this device
- `screen_capture_encoder.cpp:178` — `md.meta_data = 1;`
- `screen_capture_mediasource.cpp:126-137` — writes `{eType, pHandle}` (handle-only metadata, zero-copy).
- `droidscreencapsrc.c:65` — `DEFAULT_COLOR_FORMAT = OMX_COLOR_FormatAndroidOpaque`, and the element header comment (`gstdroidscreencapsrc.c:25-44`) describes metadata mode as the design.
- Phase-0 result (`hwc-h264-test-notes-phase0.md` table at L12-17): `AndroidOpaque + meta_data=1` → `droid_media_codec_create_encoder_raw()` returns NULL. Only `meta_data=0` works.

**Consequence:** `droidscreencapsrc` `start()` calls `screen_capture_encoder_new()` → `droid_media_codec_create_encoder_raw()` returns NULL → `GST_ELEMENT_ERROR(LIBRARY, INIT)` → pipeline refuses to start. The end-to-end path has never run on the target.

#### 🟠 3.A.2 The GPU blit is wasted work in the `meta_data=0` world
- HWC plugin: `captureFrame()` dequeues an RGBA capture `GraphicBuffer` and GPU-blits the screen buffer into it (`hwcomposer_backend_v20.cpp:488`).
- Consumer (in `meta_data=0` mode): `lock()`s the capture `GraphicBuffer` and `memcpy`s it into the encoder's input buffer (per `hwc-h264-test-notes-phase0.md` L43-50 and `screencap_enc_test.cpp:139-156`).
- Net: **two copies** (one GPU pass + one CPU copy) where one CPU copy would suffice, and the GPU pass is on the UI render thread.

**Consequence:** the implementation is further from the "minimal/zero copy" goal than a trivial "lock the screen buffer and memcpy" approach would be, and it adds UI-thread GPU work.

### 3.B. HWC plugin correctness bugs (`hwcomposer_backend_v20.cpp`)

#### 🔴 3.B.1 GPU blit uses a 1×1 viewport — only the top-left pixel is written
- `hwcomposer_backend_v20.cpp:577` — `glViewport(0, 0, 1, 1);  /* viewport is irrelevant; we're blitting tex→tex */`
- This is wrong. The destination is an FBO whose color attachment is `dstTex` at `width × height`. With a 1×1 viewport, the rasterizer only covers the bottom-left pixel; the rest of `dstTex` is undefined (likely the prior frame's contents or uninitialized memory). The encoder will receive a mostly-garbage frame.

**Fix:** `glViewport(0, 0, dw, dh);` — and the `dw`/`dh` parameters must actually be plumbed in (currently `blitRgbaToRgba` takes `int /*dw*/, int /*dh*/` and ignores them, L518-519).

#### 🟠 3.B.2 `fence->waitForever()` on the UI thread
- `hwcomposer_backend_v20.cpp:467-469` — `if (fence->isValid()) fence->waitForever();`
- This is the slot's dequeue fence (signaled when the buffer is free to be written by the producer). On the producer side this is normally quick, but with the consumer in another process and the encoder holding buffers for B-frame reordering, the wait can be long. The revised plan explicitly said **do not block the UI thread** (revision-1 §1 row 4).

**Fix:** `fence->wait(1000 /* ms */)`; on `-ETIMEDOUT` drop the frame (`return`). Or, better, attach the dequeue fence to the source EGLImage as a wait dependency and skip the explicit wait.

#### 🟠 3.B.3 `static GLuint fbo` / `static GLuint program` are never destroyed and leak across window recreates
- `hwcomposer_backend_v20.cpp:540, 557` — function-local statics.
- On hotplug / display config change, `~HWC2Window` runs `captureShutdown()` which clears `m_captureEglImages`/`m_captureTextures`, but the blit's `fbo`/`program` statics persist. The next `HWC2Window` will reuse them, but the FBO's color attachment now points at a deleted texture. Also, multiple `HWC2Window` instances (multi-display) would share the same static FBO — race.

**Fix:** make `fbo`/`program` instance members (or a small per-context cache keyed on `EGLContext`), and destroy them in `captureShutdown()`.

#### 🟡 3.B.4 `eglCreateImageKHR` on the *source* screen buffer is unverified
- `hwcomposer_backend_v20.cpp:480-484` — `srcHandle = src->handle` (a hybris gralloc `native_handle_t`) → `eglCreateImageKHR(... EGL_NATIVE_BUFFER_ANDROID, srcHandle ...)`.
- The screen buffer's `handle` is allocated by hybris gralloc (`hybris_gralloc_allocate` in `libhybris/.../hwcomposer_window.cpp`). Whether the vendor EGL driver accepts a hybris gralloc handle for `EGL_NATIVE_BUFFER_ANDROID` depends on hybris↔vendor-gralloc interop. Phase-2 has not been run, so this is unverified. On some adaptations the handle needs `native_handle_clone` or the import goes through a different path.

**Fix:** verify in Phase-2 step 1 before relying on it. Fallback: drop the blit and have the consumer `lock()`+`memcpy` the source screen buffer directly (see §4.B).

#### 🟡 3.B.5 `glFlush()` after `eglCreateSyncKHR` is the wrong order
- `hwcomposer_backend_v20.cpp:491-497` — `eglCreateSyncKHR` then `glFlush()` then `eglDupNativeFenceFDANDROID`.
- `eglCreateSyncKHR(EGL_SYNC_FENCE_KHR)` inserts a fence in the GL command stream; `glFlush()` just kicks the queue. The correct order is: issue draw → `glFlush()` (or rely on the fence) → `eglDupNativeFenceFDANDROID`. The current order works in practice but the `glFlush` inside the `if (sync != EGL_NO_SYNC_KHR)` block is after the sync was created, which is fine. This is mostly a style nit, but the comment "Flush, then dup" is slightly misleading. No code change required unless the fence never fires.

#### 🟡 3.B.6 `captureInit` is called from `present()` on the UI thread with no error recovery
- `hwcomposer_backend_v20.cpp:253-258` — if `droid_media_screen_capture_init` fails, `m_captureEnabled` is set false but `m_captureQueue` stays nullptr; the next frame retries `captureInit` because of the `m_captureQueue == nullptr` guard. This is fine, but if `init` partially succeeds (consumer stored in `ScreenCaptureService`, producer returned NULL), the service now holds a dangling consumer. `droid_media_screen_capture_init` should be all-or-nothing.

### 3.C. `ScreenCaptureMediaSource` / encoder wrapper

#### 🔴 3.C.1 `read()` writes metadata-mode payload but the encoder is (to be) created in `meta_data=0` mode
- `screen_capture_mediasource.cpp:126-137` — always writes `{eType=kMetadataBufferTypeGrallocSource, pHandle=handle}`.
- In `meta_data=0` mode the encoder expects **raw RGBA bytes** in `mbuf->data()`, not a `VideoGrallocMetadata` struct. Feeding the metadata struct as if it were pixel data → encoder reads 8-16 bytes of "pixels" → garbage H.264 / crash.

**Fix:** make `read()` mode-aware (see §4.A.1). In copy mode: `lock()` the dequeued `GraphicBuffer`, `memcpy` row-by-row (respecting stride) into `mbuf->data()`, `unlock()`, then `releaseBuffer` on `CaptureInputBuffer` destruction.

#### 🟠 3.C.2 `getFormat()` omits `kKeyMaxInputSize`, `kKeyStride`, `kKeySliceHeight`
- `screen_capture_mediasource.cpp:98-105` — only MIME/width/height/colorFormat.
- For `meta_data=0` the encoder uses these to size and lay out its input buffers. The test harness sets them (`screencap_enc_test.cpp:100-103`); production does not. Without `max-input-size`, `droidmediacodec.cpp:435` does not set `format->setInt32("max-input-size", ...)`, and the encoder picks a default (often based on YUV size, not RGBA) → truncated/garbled input.

**Fix:** set `kKeyMaxInputSize = width*height*4`, `kKeyStride = width`, `kKeySliceHeight = height` in `getFormat()` for copy mode.

#### 🟠 3.C.3 `stop()` does not wake a blocked `read()`
- `screen_capture_mediasource.cpp:92-96` — `stop()` just sets `mStarted = false`. `read()` (L114-119) blocks in `mConsumer->acquireBuffer(&item, 5000000000LL)` for up to 5 s with no cancellation. The plan's sketch (revision-1 §5.4) had a `Mutex mLock; Condition mCond;` — the implementation dropped them. Also `read()` has no `Mutex::Autolock`, so `mStarted` is a data race.

**Fix:** add `mLock`/`mCond`; `stop()` sets `mStarted = false` under `mLock` and signals; `read()` waits on `acquireBuffer` with a short timeout in a loop, checking `mStarted` each iteration. Better: drive `acquireBuffer` via the BufferQueue's `onFrameAvailable` listener + `mCond` so `stop()` can wake it instantly.

#### 🔴 3.C.4 `MediaBuffer` refcount crash — confirmed #1 blocker, not test-harness-only
- `hwc-h264-test-notes-phase0.md` L56-72 attributes the `MediaBuffer.cpp:97 CHECK_EQ(mRefCount, 0) failed: 1 vs. 0` crash to "ad-hoc `new MediaBuffer(size)`" and claims production avoids it. **The user confirms this is wrong: `screencap_enc_test` did not produce a non-zero output file — it crashed before writing anything.** The crash is the actual #1 blocker, not a latent risk.
- Production `read()` does **the same thing** the test harness does: `new CaptureInputBuffer(sizeof(meta), ...)` (`screen_capture_mediasource.cpp:134`), which is `new MediaBuffer(metaSize)` subclass. The crash will reproduce in production for the same reason.
- AOSP's `MediaSource` contract: `read()` returns a `MediaBuffer*` whose ownership transfers to the caller (the encoder). The encoder calls `buffer->release()`, which calls `decRef`, and when refcount hits 0, `delete`. The `CHECK_EQ(mRefCount, 0)` at destruction fires if anyone still holds a strong reference when the destructor runs. The crash means `release()` was called while the buffer was still in scope somewhere (likely an `sp<MediaBuffer>` inside `AsyncCodecSource`'s input queue not being cleared before the source is destroyed, or a double-release path).

**Fix:** align with how `CameraSource` allocates its `MediaBuffer`s. `CameraSource` pre-allocates a pool sized to the codec's `kKeyMaxInputSize` and reuses them (see `CameraSource.cpp` `createMediaBuffer` / `signalBufferReturned`). For `meta_data=0`, the robust approach is one of:
- (preferred) Don't `new` a `MediaBuffer` per `read()`; instead use the codec's input-slot allocation path. `AsyncCodecSource` already manages an input buffer pool; a `MediaSource` that returns buffers from that pool (via the `MediaBuffer` returned by `MediaCodec::dequeueInputBuffer`) avoids the refcount mismatch entirely. This requires checking whether `droidmediacodec.cpp`'s `AsyncCodecSource::Create(src, format, true /*isEncoder*/, ...)` wiring passes the input-slot pool through to `src->read()` — if not, this is a larger change.
- (fallback) Keep `new CaptureInputBuffer` but ensure the encoder releases **all** in-flight buffers before `stop()` returns. Implement a `drain()` that blocks until `mPending` (the `std::map<MediaBufferBase*, Pending>` from the revision-1 sketch — currently missing from the implementation) is empty. This requires the encoder to actually call our release callback for every outstanding buffer, which is what's failing.
- (debugging aid) Add `ALOGI` in `CaptureInputBuffer`'s ctor and dtor logging `this`, `mSlot`, `mFrameNumber`, and `mRefCount` so the exact double-release / leak path is visible in logcat.

This must be fixed and verified (Tier-1 test) before any end-to-end work.

#### 🟡 3.C.5 `CaptureInputBuffer::~CaptureInputBuffer()` calls `releaseBuffer` with `Fence::NO_FENCE`
- `screen_capture_mediasource.cpp:53-59` — always `Fence::NO_FENCE`.
- In metadata mode the encoder reads the `GraphicBuffer` asynchronously; releasing the slot with `NO_FENCE` tells the producer "I'm done, you can reuse it" *before* the encoder's DMA may have finished. In copy mode it's fine (the `memcpy` has completed synchronously). For metadata mode this is a use-after-free hazard on the buffer memory. (Moot on this device since metadata mode is rejected, but relevant if the dual-mode path is kept for portability.)

**Fix:** in metadata mode, extract the encoder's release fence from `MediaBuffer::meta_data()` (`kKeyFence` or similar) and pass it. For copy mode, `NO_FENCE` is correct.

### 3.D. `_DroidMediaBufferQueue` lifecycle (`private.cpp`)

#### 🟠 3.D.1 `releaseMediaBuffer(int)` dereferences `m_slots[index].mFrameNumber` even for the consumer-side wrapper
- `private.cpp:285-307` — `releaseMediaBuffer(int index, ...)` checks `m_queue == NULL` (producer-side → returns early), but for the consumer-side wrapper it unconditionally uses `m_slots[index].mFrameNumber` (L294).
- The `ScreenCaptureMediaSource` does **not** route through `_DroidMediaBufferQueue::frameAvailable()` (it calls `acquireBuffer` directly on `m_queue`, bypassing the `m_slots`/`m_cb` machinery). So `m_slots[index]` is zero-initialized and `mFrameNumber == 0` always → `releaseBuffer(slot, 0, ...)` hits `STALE_BUFFER_SLOT` every time.
- The `CaptureInputBuffer` destructor sidesteps this by calling `mConsumer->releaseBuffer(...)` **directly** (`screen_capture_mediasource.cpp:55-57`), so the bug is latent rather than active — but it's a landmine: any future caller that uses `DroidMediaBufferQueue::releaseMediaBuffer(DroidMediaBuffer*, ...)` on the consumer-side wrapper will get stale-slot errors.

**Fix:** in `releaseMediaBuffer(int)`, when the consumer-side wrapper was constructed without `setCallbacks`, track frame numbers in a small `std::map<int, int64_t>` populated by `acquireBuffer`-equivalent calls, or simply require that consumer-side wrappers used by `ScreenCaptureMediaSource` never go through `_DroidMediaBufferQueue::releaseMediaBuffer`. Add an `assert(m_data != 0)` guard or split the class.

#### 🟡 3.D.2 `frameAvailable()` on the consumer-side wrapper is dead but reachable
- `private.cpp:195-269` — `frameAvailable()` uses `m_slots`, `m_cb.buffer_created`, `m_cb.frame_available`. For the screen-capture consumer wrapper, `m_cb` is zeroed (`memset` in ctor L123) and `m_data` is 0, so `frameAvailable()` will hit the "Client wasn't able to handle a received frame" branch (L265) and call `releaseMediaBuffer` immediately, dropping every frame.
- This is only reachable if `connectListener()` is called and the BufferQueue's `onFrameAvailable` fires. `droid_media_screen_capture_consumer_new()` does call `connectListener()` (`screen_capture.cpp:89`). BUT `ScreenCaptureMediaSource` calls `mConsumer->acquireBuffer` directly, which races with the listener's `acquireBuffer` — one of them will get `NO_BUFFER_AVAILABLE` or `INVALID_OPERATION`. This is a real race.

**Fix:** do **not** call `connectListener()` for the consumer-side wrapper when used by `ScreenCaptureMediaSource`. Either (a) add a `connectListener(bool silent)` variant that installs a no-op listener, or (b) have `ScreenCaptureMediaSource` install its own `wp<ConsumerListener>` that translates `onFrameAvailable` into `mCond.signal()` (the correct design — see §4.C.2).

### 3.E. GStreamer element (`droidscreencapsrc`)

#### 🟠 3.E.1 `create()` can deadlock on `stop()`
- `gstdroidscreencapsrc.c:415-420` — `create()` waits on `output_cond` while `output_queue` is empty and `!eos`.
- `stop()` (L373-401) sets `running = FALSE`, stops the encoder (joins poll thread), then drains `output_queue`. But if `create()` is blocked in `g_cond_wait` when `stop()` is called, and the poll thread has already exited without producing a frame, `create()` never wakes. `stop()` doesn't set `eos = TRUE` or signal `output_cond` before joining.
- Also `stop()` drains `output_queue` *after* `screen_capture_encoder_stop()` — but `encoder_stop` joins the thread that produces into `output_queue`. Order is OK for draining, but the blocked `create()` is the problem.

**Fix:** in `stop()`, before `screen_capture_encoder_stop()`, acquire `output_lock`, set `eos = TRUE` (or a `flushing` flag), `g_cond_signal(&output_cond)`, release; let `create()` wake and return `GST_FLOW_FLUSHING`; then stop the encoder. The base class `GstBaseSrc` will handle the rest.

#### 🟠 3.E.2 No backpressure on `output_queue`
- `gstdroidscreencapsrc.c:264-275` — `data_available` pushes onto `output_queue` unbounded.
- If downstream (muxer → slow storage) is slower than the encoder, `output_queue` grows without bound → OOM on a long recording.

**Fix:** cap `output_queue` length (e.g., 10 frames); when full, either drop the oldest non-keyframe or block `data_available` on a `cond` until `create()` drains one. The drop policy is safer for live screen capture.

#### 🟡 3.E.3 `codec_config` buffers sent as data buffers with HEADER flag
- `gstdroidscreencapsrc.c:462-465` — SPS/PPS emitted as a regular buffer with `GST_BUFFER_FLAG_HEADER`.
- `h264parse` downstream will recover, but the cleaner pattern is to put the codec-config bytes in the source pad caps as `codec_data` and not emit them as buffers at all (or emit them only once at start). Minor; can defer.

#### 🟡 3.E.4 No `GST_FLOW_FLUSH` / segment handling
- The element is `live` (L176) but doesn't handle a `FLUSH_START`/`FLUSH_STOP` event. On a seek or state transition mid-recording, `create()` may be called with a flushing peer and will block forever.

**Fix:** implement `GstBaseSrc::event` (or rely on `GstPushSrc` defaults) and check `GST_PAD_IS_FLUSHING()` in `create()`.

### 3.F. Build / packaging

#### 🔴 3.F.1 The QPA plugin has no `droidmedia` build dependency — confirmed build-breaker
- `hwcomposer.pro:65` — `PKGCONFIG += android-headers libhardware hybris-egl-platform` (no `droidmedia`).
- `hwcomposer_backend_v20.cpp:59` — `#include <droidmedia/droidmedia.h>`; the file also calls `droid_media_screen_capture_init()`, `_consumer_new()` (via `screen_capture_encoder_new`), and `_get_dimensions()`.
- `rpm/qt5-qpa-hwcomposer-plugin.spec` — no `BuildRequires: pkgconfig(droidmedia)`.
- The exec logs claim the build passed, but **the user confirms it does not pass in their environment.** This undeclared dependency is the most likely cause: on a clean SDK build the `#include` fails (no header path), and even if the header is transitively visible, the link step has no `-ldroidmedia` (the hybris shim in `hybris.c` provides runtime `dlsym` wrappers, but the wrappers themselves need `screen_capture_encoder.h` and the droidmedia headers at build time, and `hwcomposer.pro` doesn't pull them in).
- This also inverts the layering the original assessment warned about: the QPA plugin now depends on `droidmedia` directly, coupling the boot-critical compositor to the media stack.

**Fix (chosen — option b):** move the producer-side capture API (`droid_media_screen_capture_init`, `_consumer_new`, `_get_dimensions`) into **`libminisf.so`**. The QPA plugin already `android_dlopen("libminisf.so")`s it via `initLegacyHwComposerQuirks` (`hwcomposer_backend.cpp:90-105`) and resolves `startMiniSurfaceFlinger` by `dlsym`. Add a sibling `dlsym`-resolved entry point (e.g. `minisf_screen_capture_init`) so the QPA plugin's link line is unchanged — it just gains one more `dlsym` lookup. The `libminisf → libdroidmedia` edge added in exec2 stays. See §4.F for the concrete API shape.

#### 🟡 3.F.2 `libminisf` now links `libdroidmedia` (exec2 fix 1)
- `Android.mk` (per exec2) added `libdroidmedia` to `libminisf`'s `LOCAL_SHARED_LIBRARIES`. This is correct for resolving `IScreenCaptureService::IScreenCaptureService()` (the `IMPLEMENT_META_INTERFACE` is compiled into `libdroidmedia`).
- Note: this creates a `libminisf → libdroidmedia` edge. `libdroidmedia` must **not** pull in `libminisf` (it doesn't, per exec2). Keep this invariant.

#### ⚪ 3.F.3 `screen_capture_encoder.cpp` includes `private.h`, which pulls `<camera/Camera.h>`
- `private.h:24` — `#include <camera/Camera.h>`. This is a heavy include for the encoder wrapper.
- Not a bug, but it adds build-time cost and a transitive dep on `libcamera_client`. Forward-declaring `DroidMediaBufferQueue` and putting `consumer()` accessor in a smaller header would be cleaner.

### 3.G. Security / system integration

#### 🟠 3.G.1 No SELinux policy for `sailfish.screencap`
- On A14, `servicemanager` enforces `service_manager: { add }` for service-name labels. Without an `allow <hwc_proc_context> servicemanager:binder { call transfer }; allow <hwc_proc_context> service_manager_type:sailfish_screencap { add };` rule (and a `sailfish_screencap` type declaration in `service_contexts`), `ScreenCaptureService::instantiate()` will be denied and `getService` from the GStreamer process will return NULL forever — the `droidscreencapsrc` retry loop (`gstdroidscreencapsrc.c:315-325`) will time out after 5 s.
- The plan (revision-1 §9) listed this as a risk but no `.te` / `service_contexts` file is included in the staged changes.

**Fix:** add to the droid-hal SELinux policy: a `type sailfish_screencap_service;` declaration, an entry in `service_contexts` mapping `"sailfish.screencap"` to that type, and `allow` rules for both the HWC process (to `add`) and the GStreamer/media process (to `find`/`transfer`).

### 3.H. Runtime state management

#### 🟡 3.H.1 `ScreenCaptureService::setConsumer` replaces consumer without notifying the consumer side
- `screen_capture_service.h:80-86` — `setConsumer(c, w, h)` overwrites `sConsumer`.
- On a screen resolution / DPI change, the HWC plugin tears down its capture queue and calls `droid_media_screen_capture_init` again, which calls `setConsumer` with a new consumer. The GStreamer side still holds the **old** `IGraphicBufferConsumer` proxy. Frames queued to the new producer never reach the old consumer; `acquireBuffer` on the old consumer blocks forever.
- No generation counter, no `consumerChanged` callback.

**Fix:** add a `int64_t generation` to `ScreenCaptureService` incremented on each `setConsumer`; expose via Binder. `droid_media_screen_capture_consumer_new` returns the generation; `droidscreencapsrc` polls `getGeneration` (or subscribes to a `consumerChanged` callback) and tears down + recreates its encoder pipeline when it changes. Simpler v1: have `droidscreencapsrc` watch for `acquireBuffer` returning `NO_INIT` and bail.

#### 🟡 3.H.2 Capture dims cached at `HWC2Window` construction
- `hwcomposer_backend_v20.cpp:186-187` — `m_captureWidth = width; m_captureHeight = height;` from the ctor args.
- If the display config changes (rotation, resolution), `m_captureWidth/Height` are stale. The capture BufferQueue is sized wrong → `dequeueBuffer` returns buffers at the old size → encoder gets mismatched frames.

**Fix:** re-query on `onHotplugReceived` / config change (`getScreenSizes` L727-750) and tear down + re-init the capture queue.

### 3.I. Test coverage

#### 🔴 3.I.1 No automated tests; Phase-0 verdict was wrong
- The only test is `screencap_enc_test.cpp` (Phase-0), which:
  - **Crashes on the `MediaBuffer` refcount assertion before producing any output** — confirmed by the user. The exec notes' "Attempt B: SUCCESS" / "PHASE-0 PASSED" record is incorrect.
  - Would have reported "PASSED" based on `st.st_size > 0` only (`screencap_enc_test.cpp:360-365`) even if it had run — does not parse the H.264 or verify playability.
  - Tests only the encoder in isolation; does not exercise the BufferQueue transport, the Binder service, the HWC hook, or `droidscreencapsrc`.
- There are no tests for `ScreenCaptureService`, `_DroidMediaBufferQueue` new constructors, `ScreenCaptureMediaSource`, `screen_capture_encoder`, or `droidscreencapsrc`.

**Fix:** see §5 — a layered test plan, starting with fixing the crash and confirming a *decodable* H.264 from `screencap_enc_test`, then a cross-process BufferQueue round-trip test, before any end-to-end GStreamer run.

---

## 4. Proposed changes

### 4.A. Reconcile production code with Phase-0 reality

#### 4.A.1 Make `ScreenCaptureMediaSource` dual-mode (metadata vs. copy)
Add `bool mMetadataMode` to `ScreenCaptureMediaSource`, set at construction based on a probe (try `meta_data=1`; on NULL, fall back to `meta_data=0`). The probe is exactly what `screencap_enc_test.cpp:262-278` already does — extract that into `screen_capture_encoder_new` so production gets the same fallback behavior automatically.

In `read()`:
- **metadata mode** (`mMetadataMode == true`, currently the only path): keep the `VideoGrallocMetadata` write.
- **copy mode** (`mMetadataMode == false`): `lock()` the dequeued `GraphicBuffer` with `GRALLOC_USAGE_SW_READ_OFTEN`, `memcpy` row-by-row (respecting `GraphicBuffer::getStride()`) into `mbuf->data()`, `unlock()`. The `CaptureInputBuffer` destructor still calls `releaseBuffer` — that part is mode-independent.

In `getFormat()`, set `kKeyMaxInputSize = width*height*4`, `kKeyStride = width`, `kKeySliceHeight = height` in copy mode (and conditionally in metadata mode — harmless if the codec ignores them).

In `screen_capture_encoder_new`, set `md.meta_data = mMetadataMode ? 1 : 0` and `md.max_input_size = width*height*4` (needed in copy mode; harmless in metadata mode). Add `bool *out_used_metadata` so `droidscreencapsrc` can log which path it took.

#### 4.A.2 Default `droidscreencapsrc` to the working path
Change `DEFAULT_COLOR_FORMAT` and the element description comment to reflect that copy mode is the default on Codec2/A14, with metadata mode as an opt-in for devices that support it. Add a `metadata-mode` boolean property (default FALSE) so a user can force `meta_data=1` for testing on devices that accept it.

#### 4.A.3 Document the zero-copy outcome honestly
In `hwc-h264-encoding-revised.md` (and RPM descriptions / user-facing docs), state that on this device the encoder input path is **one CPU copy** (RGBA lock+memcpy), not zero-copy. True zero-copy via `MediaCodec` is not available on this Codec2 stack; a future Phase-5 would pursue the Codec2 `C2GraphicBlock` input path (§6).

### 4.B. Eliminate the redundant GPU blit (the real minimal-copy win for v1)

**Decision locked in with the user: 4.B.3 (`attachBuffer`) is the primary v1 path; 4.B.2 (fix the blit, two copies) is the fallback if `attachBuffer`/cross-process gralloc handle import is rejected on device.**

In copy mode (`meta_data=0`), the staged GPU blit in `captureFrame` is pure overhead: it copies the screen buffer into a capture `GraphicBuffer`, which the consumer then `memcpy`s again into the encoder input. Two copies where one suffices, plus GPU work on the UI thread.

#### 4.B.1 Deferred — direct queueBuffer of the source handle
- The HWC plugin's `present(buffer)` has the just-rendered screen `GraphicBuffer` (an `HWComposerNativeWindowBuffer*` whose `handle` is the gralloc buffer). Instead of dequeue+blit+queue, the producer hands this buffer (with its acquire fence) directly to the consumer via the BufferQueue using `IGraphicBufferProducer::queueBuffer` with the source `GraphicBuffer` registered into a slot via `attachBuffer`.
- Risk: the screen `GraphicBuffer` is owned by the HWC slot cache; the producer must not release it back to HWC until the encoder is done. With `maxAcquiredBufferCount = 8` the encoder can hold several frames, which exceeds the HWC's 3-buffer slot cache → the HWC will stall on `dequeueBuffer` waiting for a free slot. This is the fundamental tension. The GPU-blit approach decouples the lifetimes; the direct-attach approach couples them.
- **Verdict:** deferred to Phase-5′. Not a v1 path — the lifetime entanglement with the HWC slot cache is the wrong fight for v1.

#### 4.B.2 Fallback — keep the GPU blit, but make it correct and cheap
Fix the bugs in §3.B (1×1 viewport → `glViewport(0,0,dw,dh)`; `fence->wait(1000)` not `waitForever`; instance-member FBO/program; verify source `eglCreateImageKHR`) so the blit at least produces correct output. Accept that v1 is "GPU pass + CPU copy" (two copies) and document it. This is the lowest-risk path to a *working* screen recorder if 4.B.3 fails on device.

Only the `hwcomposer_backend_v20.cpp` blit-related code is touched here — no droidmedia / GStreamer changes beyond what §4.A/§4.C/§4.E already require.

#### 4.B.3 Chosen v1 path — drop the GPU blit; consumer `lock()`+`memcpy`s the screen buffer via a passthrough BufferQueue
- `captureFrame()` in `hwcomposer_backend_v20.cpp` is rewritten: instead of `dequeueBuffer`+blit+`queueBuffer`, it calls `IGraphicBufferProducer::attachBuffer(&slot, srcGraphicBuffer)` to register the **source** screen `GraphicBuffer` into a BufferQueue slot, then `queueBuffer(slot, qbi_with_fence, &qbo)`. The producer never allocates its own buffers (`setDefaultBufferCount`/`setMaxAcquiredBufferCount` govern how many source buffers can be in flight at once).
- The consumer (`ScreenCaptureMediaSource::read()`, in copy mode) `acquireBuffer`s the source buffer directly, `lock(GRALLOC_USAGE_SW_READ_OFTEN)`s it, `memcpy`s row-by-row (respecting `GraphicBuffer::getStride()`) into `mbuf->data()`, `unlock()`s, and the `CaptureInputBuffer` destructor calls `releaseBuffer(slot, frameNumber, ...)` — which signals the HWC that the slot is free.
- This is the closest to "one copy" without the lifetime entanglement of 4.B.1, because the BufferQueue's own backpressure (max acquired) limits how many screen buffers the encoder can hold. Set `maxAcquiredBufferCount` ≤ the HWC slot-cache size (3) so the HWC never stalls waiting for a free slot — at the cost of dropping frames if the encoder is slower than the display (acceptable for v1; better than stalling the UI).
- **Open risk to probe in Phase-2 step 1:** `attachBuffer` + cross-process gralloc handle import. The source `GraphicBuffer` is allocated by hybris gralloc (`hybris_gralloc_allocate`); whether the consumer process (GStreamer) can `lock()` it after `acquireBuffer` depends on hybris↔vendor-gralloc interop. This is the same interop question as 3.B.4 (source `eglCreateImageKHR`), just on the consumer side instead of the producer side. If `lock()` fails with `-EINVAL` or similar in the consumer process, fall back to 4.B.2.
- **Implementation order:** Phase-2 step 1 writes a tiny probe (no encoder, no GStreamer) — producer `attachBuffer`s a hybris-allocated `GraphicBuffer`, consumer `acquireBuffer`s + `lock()`s + reads pixel 0. If that works, build out 4.B.3. If not, fall back to 4.B.2 and accept two copies for v1.

### 4.C. Fix the BufferQueue / MediaSource lifecycle

#### 4.C.1 `ScreenCaptureMediaSource` should own its own `ConsumerListener`
Replace the `_DroidMediaBufferQueue::connectListener()` call in `droid_media_screen_capture_consumer_new` (which installs the dead `DroidMediaBufferQueueListener` that races with `ScreenCaptureMediaSource`'s direct `acquireBuffer`) with a listener owned by `ScreenCaptureMediaSource` itself:
```cpp
class ScreenCaptureMediaSource : public MediaSource,
                                public BufferItemConsumer::ConsumerListener {
    void onFrameAvailable(const BufferItem&) { Mutex::Autolock l(mLock); mCond.signal(); }
    ...
};
```
Connect it via `mConsumer->consumerConnect(this, false)` in `start()`. This removes the race in 3.D.2 and gives `stop()` a way to wake `read()` (3.C.3).

If keeping the `_DroidMediaBufferQueue` wrapper for API consistency, add a `connectListener(ConsumerListener*)` overload that takes an external listener and does not install `DroidMediaBufferQueueListener`.

#### 4.C.2 Fix `releaseMediaBuffer(int)` for the consumer-side wrapper
Either (a) require `setCallbacks` to be called before any `releaseMediaBuffer` on the consumer-side wrapper (and `assert(m_data)`), or (b) maintain a small `std::map<int /*slot*/, int64_t /*frameNumber*/>` updated on each `acquireBuffer` in `ScreenCaptureMediaSource` and pass the frame number through. Since `CaptureInputBuffer` already carries `mSlot`/`mFrameNumber` and calls `mConsumer->releaseBuffer` directly, the cleanest fix is to **remove** the `_DroidMediaBufferQueue::releaseMediaBuffer` path from the consumer-side wrapper entirely (make it return `INVALID_OPERATION` with a clear log) so nobody accidentally uses it.

### 4.D. Fix the HWC plugin bugs

- **Viewport (3.B.1):** change `glViewport(0, 0, 1, 1)` → `glViewport(0, 0, dw, dh)`; plumb `dw`/`dh` into `blitRgbaToRgba` (remove the `/*dw*/` parameter elision).
- **Fence wait (3.B.2):** `fence->wait(1000)`; on `-ETIMEDOUT`, `qWarning` and `return`.
- **Static FBO/program (3.B.3):** make `fbo`/`program` instance members of `HWC2Window`; destroy in `captureShutdown()`.
- **Source EGLImage (3.B.4):** verify in Phase-2 step 1; if it fails, fall back to 4.B.3 (no GPU blit).
- **Partial init (3.B.6):** in `droid_media_screen_capture_init`, only call `ScreenCaptureService::setConsumer` after the producer is successfully created and wrapped; on any failure, return NULL without mutating the service.

### 4.E. Fix `droidscreencapsrc`

- **Deadlock on stop (3.E.1):** in `stop()`, lock `output_lock`, set a `flushing = TRUE` flag, `g_cond_signal(&output_cond)`, unlock; let `create()` return `GST_FLOW_FLUSHING`; then stop the encoder. Reset `flushing` on next `start()`.
- **Backpressure (3.E.2):** cap `output_queue` at N (10); in `data_available`, if full, drop the oldest non-keyframe (or block with a `cond_wait` until `create()` drains one — but that couples the encoder poll thread to GStreamer's pull rate, risky). For live capture, drop is safer.
- **Flush handling (3.E.4):** check `GST_PAD_IS_FLUSHING(src->srcpad)` in `create()` wait loop.

### 4.F. Build / packaging — move producer-side capture API into `libminisf.so`

**Chosen: option (b) — move the capture API into `libminisf.so`.** This fixes the broken build (§3.F.1) and the layering inversion in one move.

#### 4.F.1 New `libminisf` entry points
The QPA plugin already resolves `startMiniSurfaceFlinger` from `libminisf.so` by `dlsym` (`hwcomposer_backend.cpp:90-105`). Add sibling entry points in `libminisf.cpp` (which already links `libdroidmedia` per exec2):

```c
/* Exposed by libminisf.so, resolved by the QPA plugin via android_dlsym.
 * Declarations live in a new tiny header shipped with the android-headers
 * package (or vendored into the QPA plugin) so hwcomposer.pro doesn't
 * need PKGCONFIG += droidmedia. */

/* Producer side — called from the HWC plugin process.
 * Wraps droid_media_screen_capture_init + ScreenCaptureService::setConsumer. */
void minisf_screen_capture_init(int width, int height,
                                DroidMediaBufferQueue **out_queue);

/* Consumer side — called from the GStreamer process.
 * Wraps droid_media_screen_capture_consumer_new. */
DroidMediaBufferQueue *minisf_screen_capture_consumer_new(void);

/* Dimensions query — called from the GStreamer process. */
int minisf_screen_capture_get_dimensions(int *width, int *height);
```

These are trivial pass-throughs to the existing `droid_media_screen_capture_*` functions (which stay in `libdroidmedia.so` / `screen_capture.cpp`). `libminisf` already pulls `libdroidmedia` as a shared lib (exec2 fix), so the symbols resolve at link time.

#### 4.F.2 QPA plugin changes
- `hwcomposer_backend_v20.cpp`: drop `#include <droidmedia/droidmedia.h>`. Instead, forward-declare the three `minisf_screen_capture_*` functions in `hwcomposer_backend_v20.cpp` (or a small local header), and resolve them via `android_dlsym(libminisf, "minisf_screen_capture_init")` next to the existing `startMiniSurfaceFlinger` lookup in `hwcomposer_backend.cpp`. Cache the function pointers on the `HwComposerBackend` / `HWC2Window` so we don't `dlsym` per frame.
- `hwcomposer.pro`: **no change** — no `PKGCONFIG += droidmedia`, no new `LIBS`. The build dependency on `droidmedia` is gone; the runtime dependency is via `libminisf.so`, which the plugin already loads.
- `rpm/qt5-qpa-hwcomposer-plugin.spec`: **no change** to `BuildRequires`. The runtime `Requires:` on `droidmedia` (transitively via `libminisf`) is already there because `libminisf` is shipped by the `droidmedia` package.

#### 4.F.3 `libminisf` build changes
- `Android.mk` (libminisf module): add `minisf_screen_capture.cpp` (or fold the three functions into `libminisf.cpp`) to `LOCAL_SRC_FILES`. It already has `libdroidmedia` in `LOCAL_SHARED_LIBRARIES` (exec2).
- The `screen_capture_service.{h,cpp}` and `screen_capture.cpp` files stay in `libdroidmedia` (they reference `BufferQueue::createBufferQueue`, `ScreenCaptureService`, etc., which are `libdroidmedia` internals). `libminisf` just calls into them.

#### 4.F.4 SELinux (§3.G.1)
Add to the droid-hal SELinux policy:
- `type sailfish_screencap_service;` declaration.
- Entry in `service_contexts`: `"sailfish.screencap" u:object_r:sailfish_screencap_service:s0`.
- `allow <hwc_proc_context> sailfish_screencap_service:service_manager { add };` (HWC plugin registers the service).
- `allow <media_proc_context> sailfish_screencap_service:service_manager { find };` and `allow <media_proc_context> sailfish_screencap_service:binder { call transfer };` (GStreamer process looks it up and talks to it).

Run `audit2allow` on the first on-device run to catch anything missing.

### 4.G. Resolution / hotplug

- **Generation counter (3.H.1):** add `int64_t getGeneration()` to `ScreenCaptureService`; `droidscreencapsrc` polls it (cheap Binder call) every N frames or on `acquireBuffer` returning `NO_INIT` and recreates its encoder pipeline when it changes.
- **Stale dims (3.H.2):** in `HwComposerBackend_v20::onHotplugReceived` / `getScreenSizes` config-change path, tear down and re-init `m_captureQueue` with new dims.

---

## 5. Test plan

Tests are added in dependency order. Each tier gates the next. **Note: as of 2026-07-28, none of these have run successfully — `screencap_enc_test` crashes before producing output, and the build itself does not pass.**

### Tier 0 — Build the thing (prerequisite)
1. Apply §4.F (move capture API into `libminisf.so`, drop the `droidmedia` include from `hwcomposer_backend_v20.cpp`, resolve the three `minisf_screen_capture_*` entry points via `android_dlsym`).
2. Build `libdroidmedia.so`, `libminisf.so`, `libgstdroid.so`, `qt5-qpa-hwcomposer-plugin`, and `screencap_enc_test` in the target SDK.
3. Pass criterion: all five build cleanly with no `droidmedia` reference in the QPA plugin's link line.

### Tier 1 — Fix the `MediaBuffer` crash; produce a decodable H.264 (unit)
4. Fix §3.C.4 (the `MediaBuffer` refcount crash). Two candidate fixes are listed; pick one based on whether `AsyncCodecSource`'s input-slot pool is reachable from `src->read()` (preferred) or fall back to `new CaptureInputBuffer` + a `drain()` that empties `mPending`.
5. Run `screencap_enc_test` on device (per `hwc-h264-test-notes-phase0.md` commands) with `meta_data=0` (copy mode — the path that Phase-0 says is accepted).
6. `ffprobe /tmp/screencap_test.h264` — confirm it's a valid H.264 stream with the expected resolution/duration/framerate.
7. `ffmpeg -i /tmp/screencap_test.h264 -frames:v 1 /tmp/frame.png && file /tmp/frame.png` — confirm the first frame decodes to a sensible PNG (color bars visible).
8. Pass criterion: `ffprobe` succeeds, the PNG shows the color-bar pattern, and the harness exits cleanly (no `CHECK_EQ(mRefCount, 0)` crash in logcat).
9. Add `droidmedia/tools/screencap_enc_test2.cpp`: same as the existing harness but with `N=300` and a `stop()` after 150 frames. Confirm no refcount crash and that the encoder cleanly returns all input buffers. Validates the fix holds under load.

### Tier 2 — Cross-process BufferQueue round-trip + `attachBuffer` probe (integration, no encoder)
10. Add `droidmedia/tools/screencap_bq_test.cpp`:
    - Process A (HWC side): `droid_media_screen_capture_init(640,480,&q)`; spawn a thread that `attachBuffer`s a hybris-allocated `GraphicBuffer` (written with a known pattern — frame number as pixel 0), `queueBuffer`s at 30 fps for 300 frames.
    - Process B (consumer side): `droid_media_screen_capture_consumer_new()`; `acquireBuffer` in a loop; `lock()`; verify pixel 0 matches the frame counter; `releaseBuffer`.
    - Pass criterion: 300 frames round-trip with correct pixel data, no `STALE_BUFFER_SLOT` storms (validates 3.D.1/3.D.2 fix), no deadlock on `stop()`.
11. This test is **also the 4.B.3 `attachBuffer` + cross-process gralloc-import probe** — if `lock()` fails in process B, 4.B.3 is dead and we fall back to 4.B.2 (fix the GPU blit). It does **not** require the HWC plugin or EGL — it exercises the Binder service + BufferQueue + `attachBuffer` in isolation.

### Tier 3 — `ScreenCaptureMediaSource` unit test (copy mode)
12. Add `droidmedia/tools/screencap_src_test.cpp`: instantiate `ScreenCaptureMediaSource` with a fake `IGraphicBufferConsumer` fed by a thread; run it through `droid_media_codec_create_encoder_raw` with `meta_data=0`; verify H.264 output decodes (Tier-1 steps 6-7). This is the production `read()` path in isolation.

### Tier 4 — HWC producer end (on-device, manual)
13. If 4.B.3 is the chosen path: enable `QPA_HWC_SCREENCAP=1` on device with a test UI (color bars / test pattern). Run a modified `droidscreencapsrc` that dumps the first dequeued capture buffer to a PPM (before encoding). Confirm the PPM is the full screen at full resolution — validates the `attachBuffer` path from the real HWC source buffer.
14. If 4.B.2 is the fallback: same PPM dump, but validate the GPU blit produces the full screen (validates the viewport fix 3.B.1 — currently it would be 1×1).

### Tier 5 — End-to-end GStreamer pipeline
15. `gst-launch-1.0 droidscreencapsrc target-bitrate=8000000 fps=30 ! h264parse ! matroskamux ! filesink location=/tmp/screen.mkv` for 30 s.
16. `ffprobe /tmp/screen.mkv`; `ffmpeg` extract a mid-stream frame; confirm it matches what's on screen.
17. Long-soak: 10-minute recording; monitor `output_queue` length (validates 3.E.2 backpressure) and memory.

### Tier 6 — Lifecycle / edge cases
18. Stop/restart the pipeline 50 times in a loop (validates 3.E.1 deadlock fix).
19. Rotate the screen mid-recording (validates 3.H.1/3.H.2 generation/dims fix).
20. Kill the GStreamer process mid-recording; confirm the HWC plugin's capture queue doesn't leak slots (validates `releaseBuffer` path).

### Tier 7 — SELinux / packaging
21. Build the RPM; install on a clean device; confirm `sailfish.screencap` registers (`audit2allow` to find the missing rules). Validates 3.G.1.

---

## 6. Updated phasing

Reordered so the confirmed blockers (build, crash) come first. No audio in v1.

| Phase | Deliverable | Days | Gated on |
|---|---|---|---|
| **0′** | Tier 0: move capture API into `libminisf.so` (§4.F); fix the build. | 0.5-1 | — |
| **1′** | Tier 1: fix §3.C.4 (`MediaBuffer` crash); make `screencap_enc_test` produce a *decodable* H.264 with `meta_data=0`. | 1-2 | 0′ |
| **2′** | Tier 2: cross-process BufferQueue round-trip + `attachBuffer` probe. Decide 4.B.3 vs 4.B.2 fallback based on the probe. Apply §4.A (dual-mode `ScreenCaptureMediaSource`), §4.C (lifecycle fixes), §4.E (droidscreencapsrc stop/backpressure). Tier 3. | 2-3 | 1′ |
| **3′** | Tier 4: HWC producer end — implement `attachBuffer` path in `hwcomposer_backend_v20.cpp` (4.B.3) **or** fix the GPU blit (4.B.2). PPM dump validation. | 1-2 | 2′ |
| **4′** | Tier 5: end-to-end `droidscreencapsrc` run on device. Tier 6: lifecycle/edge cases. | 2 | 3′ |
| **5′** | Polish: bitrate/I-frame tuning, resolution-change handling (§4.G), RPM packaging. Tier 7: SELinux. | 1-2 | 4′ |
| **6′ (stretch)** | True zero-copy via Codec2 `C2GraphicBlock` / `BufferItem` input, bypassing `MediaSource`/metadata entirely. Research + prototype only. | 5+ | 5′ |

**v1 (Phases 0′-5′):** ~7-12 days. Result: a working screen recorder with **one CPU copy** (RGBA `lock`+`memcpy`) into the HW encoder, no audio. **Not zero-copy**, but minimal-copy given this device's Codec2 constraints.

**Phase 6′:** the only realistic route to zero-copy on this device. The `MediaCodec`/`MediaSource` path is closed for zero-copy (Phase-0 confirmed); Codec2's native `C2GraphicBlock` input lets a producer hand a `GraphicBuffer` directly to the component without going through stagefright's `MediaBuffer` layer. This is a substantial research effort and should not block v1.

---

## 7. Open questions (for the user)

All five questions from the first draft are now answered (2026-07-28):

1. **v1 = one CPU copy.** ✅ Confirmed acceptable; zero-copy deferred to Phase-6′.
2. **QPA dependency direction.** ✅ Option (b) — move the capture API into `libminisf.so`. Also fixes the broken build.
3. **`attachBuffer` probe.** ✅ Try 4.B.3 in Phase-2 step 1 (Tier 2 test #10-11); fall back to 4.B.2 if cross-process `lock()` fails.
4. **Phase-0 crash reproduction.** ✅ Confirmed: `screencap_enc_test` produced zero output; the `MediaBuffer` refcount crash is the #1 blocker, not test-only. Tier 1 fixes it before anything else runs.
5. **Audio.** ✅ Out of scope for v1.

Remaining open items (not blocking v1, but worth tracking):

- **§3.B.4 / 4.B.3 interop risk:** whether hybris-allocated `GraphicBuffer`s can be (a) `eglCreateImageKHR`'d on the producer side (4.B.2 path) and (b) `lock()`'d in the consumer process after `attachBuffer`+`acquireBuffer` (4.B.3 path). Tier 2 settles this. If both fail, v1 falls back to a CPU `memcpy` on the producer side into a vendor-allocated buffer — still one copy, just on the other side of the BufferQueue.
- **§3.C.4 fix shape:** whether `AsyncCodecSource` exposes its input-slot pool to `src->read()` (preferred fix) or we have to manage our own `MediaBuffer` pool. Settled during Tier 1 implementation.
- **§3.H.1 generation counter:** whether resolution/hotplug changes actually happen in practice on this device (if the panel config is fixed at boot, the generation-counter work is unnecessary for v1). Settled during Tier 6 testing.

---

## 8. File-level change summary (what to edit)

Updated for the libminisf refactor (§4.F) and the chosen 4.B.3 path.

| File | Change | Issue |
|---|---|---|
| `droidmedia/screen_capture_mediasource.{h,cpp}` | Add `mMetadataMode`; mode-aware `read()` (copy path with `lock`+`memcpy`+`unlock`); `getFormat()` sets max-input-size/stride/slice-height; `Mutex`/`Condition` + `stop()` signal; own `ConsumerListener`; fix §3.C.4 `MediaBuffer` refcount (pool or `drain()`) | 3.A.1, 3.C.1, 3.C.2, 3.C.3, 3.C.4, 3.C.5, 4.A.1, 4.C.1 |
| `droidmedia/screen_capture_encoder.cpp` | Probe + set `meta_data`/`max_input_size` per probe result; expose used-mode | 3.A.1, 4.A.1 |
| `droidmedia/private.cpp` | Guard `releaseMediaBuffer(int)` for consumer-side wrapper; document/forbid the dead path | 3.D.1, 4.C.2 |
| `droidmedia/screen_capture.cpp` | Don't `connectListener` the dead listener for `ScreenCaptureMediaSource` use; all-or-nothing init; (4.B.3) configure `maxAcquiredBufferCount` ≤ 3 | 3.B.6, 3.D.2, 4.C.1, 4.B.3 |
| `droidmedia/screen_capture_service.{h,cpp}` | Add `getGeneration()`; atomic consumer replace | 3.H.1, 4.G |
| `droidmedia/libminisf.cpp` (or new `droidmedia/minisf_screen_capture.cpp`) | Add `minisf_screen_capture_init` / `_consumer_new` / `_get_dimensions` pass-through entry points | 3.F.1, 4.F.1 |
| `droidmedia/Android.mk` | Add the new `minisf_screen_capture.cpp` to `libminisf`'s `LOCAL_SRC_FILES` (it already has `libdroidmedia` in `LOCAL_SHARED_LIBRARIES` per exec2) | 4.F.3 |
| `qt5-qpa-hwcomposer-plugin/hwcomposer/hwcomposer_backend_v20.cpp` | Drop `#include <droidmedia/droidmedia.h>`; forward-declare `minisf_screen_capture_*`; resolve via `android_dlsym` (cached); rewrite `captureFrame` for 4.B.3 `attachBuffer` (or fix blit per 4.B.2 if fallback); `fence->wait(1000)`; instance-member FBO/program; re-init on config change | 3.B.1, 3.B.2, 3.B.3, 3.F.1, 3.H.2, 4.B.3, 4.D, 4.F.2, 4.G |
| `qt5-qpa-hwcomposer-plugin/hwcomposer/hwcomposer_backend.cpp` | Resolve `minisf_screen_capture_*` function pointers alongside `startMiniSurfaceFlinger` in `initLegacyHwComposerQuirks`; expose them to `HWC2Window` | 4.F.2 |
| `qt5-qpa-hwcomposer-plugin/hwcomposer/hwcomposer.pro` (+ `.spec`) | **No change** — `libminisf` is already loaded at runtime; no `droidmedia` build dep | 3.F.1, 4.F.2 |
| `gst-droid/gst/droidscreencapsrc/gstdroidscreencapsrc.c` | `flushing` flag in `stop()`/`create()`; cap `output_queue`; default to copy mode; `metadata-mode` property (default FALSE) | 3.E.1-3.E.4, 4.A.2, 4.E |
| droid-hal SELinux policy | `sailfish.screencap` type + allow rules | 3.G.1, 4.F.4 |
| `droidmedia/tools/screencap_enc_test.cpp` | Fix the `MediaBuffer` allocation so it doesn't crash; keep the dual-attempt (metadata first, copy fallback) | 3.C.4, Tier 1 |
| `droidmedia/tools/screencap_enc_test2.cpp` (new) | Refcount regression test (N=300, stop after 150) | Tier 1 |
| `droidmedia/tools/screencap_bq_test.cpp` (new) | Cross-process BufferQueue round-trip + `attachBuffer` probe | Tier 2 |
| `droidmedia/tools/screencap_src_test.cpp` (new) | `ScreenCaptureMediaSource` copy-mode unit test | Tier 3 |
