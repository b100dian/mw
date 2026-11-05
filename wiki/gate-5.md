# Gate 5: Android Auto groundwork that can land in the first PR

**Date:** 2026-10-20, revised 2026-10-23
**Status:** Steps 1 and 2 implemented; Gates 5.0 to 5.2 passed, with the open items in `gate-5-exec.md`, the execution log.
**Basis:** `auto-goal1.md` (design; § references below point there unless stated), `../README.md`, `cleanup-plan.md`
**Scope:** Everything the upstream repositories (droidmedia, gst-droid, qt5-qpa-hwcomposer-plugin) need for Android Auto (AA), so that the PR may be the only chance to contribute:
- encoder profile/level and keyframe on demand;
- a session contract that already carries what B2 needs (target kind, content rect, repaint requests), extensible without breaking older clients;
- Option A (letterbox/pillarbox) in lipstick;
- the B2 second-process spike, which decides whether the QPA "encoder" backend joins the PR as an optional commit.

**Not in Gate 5:** the car compositor (a qt-runner fork, its own repo, auto-goal1 §4.4), car input and apps, and the AA transport. None of them needs an upstream change beyond this gate.

## 1. Changes

### 1.1 droidmedia

**Encoder API** (`droidmediascreencapture.{h,cpp}`, `hybris.c`):
- `droid_media_screen_capture_new(DroidMediaCodecEncoderMetaData *meta, cb, data)`. Uses `parent.width/height/fps`, `bitrate` and `codec_specific.h264.profile/level`. The profile/level handling is the block the camera encoder already has (`droidmediacodec.cpp:455–473`), moved into a small shared helper: the OMX constants go into the `"profile"`/`"level"` keys of `MediaCodec::configure()`, and a level of 0 becomes `ACodec::getAVCLevelFor(width, height, fps, bitrate, profile)`, the lowest level that fits the session. A profile of 0 skips the helper, so the stream stays as today (no keys set; `droidmediascreencapture.cpp:117–124`). The OMX and MediaCodec constants are the same numbers for AVC (`OMX_VIDEO_AVCProfileConstrainedBaseline` = `AVCProfileConstrainedBaseline` = 0x10000; levels 3.1 = 0x200, 3.2 = 0x400; `OMX_VideoExt.h`, `OMX_Video.h`, `MediaCodecConstants.h`). That the encoder honours an explicit Baseline is already known: gst-droid never sets `codec_specific`, so every camera recording on this device configures `profile=Baseline` plus a computed level through that block.
- `droid_media_screen_capture_set_target(capture, kind, x, y, w, h)`, before `start()`. `kind` is `DROID_MEDIA_SCREEN_CAPTURE_TARGET_DISPLAY` (default) or `_VIRTUAL`; the rect is the content rect, `0,0,0,0` for the whole frame.
- `droid_media_screen_capture_request_sync_frame(capture)`: `setParameters({"request-sync": 0})` (built like `droid_media_codec_set_video_encoder_bitrate()`, `droidmediacodec.cpp:1176`), then `requestFrame(generation)` on the service. One call, because with Surface input the sync frame only comes with the next rendered frame.
- `start()` does not request a frame. The renderer repaints on `SESSION_CHANGED` (1.3), and the attach happens inside that same `captureFrame()` before the buffer is submitted, so the first access unit is already an IDR of the current screen. An extra Binder call would add nothing but an ordering story.
- `hybris.c`: wrappers for the two new calls; `_new` keeps its `__try_resolve_sym` guard for Android < 8.

**Service** (`screen_capture_service.{h,cpp}`):
- `ScreenCaptureSession` gains `target`, `content_x/y/w/h`. `registerProducer` takes them; `getProducer` and `sessionChanged` return them. New fields go at the end of each parcel: a reader that reads fewer fields ignores the rest, and a reader past the end gets zeros, so no per-parcel version number is needed.
- New `requestFrame(generation)`: if `generation` is current, a oneway `frameRequested(generation)` goes to every listener.
- Both interface descriptors get a version suffix (`IMPLEMENT_META_INTERFACE(..., "sailfish.IScreenCaptureService/2")`, `screen_capture_service.cpp:164`; the listener at `:80` likewise). A stale `minisfservice` after an install (cleanup-plan §7) then fails `CHECK_INTERFACE` with `PERMISSION_DENIED`, which libminisf already logs as a failed subscribe, instead of mis-reading the new parcels.

