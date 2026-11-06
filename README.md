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

| Submodule | Change | Upstream |
|---|---|---|
| `droidmedia` | encoder API, `sailfish.screencap` service, libminisf bridge | `sailfishos/droidmedia` (`master`) |
| `gst-droid` | `droidscreencapsrc` element | `sailfishos/gst-droid` (`master`) |
| `qt5-qpa-hwcomposer-plugin` | draws the display into the encoder Surface | `mer-hybris/qt5-qpa-hwcomposer-plugin` (`master`) |

- The change is `git diff master..hwenc` in each submodule.
  [`scripts/squash-hwenc-review.sh`](scripts/squash-hwenc-review.sh) squashes
  it into one commit per repository on branch `hwenc-review`.
- The forks live at `github.com/b100dian/<repo>`.
- The `libhybris` submodule is not part of the set: stock libhybris works.

## Components

```
 recorder (gst-launch)                                    minisfservice
 +------------------------------+  registerProducer,      +-------------------------+
 | droidscreencapsrc            |  unregisterProducer,    | sailfish.screencap      |
 | DroidMediaScreenCapture      |  requestFrame           | one session,            |
 |   MediaCodec H.264 encoder   |------------------------>| generation N            |
 |   input Surface              |                         +-------------------------+
 +------------------------------+                             |                ^
                ^                         sessionChanged,     |                | registerListener,
                |                         frameRequested      v                | getProducer
                |                         (oneway)        +-------------------------+
                +--- frames: queueBuffer on the ----------| lipstick                |
                     encoder Surface (GPU buffers,        | libminisf               |
                     no CPU copy)                         | HwComposerScreenCapture |
                                                          +-------------------------+
```

- **`droidscreencapsrc`** (`gst-droid/gst/droidscreencapsrc/`) owns one
  `DroidMediaScreenCapture` per run and turns its callbacks into GstBuffers.
- **`DroidMediaScreenCapture`** (`droidmedia/droidmediascreencapture.{h,cpp}`)
  configures the hardware AVC encoder with Surface input. It registers the
  Surface's producer with the service, with the session's target and content
  rect, and runs the output thread. A sync-frame request sets the encoder's
  `request-sync` and asks the renderer for a frame.
- **`sailfish.screencap`** (`droidmedia/screen_capture_service.{h,cpp}`) is
  hosted by `minisfservice`. It holds one session; every registration gets a
  new generation, and the session ends when the recorder unregisters or dies.
  The target says who renders: lipstick for `DISPLAY`, another renderer for
  `VIRTUAL`. The content rect is a `DroidMediaRect`.
- **libminisf** (`droidmedia/minisf_screen_capture.cpp`) gives the compositor
  five C entry points. It subscribes to the service and keeps the session the
  service pushes, so a session query is a local read. The query fills a
  `ScreenCaptureSession`; the plugin declares the same layout as
  `MinisfScreenCaptureSessionInfo`. A callback reports session changes and
  frame requests on a Binder thread.
  While the service is missing, it looks it up with `checkService()`, at most
  every 250 ms, and never blocks.
- **`HwComposerScreenCapture`**
  (`qt5-qpa-hwcomposer-plugin/hwcomposer/hwcomposer_screencapture.{h,cpp}`)
  runs inside lipstick when `QPA_HWC_SCREENCAP=1` and draws into the Surface
  of a `DISPLAY` session.

## Session sequence

```
 recorder (droidscreencapsrc)    minisfservice           lipstick (QPA)
        |                             |<-- registerListener ---|  once, at lipstick's first frame
        |                             |    returns: no session |
 start: MediaCodec configure, createInputSurface, start        |
        |-- registerProducer -------->| generation N           |
        |                             |--- sessionChanged ---->|  N, w x h @ fps, target, rect
        |                             |    (oneway)            |  repaint; attach at that frame
        |<===== frames: queueBuffer on the encoder Surface ====|  after each primary swap
        |  output thread -> data_available(AU, ts)             |
        |                             |                        |
 GstForceKeyUnit, or overload:        |                        |
 request-sync, requestFrame(N) ------>|--- frameRequested ---->|  repaint: the next frame is
        |                             |                        |  an IDR, also on an idle screen
        |                             |                        |
 EOS (gst-launch -e / Ctrl-C):        |                        |
 finish: unregisterProducer(N) ------>| session ended          |
        |                             |--- sessionChanged ---->|  no session: repaint, detach,
        |  100 ms detach grace        |                        |  destroy the EGL surface
        |  signalEndOfInputStream                              |
        |  drain to the codec's EOS -> signal_eos -> GST_FLOW_EOS
        |  stop codec                                          |
```

`registerListener` returns the current session and notifies no one; later
changes come through `sessionChanged`. At the first frame after a new
session, lipstick ignores a `VIRTUAL` session, rejects an odd size or one
over 4096 (each with a log line, and the recording stays empty), and
otherwise attaches and fits the display into the content rect.

