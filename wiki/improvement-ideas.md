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

## Repeat the last frame on an idle screen

**Status:** idea (2026-11-09). Not implemented, not measured.

**Today.** Lipstick sends a frame only when the screen changes, so an idle
screen produces no frames and the PTS keep the gap (README, "Known limits").
An IDR on an idle screen needs `requestFrame`, which makes lipstick render
one.

**Idea.** An optional element property, for example `repeat-after-ms`
(default 0, off), that sets `repeat-previous-frame-after` (an int64 in µs,
`KEY_REPEAT_PREVIOUS_FRAME_AFTER`) in `DroidMediaScreenCapture::configure()`.
The encoder's input surface does the rest: `CCodec` turns the key into a
minimum fps (`CCodec.cpp:983`), and `GraphicBufferSource` re-submits the
last buffer at that interval, at most 10 times (`kRepeatLastFrameCount`)
after each new frame (`repeatLatestBuffer_l()` in
`frameworks/av/media/module/bqhelper/GraphicBufferSource.cpp`). Miracast gets
a steady rate the same way with its own `RepeaterSource`; see
[`android-screen-encoders.md`](android-screen-encoders.md).

**What it changes.**
- A receiver that expects a steady rate (Android Auto, an RTP player) gets
  frames for a while after the screen goes idle, and the encoder refines a
  static picture instead of leaving the last change's artifacts.
- The idle gaps in the PTS fill up, which changes the output contract
  ("idle periods as gaps"), so the default stays off.
- After 10 repeats the stream is idle again, so `requestFrame` stays for an
  IDR on a long-idle screen.
- Bitrate rises while the screen is idle, by up to 10 frames per change.

**Plumbing.** `configure()` runs inside `droid_media_screen_capture_new()`,
before any setter, so the value has to come with the meta or `configure()`
has to move into `start()`. `DroidMediaCodecEncoderMetaData` is shared with
gst-droid's encoders; a setter next to `droid_media_screen_capture_set_target()`, with
`configure()` moved into `start()`, keeps that struct unchanged.

**Measure first.** What the Android Auto head unit and the RTP receiver do
with idle gaps. If they cope, this isn't needed.

**Risks.** The hardware encoder's input surface must honour the key. Check
on the device that an idle screen yields 10 extra access units per change.

## `MediaCodecSource` with `FLAG_USE_SURFACE_INPUT`

**Status:** considered (2026-11-09), not adopted. Recorded so it isn't
proposed again without these points. The background is in
[`android-screen-encoders.md`](android-screen-encoders.md).

**Idea.** `StagefrightRecorder` encodes a Surface through `MediaCodecSource`
with `FLAG_USE_SURFACE_INPUT`
(`frameworks/av/media/libstagefright/MediaCodecSource.cpp`). It would replace
`DroidMediaScreenCapture`'s `configure()`, `run()`, the wait in `finish()`
and the `request-sync` call with `initEncoder()`, async output with
`read()`, `stop()` and `requestIDRFrame()`.

**Why not.**
- **Lost output at end of stream.** `signalEOS()` releases every output
  buffer the reader hasn't taken yet (`MediaCodecSource.cpp:655`), and
  `read()` reports the end at once. `run()` hands every access unit to the
  callback before the EOS flag; `droidscreencapsrc` relies on that.
- **Stop on an idle screen.** The recorder's stop sets `stop-time-us`. With a
  stop time set, the input surface sends end of stream only when a frame at
  or after it arrives (`GraphicBufferSource.cpp:1438`). After the detach no
  frame comes, so the stall timer fires after up to 1 s
  (`kMaxStopTimeOffsetUs`) and the encoder is released without a drain.
  Without a stop time it behaves like `finish()`, and `DETACH_GRACE_MS` is
  still needed.
- **Codec choice.** Only `FLAG_PREFER_SOFTWARE_CODEC`; no hardware-only
  selection.
- **Errors.** `CB_ERROR` becomes end of stream; the separate `error`
  callback is lost.
- **No reuse in droidmedia.** On Android 7 and later droidmedia encodes
  through `AsyncCodecSource`, which has no Surface input and reaches
  `MediaCodecSource` only for camera `video/raw`
  (`droidmedia/AsyncCodecSource.cpp:130`). The `DroidMediaCodec` loop starts
  in `droid_media_codec_queue()` (`droidmediacodec.cpp:977`), and
  `droid_media_codec_drain()` drains the input `Source`. Reusing it would
  grow the droidmedia diff.
- It solves none of the session work: the producer handoff, generations,
  `requestFrame`, the detach.

**Usable without it.** Suspend (`drop-input-frames`, for example on screen
lock) and frame repeat (above) are plain `MediaCodec` parameters.
`screenrecord` also uses plain `MediaCodec` with its own output loop.