**libminisf** (`minisf_screen_capture.cpp`), the boundary to a separately packaged QPA:
- `MinisfScreenCaptureSessionInfo` starts with `uint32_t size`, set by the caller; libminisf fills at most that many bytes. Older or newer QPA builds keep working. This stays because it is a C struct across packages, where Binder's parcel rules do not apply.
- `minisf_screen_capture_set_callback(void (*cb)(void *user, int event), void *user)`, with events `SESSION_CHANGED` and `FRAME_REQUESTED`. Called on a Binder thread, never under `s_lock`. The QPA needs it to render on an idle screen; B2's backend needs it to expose and unexpose its window.
- The session query stays a local read.

### 1.2 gst-droid (`droidscreencapsrc`)

- Properties `profile` (enum: `default`, `constrained-baseline`, `baseline`, `main`, `high`), `level`, `target` (`display` | `virtual`) and `content-rect` (`x,y,w,h`), all `GST_PARAM_MUTABLE_READY`.
- `GstBaseSrcClass::event`: an upstream `GstForceKeyUnit` calls `request_sync_frame`. The event is matched with `gst_event_has_name(event, "GstForceKeyUnit")`, not `gst_video_event_is_force_key_unit()`: the latter lives in libgstvideo, which the element no longer links (`gst/droidscreencapsrc/meson.build` lists only droidmedia, gst and gstbase). The overload "drop until keyframe" path calls it too.
- No caps change: `h264parse` already puts `profile`/`level` from the SPS into its caps.

### 1.3 qt5-qpa-hwcomposer-plugin (`hwcomposer_screencapture.{h,cpp}`)

- **Sessions:** attach only to `DISPLAY` sessions; ignore `VIRTUAL` ones (log once per generation). Reject only invalid sizes (≤ 0, > 4096, odd) or `fps <= 0`.
- **Fit:** `captureFit()` replaces `captureSessionRotation()` (`hwcomposer_screencapture.cpp:95`); it is the pure function of auto-goal1 §3.2 and returns rotation, viewport and texture-coordinate crop. It lives in a plain C++ header with no Qt includes, because the host clang cannot parse the Qt 5.6 headers (cleanup-plan §3); the host-only test that checks it against the §3.2 table is then one `g++ test.cpp` away. The QPA has no test suite, and the program is not part of the build.
- **Render:** `glClear` of the full surface every frame, then `glViewport(fit.viewport)` and the quad with the fit's texture coordinates. The clear is required: after a swap EGL leaves buffer contents undefined, so uncleared bars would show older frames. On Adreno a full clear also saves loading the old contents into tile memory.
- **Repaint on request:** the libminisf callback calls `QMetaObject::invokeMethod(window, "update", Qt::QueuedConnection)` on the primary window, straight from the Binder thread; a queued invocation is safe from a non-Qt thread, and the `update` slot needs no QtQuick link dependency. `QWindow::requestUpdate()` is not enough: with the threaded render loop it only schedules a sync, and the render thread skips the render when the sync changed nothing (`QSGRenderThread::syncAndRender`, "no changes, render aborted"), which is exactly the idle-screen case this is for. `QQuickWindow::update()` sets `RepaintRequest`, so the scene is rendered and swapped. On `SESSION_CHANGED` this makes lipstick render once, so attaching no longer waits for the next screen change. Fallback if the device disagrees in 5.1: an expose event. (The render-loop claim is from `qsgthreadedrenderloop.cpp`; the Qt 5.6 sources are not in the tree.)
- `QPA_HWC_SCREENCAP_LANDSCAPE_ROTATION` keeps its meaning; following lipstick's orientation stays a later refinement (auto-goal1 §3.2).

**Optional, only after 5.4 passes:** the "encoder" backend of auto-goal1 §4.3, as a separate commit (Gate 5.5).

### 1.4 Test tool, before 5.4

`screencap_surface_capture_test`, the recorder without GStreamer, becomes the remote view (§3). Nothing in 5.0–5.2 needs it, so it comes with the spike:
- usage `[-t display|virtual] [-r x,y,w,h] [-p profile] [-l level] [width height bitrate fps seconds output]`; the positional part is unchanged;
- `seconds` 0 records until SIGINT, SIGTERM or SIGHUP, then calls `finish()`;
- output `-` is stdout; logs stay on stderr. SIGPIPE is ignored, and a write error ends the run;
- SIGUSR1 requests a keyframe: the handler sets a flag, and the main loop calls `request_sync_frame`;
- an access-unit delimiter (`00 00 00 01 09 f0`) follows each access unit (§3).

