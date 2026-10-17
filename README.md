# Hardware H.264 screen recording for Sailfish OS

`droidscreencapsrc` is a GStreamer source that records the Sailfish display
with the phone's hardware H.264 encoder. The encoder's input Surface is handed
to the compositor. On every screen update, lipstick draws the display buffer
it has just presented into that Surface as one textured quad. Pixels never
pass through the CPU and nothing is encoded while the screen is idle. The
output is an H.264 elementary stream with timestamps, ready for a file, a
container or a network sink.

Developed and tested on the Sony Xperia 5 IV (pdx224, 1080x2520, Sailfish OS
5.1, Android 14 base). The next goal, Android Auto resolutions, is planned in
[`wiki/auto-goal1.md`](wiki/auto-goal1.md).

## Repositories

Three submodules carry the change, each on branch `hwenc`:

| Submodule | Change | `hwenc` tip | `hwenc-gate4` tag | Upstream |
|---|---|---|---|---|
| `droidmedia` | encoder API, `sailfish.screencap` service, libminisf bridge | `21a2cbf` | `29762d5` | `sailfishos/droidmedia` (`master`) |
| `gst-droid` | `droidscreencapsrc` element | `b85836e` | `6688db2` | `sailfishos/gst-droid` (`master`) |
| `qt5-qpa-hwcomposer-plugin` | draws the display into the encoder Surface | `643f56a` | `3f6d3ea` | `mer-hybris/qt5-qpa-hwcomposer-plugin` (`master`) |

- `hwenc` is a series of small cleanup commits on top of the code that passed
  Gate 4. It shows `git diff master..hwenc` as the reviewable change, and is
  meant to be squashed per repository before it goes upstream.