If the recorder dies instead, the service's death notification ends the
session and tells lipstick, which repaints and detaches. If `minisfservice`
dies, lipstick drops the session and subscribes again at its first frame
after the service is back.

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
     attaches, detaches, ignores or rejects. Attaching makes one Binder call,
     to get the Surface's producer, and logs the rotation and viewport;
   - waits up to 250 ms for the fence;
   - switches to its private EGL context with a scoped guard;
   - imports the buffer as an EGLImage texture (cached per buffer);
   - clears the frame to black and draws one quad with the y-flip and the
     rotation into the fitted viewport;
   - sets `eglPresentationTimeANDROID(CLOCK_MONOTONIC now)`, swaps, and
     restores lipstick's context.
5. A failed fence wait, render or swap, or a swap longer than 250 ms, gives
   up on that generation. Lipstick carries on, and the next recorder session
   attaches normally.

### The fit

When the content rect and the display have different orientations, the
display is turned by `QPA_HWC_SCREENCAP_LANDSCAPE_ROTATION`. It is then
scaled to fit the rect with its aspect ratio kept, rounded down to even
sizes, and centred; the rest of the frame is black. The display size and its
transpose still fill the frame exactly. The code is `captureFit()` in
`hwcomposer_screencapture.h`, built on `QSize::scaled()`;
[`tools/screencap-fit-test`](tools/screencap-fit-test) checks it on the host.

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
- **Key units:** an upstream `GstForceKeyUnit` event, from downstream or sent
  to the element, makes the next frame an IDR and has lipstick render it, so
  it comes within a frame even on an idle screen.
- **Overload:** a bound of 30 frames or 8 MiB. When it's exceeded, queued
  access units are dropped up to the next IDR, with one warning per episode,
  and an IDR is requested at once. A repeated PTS is dropped; a regressing
  PTS is an error.
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

Element properties:
- `width`, `height` (required). Lipstick mirrors even sizes up to 4096 and
  rejects others with a log line (the recording stays empty). The display is
  fitted into the frame, turned for a landscape size; `1080x2520` and
  `2520x1080` fill the frame on this phone.
- `target-bitrate` (default 8000000).
- `fps` (default 60, at most 120): the encoder's nominal frame rate and the
  caps framerate. Lipstick sends every frame it renders, so it should match
  the display refresh rate.
- `profile` (default `default`): `constrained-baseline`, `baseline`, `main`
  or `high`. `default` leaves profile and level to the encoder (High on
  this phone).
- `level` (default 0): the H.264 level times 10 (`31` is 3.1). 0 is the
  lowest level that fits size, fps and bitrate. It needs a `profile`.
- `target` (default `display`): `display` has lipstick mirror the screen;
  lipstick ignores a `virtual` session, which another renderer fills.
- `content-rect` (default `<0, 0, 0, 0>`, the whole frame): `<x, y, width,
  height>` from the top left, where the picture goes in the frame. A value
  that is not four non-negative integers is ignored with a warning; a rect
  outside the frame, or with no area, fails at start.

## Build and deploy

General build notes are in [`wiki/building.md`](wiki/building.md). The four
packages are a matched set: the API, the Binder interface and the session
struct the plugin reads changed together.

1. **droidmedia, Android side.** In the HADK `croot`:
   `make libdroidmedia minimediaservice minisfservice libminisf screencap_surface_capture_test`,
   then the droidmedia RPM as usual:
   `rpm/dhd/helpers/build_packages.sh -g`. It ships
   `libdroidmedia.so`, `libminisf.so`, `minisfservice` and
   `screencap_surface_capture_test`.
2. **droidmedia-devel**, which gst-droid needs (PlatformSDK):
   `rpm/dhd/helpers/build_packages.sh -b hybris/mw/droidmedia -s rpm/droidmedia-devel.spec`.
3. **gst-droid:** `rpm/dhd/helpers/build_packages.sh -b hybris/mw/gst-droid`.
4. **qt5-qpa-hwcomposer-plugin:**
   `rpm/dhd/helpers/build_packages.sh -b hybris/mw/qt5-qpa-hwcomposer-plugin`.
   It has no droidmedia build dependency.

To install them on the phone and restart `minisfservice` and lipstick, follow
"On the device" in [`wiki/building.md`](wiki/building.md) or step 1 of
[`wiki/checklist.md`](wiki/checklist.md).

The service is registered by `minisfservice` for the first time. If
`droidscreencapsrc` reports that `sailfish.screencap` is not running, check
that `minisfservice` was restarted after the install (`pgrep -a
minisfservice`), then look for SELinux denials with `logcat -d | grep avc`.
The service manager logs them to logcat, not to `dmesg`.

## Usage