## 2. Gates

Each gate passes only on its own evidence (Rev. 4 rule). The README's device checklist is the regression run after each deploy: portrait, landscape, MP4, TCP, Gate 4.3 sequence, `kill -9` of the recorder, lipstick without capture, the droidmedia-only tool, camera recording.

- **5.0 Encoder profile** (droidmedia, gst-droid; runs with the current QPA, which still accepts only display-size sessions):
  - `droidscreencapsrc width=1080 height=2520 profile=constrained-baseline ! h264parse ! …`, checked with `ffprobe`. The level is left at default: 1080x2520 is 10,744 macroblocks per frame, and at 60 fps that needs level 5.1 (level 5.0 allows 589,824 MB/s, 5.1 983,040), so no low level can be observed at display size. The level test is in 5.2.
  - Pass: the SPS reports Constrained Baseline with level 5.1 (what `getAVCLevelFor` computes); `profile=default` gives today's stream.
- **5.1 Session contract and repaint** (all three):
  - Pass:
    - the first AU after start is an IDR with the current screen, without touching it;
    - `GstForceKeyUnit` sent every 5 s while the screen is idle gives an IDR each time, within one frame period;
    - a `target=virtual` session is ignored by lipstick (logged, no attach) and its recorder gets no frames;
    - an old `minisfservice` (not restarted after the install) gives a logged subscribe failure and no attach, not garbage sizes.
- **5.2 Letterbox and level** (QPA; auto-goal1 §3):
  - Host: the fit test passes.
  - Device, one lipstick run: 800x480 with lipstick in portrait; 1280x720, rotating lipstick to landscape during the session; 1920x1080; 720x1280; 1280x720 with `content-rect=0,60,1280,600`. Detach/reattach and a stale size are covered by the same run.
  - Level, during the 1280x720 sessions: `level=31 fps=30` gives an SPS with level 3.1 (720p30 is exactly level 3.1: 3,600 MB per frame, 108,000 MB/s); `level=32` at 60 fps gives 3.2.
  - Pass: correct aspect (a round UI element measures round in a decoded frame), centred black bars, picture inside the content rect, `rotation` and `viewport` logged per generation; clean detach/reattach between the sizes, no stale size; the two level values as stated.
  - Quality, during the 800x480 and 1280x720 sessions: a text-heavy page (Settings) is legible and does not shimmer while scrolling. If it does, add the 4-tap filter (auto-goal1 §3.3) and compare.
- **5.3 HU path** (optional before the PR; needs a HU or emulator):
  - The 5.0 settings into an openauto/aasdk-based desktop HU, or at least `ffplay`/`avdec_h264` plus a Baseline-only decoder.
  - Pass: decodes from a mid-stream join and after a forced IDR; no decoder errors over 10 minutes.
- **5.4 B2 spike** (a test tool, not part of the PR; it lives in the parent repo, `mw/tools/b2-spike/`, built in the PlatformSDK against libhybris EGL, libminisf and wayland-server, so nothing can leak into a submodule PR):
  - A native program run as `EGL_PLATFORM=hwcomposer` while lipstick runs: `eglGetDisplay(EGL_DEFAULT_DISPLAY)`, subscribe through libminisf, attach to a `VIRTUAL` session, `eglCreateWindowSurface` on the encoder's native window, animate for a few seconds, pause, animate again. Also `eglGetProcAddress("eglBindWaylandDisplayWL")` and bind a `wl_display_create()` display. Recorded with `droidscreencapsrc target=virtual width=1280 height=720`, or with the test tool and watched live (§3). Start from the reverted `tools/hwcomposer_screencap_egl_test.cpp` (at `hwenc-gate4`).
  - Pass: decodable stream with the right content; sparse PTS during the pause; lipstick unaffected, and its journal has only the one "ignored VIRTUAL session" line for that generation, no attach; the Wayland bind succeeds; no `hwcomposer` module in the spike's `/proc/<pid>/maps`.
  - Expected with stock libhybris: its hwcomposer platform takes any `ANativeWindow` (`eglplatform_hwcomposer.cpp:63–65`), and `eglBindWaylandDisplayWL` is in the shared platform code (`eglplatformcommon.cpp:68`).
  - If it fails, re-plan B2 (auto-goal1 §5, decision point) before deciding the PR's content.
