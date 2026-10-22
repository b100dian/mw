# lipstick2vnc's `lipstick_recorder` vs. our QPA capture

Question: does the way lipstick2vnc gets frames from lipstick overlap with
`HwComposerScreenCapture` in qt5-qpa-hwcomposer-plugin (`hwenc`), and could
it replace it?

## How lipstick2vnc gets frames

- It uses the Wayland protocol `lipstick_recorder`
  (`lipstick2vnc/src/protocol/lipstick-recorder.xml`). The client must be in
  the `privileged` group (`lipstick/src/compositor/lipstickrecorder.cpp:106-120`).
- The client allocates **wl_shm** buffers (ARGB, display size) in `/tmp`
  (`lipstick2vnc/src/buffer.cpp`). It sends `record_frame(buffer)` for
  **one** frame and has to ask again after every `frame` event
  (`lipstick2vnc/src/recorder.cpp:109-154`).
- In lipstick, `QQuickWindow::afterRendering` →
  `LipstickCompositor::readContent()` →
  `LipstickRecorderManager::recordFrame()` runs **`glReadPixels` of the whole
  window into the shm buffer**, on the render thread, before the swap
  (`lipstick/src/compositor/lipstickcompositor.cpp:121`,
  `lipstickrecorder.cpp:65-92`). Only shm buffers are accepted: anything
  else gets `failed(bad_buffer)`.
- The client then rotates, flips and scales a `QImage` on the CPU
  (`lipstick2vnc/src/screentovnc.cpp:470-526`).

## Where it overlaps with our work

- Both hook "lipstick has just rendered a frame" and send nothing while the
  screen is idle. Both report the y-inverted orientation.
- `lipstick_recorder.repaint` is the "request a repaint on attach" item that
  the README lists as a follow-up.

## Why it can't easily replace our work

1. **CPU readback instead of zero copy.** Each frame is a synchronous
   `glReadPixels` of 1080x2520x4 ≈ 10.9 MB on lipstick's render thread. At
   60 fps that is about 650 MB/s, and the GPU pipeline stalls every frame.
   That is the `glReadPixels` approach already rejected
   (`hwc-encoder-discussion1.md` §5, `hwc-h264-encoding-revised.md:627`).
   Ours draws the HWC buffer through an EGLImage straight into the encoder
   Surface, so no pixels go through the CPU.
2. **The encoder can't take shm.** To get from RGBA shm to the HW AVC
   encoder we'd need ByteBuffer input plus an RGBA→NV12 conversion on the
   CPU, or a GPU re-upload. That gives back the copies we saved, and it
   needs a new droidmedia input path. The Surface-input path we already have
   doesn't fit.
3. **One frame per round trip.** The client has to send `record_frame` again
   after every frame event, so frames are lost while it's busy. Ours sends
   every frame lipstick renders, with a `CLOCK_MONOTONIC` PTS from the
   compositor. `lipstick_recorder` gives a millisecond `gettimeofday` time
   instead.
4. **The protocol can't carry an encoder Surface.** Extending it (for
   example a v2 that takes Android/wlegl buffers dequeued from the encoder's
   producer) would rebuild our design inside lipstick and the protocol. It
   would also need lipstick changes and still need the libminisf /
   `sailfish.screencap` bridge to get the producer. That's more work, not
   less.
5. **auto-goal1 doesn't fit.** Option A (letterbox at the encoder's size)
   needs a GPU draw at codec resolution, which our QPA quad already does.
   Option B2 renders into a `VIRTUAL` session from a second compositor, and
   `lipstick_recorder` has no part in that.

## What we could take from it

- **A repaint on attach:** lipstick already does this through
  `m_window->update()` (`lipstickrecorder.cpp:175-181`). Our QPA plugin
  can't reach the QQuickWindow easily, but
  `QWindowSystemInterface::handleExposeEvent` or a `requestUpdate()` on the
  platform window would serve the same purpose.
- **Moving the hook out of the QPA:** we could draw in lipstick's
  `afterRendering` instead of `HWC2Window::present()`, so we wouldn't need a
  plugin fork. But at that point the frame is only in the default
  framebuffer, so we'd have to copy it into a texture before switching to
  the encoder's EGL context. That's an extra GPU copy compared with the HWC
  buffer import, and it needs a patch to lipstick itself. Not recommended.

## Conclusion

They overlap in **where** they hook (after each lipstick frame), but not in
**how** frames get out. `lipstick_recorder` is a CPU path (`glReadPixels`
into shm), fine for VNC at low frame rates. Using it as the H.264 source
would bring back the GPU stall and CPU copies the current design avoids, and
it would need a new encoder input path. Keep the QPA implementation. A
possible small follow-up is to borrow the "repaint on attach" idea.

## Measuring it (not done)

On the device, run lipstick2vnc with a VNC client connected and watch
lipstick's frame time and CPU (`top -H -p $(pgrep lipstick)`). Compare with
a `droidscreencapsrc fps=60` session to show the cost of the readback.

The lipstick tree checked out under `mw/lipstick` is the open-source one
(`28f86bd5`). The lipstick that ships on the device may differ in detail.