```sh
# Raw H.264 (portrait; use width=2520 height=1080 for landscape)
gst-launch-1.0 -e droidscreencapsrc width=1080 height=2520 target-bitrate=8000000 fps=60 ! \
  h264parse ! filesink location=/tmp/screen.h264

# A head-unit size: letterboxed, Constrained Baseline, level 3.1
gst-launch-1.0 -e droidscreencapsrc width=1280 height=720 fps=30 target-bitrate=4000000 \
  profile=constrained-baseline level=31 ! h264parse ! filesink location=/tmp/hu.h264

# The picture in the top 1280x600 of a 1280x720 frame
gst-launch-1.0 -e droidscreencapsrc width=1280 height=720 content-rect="<0, 0, 1280, 600>" ! \
  h264parse ! filesink location=/tmp/rect.h264

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

**Passed on the device** (dates and logs in
[`wiki/cleanup-plan.md`](wiki/cleanup-plan.md) and
[`wiki/gate-5-exec.md`](wiki/gate-5-exec.md)):
- Regression set, last run before the Gate 5 changes:
  - portrait 1080x2520 and landscape 2520x1080 (rotation 270, upright, not
    stretched), raw and MP4 through `qtmux` (valid per `ffprobe`): High
    profile, sparse PTS with idle gaps kept, EOS drained in about 0.5 s,
    0 drops at 8 Mbit/s;
  - portrait, landscape and portrait again in one lipstick run;
  - raw Annex B over TCP, played live on a host at `fps=60` and `fps=120`
    (no frame dropped on this 60 Hz display); after typing, the view shows
    the last change at once;
  - recorder killed with `kill -9`: the session ends and the next one works;
  - lipstick without `QPA_HWC_SCREENCAP`, the droidmedia-only tool, and
    camera recording;
  - `gst-inspect-1.0`: properties, rank none;
  - stock libhybris is enough.
- Gate 5:
  - `profile=constrained-baseline` gives Constrained Baseline at the computed
    level (5.1 at 1080x2520@60); `level=31` and `level=32` give those levels
    in the SPS;
  - with the screen idle, every `GstForceKeyUnit` gives exactly one IDR, and
    the first frame comes without touching the screen;
  - a `target=virtual` session is ignored by lipstick with one log line, and
    its recording stays empty;
  - 800x480, 1280x720, 1920x1080, 720x1280 and a content rect in one lipstick
    run, each with the fit-test viewport and a clean detach.

**Not yet run on the device:**
- the device checklist, [`wiki/checklist.md`](wiki/checklist.md), on the
  build with the review tweaks (results in `wiki/gate-5-tweaks-exec.md` §6).
  It includes the regression set, a stale `minisfservice` and Gallery
  playback;
- outside the checklist so far: a check that the 100 ms detach grace keeps
  the last frame of a recording, the RTP proof, and slow downstream with
  keyframe recovery.

**Known limits:**
- An idle screen produces no frames until something changes or a key unit
  is requested.
- A landscape session always turns the display, even while lipstick's UI is
  portrait, and a portrait one never does. The landscape default (270) fits
  one landscape direction only; the rotation doesn't follow lipstick's
  orientation.
- After a `minisfservice` restart, lipstick subscribes again only at its
  next frame, so a recorder started before that waits for a screen change.
- Downscaling far below the display size aliases thin text: at 800x480
  (about 0.32x) Settings visibly shimmers while scrolling.

**Follow-ups outside this set:**
- The libhybris change that drops the `HWComposerNativeWindow` down-casts: a
  separate, optional upstream PR (stock libhybris works).
- The `SurfaceFlingerAIDL` check in `startMiniSurfaceFlinger()`: an
  independent upstream fix.
- Make landscape rotation follow lipstick's orientation.
- The 4-tap downscale filter (auto-goal1 §3.3), only if the mirror stays a
  product mode: B2 renders at the head unit's size and doesn't scale.

## Wiki map

| Stage | Documents |
|---|---|
| Discussion | `hwc-encoder-discussion.md`, `hwc-encoder-discussion1.md` |
| Plans | `hwc-h264-encoding.md`, then `-revised`, `-revision2`, `-revision3`, `-revision3.1`, `-revision4` |
| Execution logs | `hwc-h264-test-notes-phase0.md`, `hwc-h264-exec1.md` ... `hwc-h264-exec4.md` |
| Cleanup | `cleanup-plan.md`: `hwenc` as reviewable commits; the pre-cleanup heads are tagged `hwenc-gate4`, with the rollback steps |
| Next goal | `auto-goal1.md`: Android Auto resolutions (Option A mirror, Option B2 car compositor; its file and line references point at `hwenc-gate4`); its first step `gate-5.md`, executed in `gate-5-exec.md` |
| Review prep | `gate-5-tweaks.md`: comment cleanup, reuse of existing types, a smaller `master..hwenc` diff; executed in `gate-5-tweaks-exec.md` |
| Build | `building.md`: SDK, HADK, device install and host-only checks |
| Device tests | `checklist.md`: the device run after every deploy; a change to device behaviour updates it |
| Notes | `review.md` (code walkthrough), `improvement-ideas.md` (unplanned ideas), `lipstick-recorder-comparison.md` (lipstick2vnc's recorder compared with the QPA capture) |