- `hwenc-gate4` is a local tag on the pre-cleanup head that was tested on the
  device (see [Rollback](#rollback)).
- The forks live at `github.com/b100dian/<repo>`.
- The `libhybris` submodule is not part of the set: stock libhybris works.

## Components

```
 recorder process (gst-launch ...)                minisfservice (droid-hal-init, Android)
 +-----------------------------------------+      +-------------------------------------+
 | droidscreencapsrc (gst-droid, Linux)    |      | MiniSurfaceFlinger                  |
 |   start/finish/stop      ^ AUs + PTS    |      | ScreenCaptureService                |
 |   v                      |              |      |   "sailfish.screencap"              |
 | libdroidmedia via libhybris             | reg/ |   {producer, w, h, fps, generation} |
 |   DroidMediaScreenCapture  -------------+unreg>|                                     |
 |   MediaCodec HW AVC --> output thread   |      +------------------^-------|----------+
 |   input Surface = IGraphicBufferProducer|        registerListener |       | sessionChanged
 +-------------------^---------------------+          getProducer    |       | (oneway)
                     | queueBuffer over Binder (GPU buffers only)    |       v
 lipstick -----------+-----------------------------------------------+-------+----------
 | Qt scene graph -> eglSwapBuffers(primary HWC window)
 |   HWC2Window::present(): HwComposerScreenCapture keeps buffer + dup(acquire fence)
 |   swap returned -> HwComposerScreenCapture::captureFrame()
 |     wait fence -> EGLImage(HWC buffer) -> 1 textured quad (y-flip, rotate 0/90/270)
 |     -> eglPresentationTimeANDROID(CLOCK_MONOTONIC) -> eglSwapBuffers(encoder Surface)
 +----------------------------------------------------------------------------------------
```

- **`droidscreencapsrc`** (`gst-droid/gst/droidscreencapsrc/`) owns one
  `DroidMediaScreenCapture` per run and turns its callbacks into GstBuffers.
- **`DroidMediaScreenCapture`** (`droidmedia/droidmediascreencapture.{h,cpp}`)
  configures the hardware AVC encoder with Surface input. It registers the
  Surface's producer with the service and runs the output thread.
- **`sailfish.screencap`** (`droidmedia/screen_capture_service.{h,cpp}`) is
  hosted by `minisfservice`. It holds one session; every registration gets a
  new generation, and the session ends when the recorder unregisters or dies.
- **libminisf** (`droidmedia/minisf_screen_capture.cpp`) gives the compositor
  four C entry points. It subscribes to the service and keeps the session the
  service pushes, so a session query is a local read. While the service is
  missing, it looks it up with `checkService()`, at most every 250 ms, and
  never blocks.
- **`HwComposerScreenCapture`**
  (`qt5-qpa-hwcomposer-plugin/hwcomposer/hwcomposer_screencapture.{h,cpp}`)
  runs inside lipstick when `QPA_HWC_SCREENCAP=1` and draws into the
  session's Surface.

## Session sequence

```
 recorder (droidscreencapsrc)    minisfservice           lipstick (QPA)
        |                             |<-- registerListener ---|  once, on lipstick's first frame
        |                             |--- no session -------->|
 start: MediaCodec configure, createInputSurface, start        |
        |-- registerProducer -------->| generation N           |
        |                             |--- sessionChanged ---->|  N, w x h @ fps (oneway)
        |                             |                        |  at the next frame:
        |                             |                        |  size == display    -> rotation 0
        |                             |                        |  size == transpose  -> rotation 90/270
        |                             |                        |  otherwise          -> reject N (logged)
        |<===== frames: queueBuffer on the encoder Surface ====|  after each primary swap
        |  output thread -> data_available(AU, ts)             |
        |                             |                        |
 EOS (gst-launch -e / Ctrl-C):        |                        |
 finish: unregisterProducer(N) ------>| session ended          |
        |                             |--- sessionChanged ---->|  no session: at the next
        |  100 ms detach grace        |                        |  frame, detach and destroy
        |                             |                        |  the EGL surface
        |  signalEndOfInputStream                              |
        |  drain to the codec's EOS -> signal_eos -> GST_FLOW_EOS
        |  stop codec                                          |
```

If the recorder dies instead, the service's death notification ends the
session and tells lipstick, which detaches at its next frame. If
`minisfservice` dies, lipstick drops the session and subscribes again once
the service is back.

## Per-frame path in lipstick

1. The Qt scene graph renders and calls `eglSwapBuffers()` on the primary HWC
   window.
2. Inside that swap, `HWC2Window::present()` hands the buffer and a `dup()` of
   its acquire fence to `HwComposerScreenCapture::bufferPresented()`. This
   happens before `set_client_target()`, which takes the fence.
3. When the swap has returned, `HwComposerBackend_v20::swap()` calls
   `captureFrame()`. Capture never runs inside `present()`, because EGL must
   not be re-entered there.
4. `captureFrame()`:
   - checks the session that libminisf keeps (no Binder call), then
     attaches, detaches or rejects. Attaching makes one Binder call, to get
     the Surface's producer;
   - waits up to 250 ms for the fence;
   - switches to its private EGL context with a scoped guard;
   - imports the buffer as an EGLImage texture (cached per buffer);
   - draws one quad with the y-flip and the rotation;
   - sets `eglPresentationTimeANDROID(CLOCK_MONOTONIC now)`, swaps, and
     restores lipstick's context.
5. A failed fence wait, render or swap, or a swap longer than 250 ms, gives
   up on that generation. Lipstick carries on, and the next recorder session
   attaches normally.

## `droidscreencapsrc` output

- **Caps:** `video/x-h264, stream-format=byte-stream, alignment=au`, with
  `width`, `height` and `framerate=fps/1`. The framerate is nominal.
- **Buffers:** one access unit per buffer. IDR frames clear
  `GST_BUFFER_FLAG_DELTA_UNIT`.
- **SPS/PPS** are in-band on every IDR, and never sent as a buffer of their
  own: `h264parse` would turn a header-only buffer into an access unit
  without a PTS, which `qtmux` rejects. A client can join mid-stream at the
  next IDR (one per second).
- **PTS:** start at 0 with the first access unit, are monotonic, and keep
  idle periods as gaps rather than repeated frames. DTS is unset.
- **Duration:** unset. Each access unit is pushed as soon as the encoder
  delivers it, so a live viewer gets the last change before an idle period
  at once. `h264parse` sets a nominal duration, and muxers take sample
  durations from the next PTS.
  - The cost is the tail: an MP4 ends one nominal frame after the last
    screen change, not when the recording stopped.
- **EOS:** the element intercepts EOS in `send_event()`. It withdraws the
  Surface, signals end of input and drains the encoder before returning EOS,
  so no access unit is lost (the 100 ms detach grace plus the drain).
- **Overload:** a bound of 30 frames or 8 MiB. When it's exceeded, queued
  access units are dropped up to the next IDR, with one warning per episode.
  A repeated PTS is dropped; a regressing PTS is an error.
- **Rank:** `GST_RANK_NONE`. The element is only used when named.

## Configuration

Capture is enabled in lipstick only, through a systemd drop-in:

```ini
# /etc/systemd/user/lipstick.service.d/51-screencap.conf
[Service]
Environment=QPA_HWC_SCREENCAP=1
# Optional, default 270 (camera key up on the Xperia 5 IV):
# Environment=QPA_HWC_SCREENCAP_LANDSCAPE_ROTATION=90
```

- Don't use `/var/lib/environment/compositor/`: the encryption ask-password UI
  reads it too.
- Without `QPA_HWC_SCREENCAP`, the plugin behaves exactly like upstream: it
  never loads libminisf.
- Builds from `hwenc-gate4` also need `QPA_HWC_SCREENCAP_SOURCE=1` and
  `QPA_HWC_SCREENCAP_FLIP_Y=1`. The current tip ignores both.

Element properties:
- `width`, `height` (required): the display size, or its transpose for
  landscape (`2520x1080` on this phone).
- `target-bitrate` (default 8000000).
- `fps` (default 60, at most 120): the encoder's nominal frame rate and the
  caps framerate. Lipstick sends every frame it renders, so it should match
  the display refresh rate.

## Build and deploy

General build notes are in [`wiki/building.md`](wiki/building.md). The four
packages are a matched set: the API and the Binder interface changed together.

1. **droidmedia, Android side.** In the HADK `croot`:
   `make libdroidmedia libminisf minisfservice screencap_surface_capture_test`,
   then the droidmedia RPM as usual:
   `rpm/dhd/helpers/build_packages.sh -b hybris/mw/droidmedia`. It ships
   `libdroidmedia.so`, `libminisf.so`, `minisfservice` and
   `screencap_surface_capture_test`.
2. **droidmedia-devel**, which gst-droid needs (PlatformSDK):
   `rpm/dhd/helpers/build_packages.sh -b hybris/mw/droidmedia -s rpm/droidmedia-devel.spec`.
3. **gst-droid:** `rpm/dhd/helpers/build_packages.sh -b hybris/mw/gst-droid`.
4. **qt5-qpa-hwcomposer-plugin:**
   `rpm/dhd/helpers/build_packages.sh -b hybris/mw/qt5-qpa-hwcomposer-plugin`.
   It has no droidmedia build dependency.

Install all four (`droidmedia`, `droidmedia-devel`, `gstreamer1.0-droid`,
`qt5-qpa-hwcomposer-plugin`), set up the drop-in, and **reboot**. That
restarts `minisfservice` with the new service, and lipstick with the new
plugin.

The service is registered by `minisfservice` for the first time. If
`droidscreencapsrc` reports that `sailfish.screencap` is not running, check
that `minisfservice` was restarted after the install (`pgrep -a
minisfservice`), then look for SELinux denials with `logcat -d | grep avc`.
The service manager logs them to logcat, not to `dmesg`.

### Rollback

`git checkout hwenc-gate4` in the three submodules, then rebuild and redeploy
that set, with the extra drop-in variables listed under
[Configuration](#configuration).

## Usage

```sh
# Raw H.264 (portrait; use width=2520 height=1080 for landscape)
gst-launch-1.0 -e droidscreencapsrc width=1080 height=2520 target-bitrate=8000000 fps=60 ! \
  h264parse ! filesink location=/tmp/screen.h264

# MP4
gst-launch-1.0 -e droidscreencapsrc width=1080 height=2520 target-bitrate=8000000 fps=60 ! \
  h264parse config-interval=-1 ! video/x-h264,stream-format=avc,alignment=au ! \
  qtmux ! filesink location=/tmp/screen.mp4

# Element log: GST_DEBUG=droidscreencapsrc:4
# Without GStreamer (droidmedia only):
/usr/libexec/droid-hybris/system/bin/screencap_surface_capture_test 1080 2520 8000000 30 5 /tmp/t.h264
```

Always pass `-e` when recording to a file. On Ctrl-C, `gst-launch` then sends
EOS, which makes the element drain the encoder and the muxer finish the file.

Streaming scripts in [`scripts/`](scripts):

- **TCP, raw Annex B** (tested): run `sharing-tcp.sh` on the phone (60 fps,
  port 5000) and `PHONE_IP=... receiving-tcp.sh` (ffplay) on the host. There
  are no timestamps or frame boundaries on the wire: idle gaps collapse in
  the player, and ffplay shows a frame only once the next one starts.
- **RTP** (not yet tested): `sharing-rtp.sh` with `receiving-rtp.sh` or
  `screen.sdp`. Before using them:
  - set `udpsink host=` in `sharing-rtp.sh` to the receiver's address;
  - align the ports (`sharing-rtp.sh` and `receiving-rtp.sh` use 5001,
    `screen.sdp` uses 5000).

The commands for VLC and MPEG-TS receivers are in
[`wiki/hwc-h264-exec4.md`](wiki/hwc-h264-exec4.md) §13.

## Status

**Passed on the device with the `hwenc-gate4` build (2026-09-27 to 09-29):**
- Portrait 1080x2520 recording: High profile; sparse PTS with idle gaps
  preserved; EOS drained in about 0.5 s; 0 drops at 8 Mbit/s.
- Landscape 2520x1080 (rotation 270): upright, not stretched.
- MP4 through `qtmux`: valid per `ffprobe`, gaps preserved.
- Raw Annex B over TCP at 60 fps, played live on a host.
- Stock libhybris is enough.

**Passed on the device with the cleaned-up `hwenc` tip (2026-10-15,
gst-droid at `40d446a`):**
- `gst-inspect-1.0`: properties, rank none.
- Portrait and landscape recordings, raw and MP4; live over TCP.
- Portrait, landscape and portrait again in one lipstick run (Gate 4.3).
- Recorder killed with `kill -9`: the session ends and the next one works.
- Lipstick without `QPA_HWC_SCREENCAP`, the droidmedia-only tool, and camera
  recording.

**Passed on the device with gst-droid `3a7e560` (2026-10-16):** live over TCP
at `fps=120`, which drops no frame on this 60 Hz display.
After typing, the view shows the last change at once.

**Not yet run on the device:**
- qt5-qpa-hwcomposer-plugin `643f56a` (every frame sent, at any fps);
- push-mode session updates (uncommitted): libminisf subscribes to
  `sailfish.screencap` instead of polling it, and the detach grace is 100 ms
  instead of 500 ms. The wiki logs describe the polling design;
- the RTP proof;
- slow downstream and keyframe recovery (Gate 4.4).

**Known limits:**
- After a session starts, the first frame arrives at the next screen update.
  An idle screen produces no frames until something changes.
- The landscape default (270) fits one landscape direction only; the
  rotation doesn't follow lipstick's orientation.
- The recording size must be the display size or its transpose; anything
  else is rejected (Android Auto sizes are the next goal).
- Gallery can't play any video on this device, including files not made by
  this work. That is unrelated (exec4 §12).

**Follow-ups outside this set:**
- libhybris `8ac75ab` (drop the `HWComposerNativeWindow` down-casts): a
  separate, optional upstream PR.
- The `SurfaceFlingerAIDL` check in `startMiniSurfaceFlinger()`: an
  independent upstream fix.
- Pass `DroidMediaCodecEncoderMetaData` (profile, level) to
  `droid_media_screen_capture_new()` (auto-goal1 §2.1).
- Request a repaint on attach, so that the first IDR arrives immediately.
- Make landscape rotation follow lipstick's orientation.

## Wiki map

| Stage | Documents |
|---|---|
| Discussion | `hwc-encoder-discussion.md`, `hwc-encoder-discussion1.md` |
| Plans | `hwc-h264-encoding.md`, then `-revised`, `-revision2`, `-revision3`, `-revision3.1`, `-revision4` |
| Execution logs | `hwc-h264-test-notes-phase0.md`, `hwc-h264-exec1.md` ... `hwc-h264-exec4.md` |
| Next goal | `auto-goal1.md`: Android Auto resolutions (Option A mirror, Option B2 car compositor) |

The cleanup on `hwenc` already does most of auto-goal1 §6 and the service
hosting of §2.3. Its file and line references point at `hwenc-gate4`.
