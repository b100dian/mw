# HWC H.264 Encoding — Execution Log 2: Build Fixes (Linker & Compile Errors)

**Date:** 2026-07-26
**Plan Reference:** `wiki/hwc-h264-encoding-revised.md`
**Previous log:** `wiki/hwc-h264-exec1.md`

## Summary

Multiple build errors encountered during the droidmedia compilation. Three categories of fixes applied:

1. **Linker error** (`libminisf.so` undefined `IScreenCaptureService` symbol)
2. **Compile errors** in `screen_capture_mediasource.cpp` (wrong includes, wrong `releaseBuffer` signature)
3. **Test harness** `releaseBuffer` signature fix

---

## Fix 1: `IScreenCaptureService` undefined symbol (linker)

### Error

```
ld.lld: error: undefined symbol: _ZN7android21IScreenCaptureServiceC2Ev
>>> referenced by ... libminisf.o:(_ZN7android13BinderServiceINS_20ScreenCaptureServiceEE7publishEbi)
```

### Root cause

`IMPLEMENT_META_INTERFACE(ScreenCaptureService, ...)` in `screen_capture_service.cpp` defines `IScreenCaptureService::IScreenCaptureService()` (the base class constructor). That object file is compiled into **`libdroidmedia.so`**.

But `libminisf.cpp` (compiled into **`libminisf.so`**) calls `ScreenCaptureService::instantiate()` → `BinderService::publish()` → `new ScreenCaptureService()` → needs the base-class constructor.

`libminisf` did **not** link against `libdroidmedia`. No circular dependency exists (libdroidmedia does not depend on libminisf).

### Fix

**File:** `mw/droidmedia/Android.mk` — Added `libdroidmedia` to `libminisf`'s `LOCAL_SHARED_LIBRARIES`:

```makefile
# Before:
LOCAL_SHARED_LIBRARIES := libutils \
                          libbinder \
                          ...

# After:
LOCAL_SHARED_LIBRARIES := libdroidmedia \
                          libutils \
                          libbinder \
                          ...
```

The `minisfservice` executable (which uses `minisf.cpp`, not `libminisf.cpp`) does NOT need this fix — it doesn't reference `ScreenCaptureService`.

### No circular dependency

- `libdroidmedia` depends on: `libgui`, `libbinder`, `libstagefright`, etc. (not `libminisf`)
- `libminisf` now depends on: `libdroidmedia` (new), `libgui`, `libbinder`, etc.

Safe to add.

---

## Fix 2: Compile errors in `screen_capture_mediasource.cpp`

### Error A: `'gui/Fence.h' file not found`

**Fix:** Changed `#include <gui/Fence.h>` → `#include <ui/Fence.h>`. On A14, `Fence.h` lives in `libui`, not `libgui`.

### Error B: `releaseBuffer` parameter mismatch

```cpp
// ERROR — 3rd param `false` interpreted as EGLDisplay
mConsumer->releaseBuffer(slot, frameNumber, false, Fence::NO_FENCE, NULL);
```

The `IGraphicBufferConsumer::releaseBuffer` signature is:
```cpp
releaseBuffer(int slot, int64_t frameNumber, EGLDisplay display, EGLSyncKHR fence, const sp<Fence>& releaseFence);
```

**Fix:** Changed to:
```cpp
mConsumer->releaseBuffer(mSlot, mFrameNumber,
                         EGL_NO_DISPLAY, EGL_NO_SYNC_KHR,
                         Fence::NO_FENCE);
```

And added `#include <EGL/egl.h>` for the `EGL_NO_DISPLAY` / `EGL_NO_SYNC_KHR` constants.

---

## Fix 3: Test harness `screencap_enc_test.cpp` — same `releaseBuffer` issue

**File:** `mw/droidmedia/tools/screencap_enc_test.cpp` line 175-176

Same signature error in the `TestMediaSource::releaseBuffer()` method:

```cpp
// Before:
mC->releaseBuffer(it->second, mFrames[mb],
                  false, Fence::NO_FENCE, nullptr);

// After:
mC->releaseBuffer(it->second, mFrames[mb],
                  EGL_NO_DISPLAY, EGL_NO_SYNC_KHR,
                  Fence::NO_FENCE);
```

---

## Fix 5: `screen_capture_encoder_*` undefined symbols in gst-droid link

### Error

```
undefined reference to `screen_capture_encoder_stop'
undefined reference to `screen_capture_encoder_destroy'
undefined reference to `screen_capture_encoder_start'
undefined reference to `screen_capture_encoder_new'
```

