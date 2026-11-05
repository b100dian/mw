# Gate 5: Execution log

**Date:** 2026-10-23 to 2026-10-24
**Basis:** `gate-5.md` (plan), `auto-goal1.md` (design)
**Status:**
- Steps 1 and 2 are implemented.
- Gate 5.0 passed on 2026-10-23.
- Gates 5.1 and 5.2 passed on 2026-10-24, on the uncommitted step 2 build, with two exceptions:
  - the stale-`minisfservice` case of 5.1 was not run;
  - text aliases at 800x480 (filter deferred, §6).
- The README regression checklist has not been run on either build.
- Next: step 3 (test tool, B2 spike, Gate 5.4).

## 1. Decisions taken before implementation

These differ from `gate-5.md` or settle what it left open:

1. **libminisf query symbol.** `minisf_screen_capture_session_query` keeps its name, although its struct now starts with `size`. Step 2 is therefore deployed as a matched set: an old QPA on the new libminisf would pass a struct without `size`.
2. **Fit only.** No `fill` or `stretch` policy, no texture-coordinate crop, and no new environment variable. `captureFit()` returns rotation and viewport.
3. **Fit test location.** The host test lives in `mw/tools/screencap-fit-test/`, outside the QPA repository.
4. **H.264 constants.**
   - `droidmediacodec.h` gets public `DroidMediaCodecH264Profile` and `DroidMediaCodecH264Level` enums with numeric values. The header is compiled in the PlatformSDK, which has no OMX headers, so the values can't be written as `OMX_VIDEO_AVC*` there.
   - `static_assert`s in `droidmediacodec.cpp` (Android ≥ 8.1) check the values against the OMX constants.
   - The levels are named `LEVEL_1_0`, `LEVEL_1B`, `LEVEL_1_1` … `LEVEL_5_2`, not OMX's `Level2`/`Level21`, where "21" reads as twenty-one.

## 2. Step 1: encoder profile and level

Commits: droidmedia `6f6ad9c`, gst-droid `71437e6`. In gst-droid the level rename is staged but not yet committed.

- **droidmedia:**
  - `droid_media_screen_capture_new()` takes a `DroidMediaCodecEncoderMetaData`.
  - The camera encoder's profile/level block became `droid_media_codec_set_h264_profile_level()` (`private.h`), now shared with screen capture.
  - A level of 0 becomes `ACodec::getAVCLevelFor()`. A profile of 0 leaves profile and level to the encoder, as before.
- **gst-droid:**
  - `profile` is an enum (`default`, `constrained-baseline`, `baseline`, `main`, `high`).
  - `level` is level_idc (`31` is 3.1). A level without a profile is an element error.

### Gate 5.0 result: passed (2026-10-23)

- With `width=1080 height=2520 profile=constrained-baseline`, the SPS reports Constrained Baseline, level 5.1: the level `getAVCLevelFor()` computes for 1080x2520@60.
- `profile=default` gives the same High stream as before.

## 3. Step 2: session contract, repaint, letterbox

Uncommitted, on top of droidmedia `6f6ad9c`, gst-droid `71437e6` and QPA `d2a8124`.

- **Service:**
  - `ScreenCaptureSession` gains `target` (DISPLAY 0, VIRTUAL 1) and `content_x/y/width/height`.
  - `writeSession()`/`readSession()` carry the whole session in all three parcels (register, get-producer reply, session change), so a new field is added in one place.
  - `requestFrame(generation)` (oneway) reaches the listeners as `frameRequested` (oneway).
  - Both descriptors end in `/2`.
  - `screenCaptureTargetValid()` validates for the service and the recorder alike.
- **libminisf:**
  - `MinisfScreenCaptureSessionInfo` starts with `size`; the query zeroes and fills only that many bytes.
  - `minisf_screen_capture_set_callback()` reports `SESSION_CHANGED` (also when the service dies) and `FRAME_REQUESTED` (current generation only).
  - The callback runs on a Binder thread, under its own mutex, and never under `s_lock`. Clearing it waits for a running callback.
- **Recorder API:**
  - `droid_media_screen_capture_set_target()` works in IDLE only.
  - `droid_media_screen_capture_request_sync_frame()`, under `m_lock` while STARTED, sets `request-sync` and calls `requestFrame`. It is callable from any thread, including the callbacks.
  - Both have `hybris.c` wrappers.
- **gst-droid:**
  - New properties: `target` (enum) and `content-rect` (`"x,y,w,h"`; an invalid string warns and is ignored).
  - `GstForceKeyUnit` calls `request_sync_frame`, whether it comes from downstream (`GstBaseSrcClass::event`) or is sent to the element (`send_event`, because GstBaseSrc drops custom upstream events sent that way). Its running-time is ignored: the IDR comes at once.
  - A queue overflow requests an IDR right away.
  - `capture_lock` keeps a key-unit request from racing `stop()`.