- **5.5 Encoder backend** (optional commit in the PR; auto-goal1 §4.3):
  - `QT_QPA_PLATFORM=hwcomposer QPA_HWC_BACKEND=encoder qmlscene test.qml`, recorded with `target=virtual` at 1280x720.
  - Pass: on an IDR at a high bitrate, 1 px lines stay 1 px wide and unblurred (no resampling; H.264 is lossy, so no pixel-exact compare); swap rate capped at fps, and the last frame before idle is sent; 0 AUs and an idle CPU while nothing changes; session stop/start unexposes and re-exposes cleanly; lipstick unaffected.
  - If the `remotetouch` plugin exists by then (auto-goal1 §4.5; it is not part of the PR), add `QT_QPA_GENERIC_PLUGINS=remotetouch:…` and try the scene with touch from the PC (auto-goal1 §4.5).

## 3. Remote view over SSH

A `VIRTUAL` session has no screen. To watch it from a PC, use the test tool (1.4) and SSH: no GStreamer, no open port, and one login when SSH multiplexing is on (`ControlMaster auto`, `ControlPersist`).

```sh
ssh phone /usr/libexec/droid-hybris/system/bin/screencap_surface_capture_test \
    -t virtual 1280 720 4000000 60 0 - |
  mpv --profile=low-latency --untimed --demuxer-lavf-format=h264 -
```
- The first frame is an IDR of the current content, because the renderer repaints on attach (1.3, auto-goal1 §4.3). `ssh phone pkill -USR1 -f screencap_surface_capture_test` forces another one.
- **The delimiter after each access unit:** with raw H.264, ffmpeg's parser (in both mpv and ffplay) ends a frame only when the next one starts. A still screen therefore shows one frame late (cleanup-plan §5.1). An access-unit delimiter also starts a new access unit, so the frame is shown at once. It costs 6 bytes per frame. Verify on the host first, with a file. The same trick would close the one-frame-late limit of the raw Annex B TCP scripts (README "Known limits"); a `droidscreencapsrc` property for it is a possible follow-up, not Gate 5.
- `-t display` gives the same view of lipstick: at the display size until 5.2 lands, at any fitted size after.
- **A slow pipe** blocks the tool's output thread. The encoder then backs up until the renderer's 250 ms swap guard gives up on the session. That is fine on USB or a LAN.

Touch back from mpv into the compositor is B.4 work, described in auto-goal1 §4.5.

## 4. Order, commits and deploy

1. **Encoder profile/level:** `droid_media_screen_capture_new(meta)` with the shared profile/level helper (1.1), gst-droid `profile`/`level` (1.2). No Binder or libminisf change, so the current QPA keeps capturing; Gate 5.0. A self-contained first commit per repo.
2. **Session contract and QPA:** target, content rect, `requestFrame` and the descriptor bump (1.1 service), the libminisf callback, gst-droid `target`/`content-rect`/`GstForceKeyUnit` (1.2), and the QPA fit, clear and repaint (1.3). One matched set, deployed together; Gates 5.1 and 5.2 in one deploy. Gate 5.3 whenever a HU is available.
3. **Test tool and spike:** 1.4 and `mw/tools/b2-spike/`; Gate 5.4.
4. If 5.4 passes and there is time, the encoder backend and Gate 5.5.

Commits go on `hwenc` in each submodule, made by the user: one per item above per repo, so that the Gate 4 cleanup and Gate 5 stay separately reviewable before the squash. Step 1 deploys on its own; a deploy of step 2's droidmedia without its QPA would leave lipstick unable to attach until the QPA follows, which is why the two are not split.

Deploy as in the README ("Build and deploy"). Step 2 changes the Binder interface and the libminisf struct together, so its Android side, `droidmedia-devel`, gst-droid and the QPA are one matched set. After installing droidmedia, `kill $(pgrep minisfservice)` (init restarts it) or reboot; until then the old service fails the new descriptor check, which 5.1 tests on purpose.

## 5. Decisions

Formerly open questions; each is settled above and verified by the gate named.

1. **Repaint of an unchanged scene:** `invokeMethod(window, "update")`, not `requestUpdate()` (1.3). Verified in 5.1; an expose event is the fallback.
2. **Constrained Baseline constant:** the same value for OMX and MediaCodec, 0x10000, and the camera encoder path already feeds OMX constants to the same keys (1.1). Verified in 5.0.
3. **Spike tool location:** `mw/tools/b2-spike/` in the parent repo, outside every submodule (5.4).
