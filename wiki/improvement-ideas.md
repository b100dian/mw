# Screen recording — improvement ideas

Possible changes that are not planned yet. Each one says what to measure
before deciding.

## GPU-side wait for the display buffer's fence

**Status:** idea (2026-10-18). Not implemented, not measured.

**Today.** While a recording is attached, `HwComposerScreenCapture::captureFrame()`
(`qt5-qpa-hwcomposer-plugin/hwcomposer/hwcomposer_screencapture.cpp`) calls
`sync_wait()` on a `dup()` of the display buffer's acquire fence, for up to
250 ms. The fence signals when the GPU has finished lipstick's frame, so
lipstick's render thread sits idle for whatever GPU work is still pending
after the primary `eglSwapBuffers()` returned. Without a recording, nothing
waits. `present()` waits on the CPU itself only with `QPA_HWC_SYNC_BEFORE_SET`.

**Idea.** Let the GPU wait instead:
- `EGL_ANDROID_native_fence_sync` turns the fence fd into an `EGLSyncKHR`;
- `EGL_KHR_wait_sync`: `eglWaitSyncKHR()` adds a dependency to the capture
  context's command stream and returns at once. Commands submitted after it
  do not run until the fence signals. On Adreno the kernel driver (KGSL)
  holds the batch; other GPUs put a wait into the command ring.

Like the wait, the quad draw (`glDrawArrays()`) is only recorded on the CPU and
submitted at the encoder swap. Lipstick's next frame then queues behind it.
The encoder surface's swap gives its queued buffer an acquire fence that
covers the draw, and the encoder waits on that, so the order stays correct
with no CPU wait.

**What it changes.**
- The render thread no longer idles until lipstick's frame is done; CPU and
  GPU overlap again, as they do without a recording.
- The latency of each captured frame is unchanged: the work still runs in the
  same order.
- If lipstick is GPU-bound, the gain is smaller.
- A fence that never signals stalls the GPU instead of failing the session
  after 250 ms. The display waits on the same fence, so the screen would be
  stuck anyway.

**Sketch.** In `submit()`, with the capture context current, before `render()`:

```cpp
// Let the GPU wait for the compositor's frame instead of blocking here.
if (fenceFd >= 0) {
    const EGLint attribs[] = { EGL_SYNC_NATIVE_FENCE_FD_ANDROID, fenceFd, EGL_NONE };
    EGLSyncKHR sync = m_createSync(m_eglDisplay, EGL_SYNC_NATIVE_FENCE_ANDROID, attribs);
    if (sync == EGL_NO_SYNC_KHR)
        return false;                    // or fall back to sync_wait()
    fenceFd = -1;                        // EGL owns the fd now
    m_waitSync(m_eglDisplay, sync, 0);   // queued on the GPU; returns at once
    m_destroySync(m_eglDisplay, sync);   // the wait is already queued
}
```

- Resolve `eglCreateSyncKHR`, `eglWaitSyncKHR` and `eglDestroySyncKHR` through
  `eglGetProcAddress`, like the other extensions.
- Check both extension names in `eglQueryString(display, EGL_EXTENSIONS)`,
  log the result once in `create()`, and keep `sync_wait()` as the fallback.
- `captureFrame()` hands the fence to `submit()` instead of waiting on it.
- About 30 lines in `hwcomposer_screencapture.{h,cpp}`.

**Measure first.** Time the current `sync_wait()` in `captureFrame()`
(`monotonicNs()` before and after, logged as a running average while
recording). If it is usually under a millisecond, the extension is not worth
the code and the device risk.

**Risks.**
- libhybris must pass the calls and the fd through to the vendor EGL. Fds are
  kernel objects, so bionic and glibc sharing one should work; untested.
- Adreno normally exposes both extensions; confirm on the device.

**Unchanged.** Nothing fences the capture's GPU read of the display buffer
against lipstick reusing that buffer a frame or two later. It relies on the
buffer rotation (3 buffers) and on the GPU running work in submission order.