- **QPA:**
  - `hwcomposer_screencapture_fit.h` (no Qt) holds `captureFit()` and `captureViewportGlY()`.
  - DISPLAY sessions of any even size up to 4096 attach. VIRTUAL sessions are logged once and ignored.
  - Each frame is cleared to black, then drawn into the fitted viewport.
  - The libminisf callback posts an event to a receiver on the GUI thread, which calls `QQuickWindow::update()` on every exposed top-level window (`requestUpdate()` for other windows). On `FRAME_REQUESTED` it does so only for DISPLAY sessions.
  - Lipstick hides its window when the display is off, so the `isExposed()` check skips that case.

Differences from the plan:
- **Rotation rule.** The display turns when its orientation differs from the content rect's, not only when the rect is landscape and the panel portrait. On portrait panels the result is the same, and landscape panels keep today's behaviour of turning for the transposed size.
- **No overload flag.** `waiting_for_keyframe` being set right after `enqueue_locked()` means the queue just overflowed.
- **GL y of the asymmetric rect.** The plan gave 120 for the content rect `0,0,1280,600`. The fit sits 26 px into that rect, so its GL y is 146; 120 is the GL y of the rect itself.

Host checks:
- every changed droidmedia source compiles with the kati flags;
- `hybris.c` compiles;
- the element passes the GStreamer 1.26 syntax check;
- the QPA compiles with the SDK cross g++, with no warnings in our files;
- the fit test passes: 34 cases, every cell of the auto-goal1 §3.2 table plus the content rects, an odd rect, a square panel, an upscale and both orientations on a landscape panel.

## 4. Deploy detour: the wrong package

The first 5.1 run aborted with:

```
python3: ../hybris.c:76: __resolve_sym: Assertion `ptr != NULL' failed.
```

logcat ended right after `DroidMediaScreenCapture: Using c2.qti.avc.encoder`, so `_new()` worked and the next call, `set_target()`, did not resolve. `droidmedia-flashlight` had been installed instead of `droidmedia`, so the device ran the step 1 `libdroidmedia.so` under the step 2 shim from droidmedia-devel.

A second trap behind the same symptom:
- The droidmedia RPM's version comes from `git describe` only, e.g. `hwenc+gate4+10+g6f6ad9c-1`, with no dirty marker or timestamp.
- A rebuild of uncommitted changes therefore keeps the version of the last commit, and zypper or rpm skip it as already installed. Install it with `rpm -Uvh --force`.
- droidmedia-devel and gst-droid carry a timestamp in their version and always upgrade.
- To check on the device: `grep -c <symbol> /usr/libexec/droid-hybris/system/lib64/libdroidmedia.so`.

## 5. Gate 5.1 result: passed except the stale service (2026-10-24)

**Key units on an idle screen.** The script below pushes an upstream `GstForceKeyUnit` from `h264parse`'s sink pad every 5 s and sends EOS at 32 s:

```python
import gi
gi.require_version('Gst', '1.0'); gi.require_version('GstVideo', '1.0')
from gi.repository import GLib, Gst, GstVideo
Gst.init(None)
p = Gst.parse_launch('droidscreencapsrc width=1280 height=720 fps=30 ! '
                     'h264parse name=parse ! filesink location=/tmp/fku.h264')
pad = p.get_by_name('parse').get_static_pad('sink')
GLib.timeout_add_seconds(5, lambda: pad.push_event(
    GstVideo.video_event_new_upstream_force_key_unit(Gst.CLOCK_TIME_NONE, True, 0)) or True)