### Root cause

The four `screen_capture_encoder_*()` functions live in the Android-side `libdroidmedia.so` and are declared in `screen_capture_encoder.h`. The gst-droid meson build links against the **hybris-side** `libdroidmedia.a` (the static library built from `hybris.c`), which is a shim that uses `dlopen`/`dlsym` to resolve symbols from the Android `libdroidmedia.so` at runtime.

This shim only works for functions explicitly listed in `hybris.c` via the `HYBRIS_WRAPPER_*` macros. The `screen_capture_encoder_*` functions were not listed, so the linker saw them as unresolved external symbols.

### Fix

**File:** `mw/droidmedia/hybris.c`

1. Added `#include "screen_capture_encoder.h"` at the top (alongside other includes)

2. Added hybris wrappers for all 4 functions. Three use existing macros:
   ```c
   HYBRIS_WRAPPER_0_1(ScreenCaptureEncoder*,screen_capture_encoder_destroy)
   HYBRIS_WRAPPER_1_1(bool,ScreenCaptureEncoder*,screen_capture_encoder_start)
   HYBRIS_WRAPPER_0_1(ScreenCaptureEncoder*,screen_capture_encoder_stop)
   ```

3. `screen_capture_encoder_new` has 8 parameters — no existing macro supports that many, so it uses a manually-written wrapper:
   ```c
   ScreenCaptureEncoder *
   screen_capture_encoder_new(void *queue, int width, int height,
                             int colorFormat, int bitrate, int fps,
                             const ScreenCaptureEncoderCallbacks *callbacks,
                             void *cbUser)
   {
       static ScreenCaptureEncoder *(*_sym)(void*, int, int, int, int, int,
                                            const ScreenCaptureEncoderCallbacks*,
                                            void*) = NULL;
       if (!_sym)
           _sym = __resolve_sym("screen_capture_encoder_new");
       return _sym(queue, width, height, colorFormat, bitrate, fps,
                   callbacks, cbUser);
   }
   ```

This follows the same pattern as `droid_media_camera_set_torch_mode()` at L277 of `hybris.c`.

---

## Fix 4: `enc->mLooper->stop()` called before allocation

**Note:** This was already fixed in the initial implementation (the `screen_capture_encoder.cpp` creates the looper before the error-return path touches it), but is documented here for completeness since it was mentioned as a previous blocker.

**Current init order in `screen_capture_encoder_new()`:**
```
1. Parse/validate args
2. Create looper (line 181)
3. Create media source (line 186)
4. Create raw encoder (line 190) — if this fails, looper->stop() is safe because looper was created
5. Allocate ScreenCaptureEncoder struct
```

This order ensures the looper exists before any error path calls `looper->stop()`.

---

## Files modified in this execution step

| File | Change | Rationale |
|------|--------|-----------|
| `mw/droidmedia/Android.mk` | Added `libdroidmedia` to `libminisf`'s `LOCAL_SHARED_LIBRARIES`; added `screencap_enc_test` BUILD_EXECUTABLE target | Resolve linker undefined symbol; enable Phase-0 test harness build |
| `mw/droidmedia/screen_capture_mediasource.cpp` | `<gui/Fence.h>` → `<ui/Fence.h>`; `releaseBuffer` signature fix; added `<EGL/egl.h>` | Compile errors on A14 |
| `mw/droidmedia/tools/screencap_enc_test.cpp` | `releaseBuffer` signature fix; added missing includes (`private.h`, `map`, `Fence`, `Rect`, `Thread`, `Timers`, `BufferItem`) | Test harness correctness + Android build compatibility |
| `mw/droidmedia/hybris.c` | Added `#include "screen_capture_encoder.h"`; added hybris wrappers for `screen_capture_encoder_new/destroy/start/stop` | gst-droid linker errors — encoder symbols were missing from hybris shim |

---

## Next steps

1. **Rebuild `libdroidmedia.so`** — verify no further compile or link errors
2. **Rebuild `libminisf.so`** — now that it links against libdroidmedia, the symbol should resolve
3. **Build `minisfservice`** and `minimediaservice` — should be unaffected
4. **On-device Phase 0 test** — cross-compile and run `screencap_enc_test` to validate `AndroidOpaque` acceptance
5. **Build gst-droid** — `libgstdroid.so` with the new `droidscreencapsrc` element
6. **Build HWC plugin** — verify `droidmedia/droidmedia.h` and `<gui/IGraphicBufferProducer.h>` are reachable