GLib.timeout_add_seconds(32, lambda: p.send_event(Gst.Event.new_eos()) and False)
loop = GLib.MainLoop(); bus = p.get_bus(); bus.add_signal_watch()
bus.connect('message::eos', lambda *a: loop.quit())
bus.connect('message::error', lambda b, m: (print(m.parse_error()), loop.quit()))
p.set_state(Gst.State.PLAYING); loop.run(); p.set_state(Gst.State.NULL)
```

```sh
ffprobe -v quiet -show_entries frame=pict_type,pkt_size -of csv=p=0 /tmp/fku.h264
```

Without stderr suppressed, ffprobe's "Last message repeated" lines overwrite its stdout in the terminal.

- **Run without a screen change** (the status-bar minute stayed the same): 7 frames, all I.
  - Sizes: 60646 (three times), then 63798 (four times). That is the first frame plus one per request, and nothing in between.
  - The size step at the 4th frame has no frame of its own before it, so it is most likely the encoder's rate control, not new content. It happened at the same frame in both runs. Frames 3 and 4 were not compared pixel by pixel.
- **Earlier run that crossed a minute:** 8 frames, `I I I I P I I I` (60550 three times, 63670, a 758-byte P, 63766 three times).
  - This fits the clock's frame arriving together with the 15 s request: that frame took the IDR, and the repaint followed as an almost empty P.
  - Without timestamps this is not proven. The clean rerun above is the evidence.

So: each request gives one IDR on an idle screen, and the repaint renders exactly one frame. The first access unit is an IDR without touching the screen. Its content was not compared with the screen.

**VIRTUAL session.** `droidscreencapsrc width=1280 height=720 target=virtual` ran about 10 s while the screen was touched:
- the output file is empty;
- lipstick logged exactly one line, and nothing attached:

```
screencap: ignoring session 446581715594547: target 1 is not the display
```

**Stale `minisfservice`: not run.** The wrong-package detour (§4) was a different mismatch: an old Android library under the new shim, not the descriptor check. Reproducing the check now needs the step 1 droidmedia RPM reinstalled under the step 2 clients. It is left open.

**Generation numbers.**
- Values like 446581715594547 are expected. The service starts counting at `CLOCK_MONOTONIC` in ns when it starts (here about 124 h of awake time) and adds one per session, so a restarted service never reuses a generation the compositor has seen.
- The sessions in §6 ran consecutively, 548 to 554.

**Journal access.** Lipstick's lines are in the system journal. `journalctl --user` as `defaultuser` doesn't show them; `devel-su journalctl` does.

## 6. Gate 5.2 result: passed, with aliasing at 800x480 (2026-10-24)

Host: fit test, 34 of 34.

Device: one lipstick run (pid 60895), one 10 s recording per size, Settings on screen. Every session attached with the fit-test values and detached cleanly before the next one, with no stale size:

| Run | Properties | Journal: rotation, viewport |
|---|---|---|
| s800 | `width=800 height=480` | 270, `0,69 800x342` |
| s1280 | `width=1280 height=720` | 270, `0,86 1280x548` |
| s1920 | `width=1920 height=1080` | 270, `0,129 1920x822` |
| s720p | `width=720 height=1280` | 0, `86,0 548x1280` |
| rect | `width=1280 height=720 content-rect=0,0,1280,600` | 270, `0,26 1280x548` |
| l31 | `… fps=30 profile=constrained-baseline level=31` | 270, `0,86 1280x548` |
| l32 | `… fps=60 profile=constrained-baseline level=32` | 270, `0,86 1280x548` |

- **Content rect.** The asymmetric `0,0,1280,600` replaced the gate's `0,60,1280,600`. That rect is symmetric, and its fit (`0,86 1280x548`) equals the whole-frame fit, so it can't show that the rect is applied. In the asymmetric run, the journal viewport moved to y 26 as computed. The decoded frame was not inspected for the 26/146 px bars.
- **Levels.** `ffprobe -show_entries stream=profile,level` gives `Constrained Baseline,31` and `Constrained Baseline,32`.
- **Rotation.** s1280, recorded again for 20 s while turning lipstick to landscape early, looks good: upright and letterboxed.
- **Quality at 800x480.** Text is visibly aliased while scrolling. `GL_LINEAR` reads 2x2 texels per output pixel, and at 0.32x it skips most of the source.
  - The 4-tap filter of auto-goal1 §3.3 is deferred. B2 renders VIRTUAL sessions at the head unit's own size, with no blit and no scaling, so the filter only matters if the DISPLAY mirror becomes a product mode, or if Gate 5.4 fails and B2 is re-planned.

The helper used for the runs. The phone has no `timeout`, and gst-launch handles SIGINT itself, so `-e` still finishes the file:

```sh
r() { n=$1; shift; gst-launch-1.0 -q -e droidscreencapsrc "$@" ! h264parse ! filesink location=/tmp/$n.h264 & p=$!; sleep ${S:-10}; kill -INT $p; wait $p; }
r s800 width=800 height=480
devel-su journalctl -b | grep -E "screencap: (attached|session)"
```

## 7. Open items

- The README regression checklist on the step 1 and step 2 builds.
- The stale-`minisfservice` case of 5.1.
- Commits:
  - the gst-droid level rename (staged);
  - step 2 in the three submodules;
  - `tools/screencap-fit-test/` and the README in mw;
  - the new QPA file `hwcomposer_screencapture_fit.h`, which still needs `git add`.
- The 4-tap downscale filter, deferred (§6).
- Step 3: the test tool options and the B2 spike, Gate 5.4.
