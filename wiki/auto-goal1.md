# Android Auto Goal 1: AA-resolution capture. Option A (mirror, test) and Option B2 (car compositor, final)

**Date:** 2026-10-13, revised 2026-10-20
**Status:** Plan. Nothing implemented. The baseline is the cleaned-up `hwenc` (`../README.md`, `cleanup-plan.md`): `sailfish.screencap` is hosted by `minisfservice`, libminisf receives session changes pushed by the service, and lipstick sends every frame it renders.
**Basis:** `../README.md`, `cleanup-plan.md`, `hwc-h264-encoding-revision4.md`, `hwc-h264-exec4.md`
**Scope:** Get a Sailfish UI into an H.264 stream at a resolution the Android Auto (AA) head unit (HU) negotiates, for any phone panel size, keeping the zero-CPU-copy hardware-encode path.
- **Option A** mirrors lipstick, scaled with letterbox/pillarbox. It is a test vehicle.
- **Option B2** is a dedicated nested Wayland "car compositor" that renders natively at the HU size. It is the product target.

**Out of scope:** the AA transport (USB/Wi-Fi, AAP framing, TLS, service discovery), audio, and AA sensor/navigation channels. The plan only fixes the interfaces the transport will need: encoded AUs, keyframe requests, a session start/stop with size/fps/margins/DPI, and touch input.

## 1. Requirements derived from AA video

| AA concept | What it means here |
|---|---|
| HU offers video configs: codec resolution 800x480, 1280x720, 1920x1080 (newer: 2560x1440, 3840x2160, portrait 720x1280/1080x1920/1440x2560), fps 30/60 | The encoder session size is one of a fixed set and is **unrelated to the phone panel**. QPA must stop requiring session size == display size. |
| `width_margin` / `height_margin` | The HU crops margins off the decoded frame. The visible UI area is `codec size − margins`, centred. The session must carry a **content rect**. |
| `density` (DPI, typically ~120–200) | UI scale. Irrelevant to A (it mirrors phone UI). For B2 it drives the client pixel ratio. |
| H.264 elementary stream, IDR self-contained | Already the `droidscreencapsrc` contract (README, "output"). |
| Decoder capability | Assume **Constrained Baseline**, level ≤ 3.1 for 720p and ≤ 4.x for 1080p, until a real HU or emulator proves otherwise. Current output is **High** (level 5.0 in exec4) with no profile/level set (`droidmedia/droidmediascreencapture.cpp:117–124`). |
| Video focus gain, error recovery, unacked-frame flow control | Need **low latency** (done: each AU is pushed at once, gst-droid `3a7e560`) and **IDR on demand**. With Surface input, `request-sync` applies to the *next input frame*, so on an idle screen an IDR also needs a repaint (§2.2). |

The phone panel is not a parameter of the stream. For A, panel size affects only the fit math (§3.2). For B2 it does not matter at all.

## 2. Work shared by A and B2 (do first)

### 2.1 Encoder configuration (droidmedia)

Today `droid_media_screen_capture_new(width, height, bitrate, fps, cb, data)` takes positional arguments and hard-codes the rest (`i-frame-interval` 1, SPS/PPS prepended to IDRs).

- Make it take the existing `DroidMediaCodecEncoderMetaData` (`droidmediacodec.h`): `parent.width/height/fps`, `bitrate`, `codec_specific.h264.profile/level` (0 = platform default). No new struct and no shim: the API is not upstream, and the only callers are gst-droid and `screencap_surface_capture_test`.
- Add `droid_media_screen_capture_request_sync_frame(capture)`: `MediaCodec::setParameters({"request-sync": 0})`, built like `droid_media_codec_set_video_encoder_bitrate()` (`droidmediacodec.cpp:1176`), with a `hybris.c` wrapper. A bitrate setter is optional.
- Target kind and content rect are session properties, not codec ones. They go to the service with `registerProducer` (§2.3), set on the capture object before `start()`.
- Validate profile/level acceptance on device. Codec2 may silently ignore an unsupported profile. Log the output format and check the first SPS with `ffprobe`.
- Not `repeat-previous-frame-after`: Android 14's GraphicBufferSource repeats the last frame 10 times after every change and can drop a real frame that follows a repeat (cleanup-plan §5.3).

### 2.2 `droidscreencapsrc` (gst-droid)

- **Properties:** `profile` (enum: `default`, `constrained-baseline`, `baseline`, `main`, `high`) and `level`; `target` (`display` | `virtual`); `content-rect` (string `x,y,w,h`).
- **Keyframe on demand:** handle the upstream `GstForceKeyUnit` event (`gst_video_event_is_force_key_unit`) in `src_event` and call `request_sync_frame`. An AA transport element or app only has to send that event. The overload "drop until keyframe" path should request a sync frame too, instead of waiting up to a second.
- **Repaint request:** add `requestFrame(generation)` to the service, forwarded to the subscribed compositors as a oneway listener call. The compositor posts an update to its GUI thread (a `requestUpdate()` on the platform window, or an expose). The element sends it after each sync-frame request and at session start, so the first IDR arrives at once (today it waits for the next screen change, README "Known limits").
- **Caps:** when `profile` is set, add `profile=` to the fixed caps only after the first SPS confirms it.

### 2.3 Session contract (droidmedia `sailfish.screencap`)

The service holds one session, keyed by a generation, and pushes every change to its listeners (`screen_capture_service.h`). Two renderers will exist (lipstick for A, the car compositor for B2), so the session must say **who should render into it**:

- Add `target_kind` and the content rect to `ScreenCaptureSession`, to its parcels (`registerProducer`, `getProducer`, `sessionChanged`), and to the QPA's mirror `MinisfScreenCaptureSessionInfo` (`hwcomposer_screencapture.cpp:64`).
- Lipstick only attaches to `DISPLAY` sessions, the car compositor only to `VIRTUAL` ones. The service already keeps a list of listeners, so both processes can subscribe at once; each filters in its own query.
- Keep one active session at a time. Two concurrent recorders are not a goal.
- The interface is not upstream: change the transactions in place and deploy droidmedia as a matched set. After installing it, `kill $(pgrep minisfservice)` (init restarts it) or reboot; SELinux denials are in logcat.

### 2.4 QPA structure (`qt5-qpa-hwcomposer-plugin`)

Done by the cleanup (`f30d531`): capture lives in `HwComposerScreenCapture` (`hwcomposer_screencapture.{h,cpp}`), with three hooks in `hwcomposer_backend_v20.cpp` and two env variables. Split it into an encoder-target part (session, EGL surface, `submit()`) and a blitter (EGLImage cache, program, rotation/fit) only when B.2 needs the target without the blitter.

## 3. Option A: mirror with letterbox/pillarbox (test vehicle)

### 3.1 Goal and limits

Any recorder-requested session size works on any phone. Lipstick's current frame is scaled with its aspect ratio preserved into the session's content rect, and the bars are black. It is used to:
1. validate encoder profile/level and IDR-on-demand against a HU or HU emulator early;
2. exercise the session/target/content-rect contract;
3. provide a fallback "mirror" mode.

**Not a product UI:** phone-density UI, the whole lipstick (status bar, notifications) is visible, and no input unless §3.5 is done.

### 3.2 Fit computation (pure function, unit-tested off-device)

Inputs:
- native display `Wn x Hn`, always portrait on these devices;
- lipstick orientation, which decides whether the *content* is landscape;
- session `Ws x Hs`;
- content rect `R` (defaults to the full session);
- policy `fit` (default) | `fill` (crop) | `stretch` (debug only).

Steps:
1. **Rotation.** If the session content rect is landscape (`R.w > R.h`) and the panel is portrait, rotate by `QPA_HWC_SCREENCAP_LANDSCAPE_ROTATION` (270 default); otherwise 0.
   - Today rotation is inferred from an exact transposed size match (`captureSessionRotation()`, `hwcomposer_screencapture.cpp:94`). It becomes `captureFit()`, which also returns the fit.
   - Later refinement: follow lipstick's actual UI orientation, so a portrait-UI phone shown on a landscape HU gets pillarboxed instead of turned sideways. Make it a policy flag: `orientation=auto|fixed`.
2. **Source size after rotation:** `Sw x Sh` (2520x1080 for landscape on the Xperia 5 IV).
3. **Fit:** `scale = min(R.w / Sw, R.h / Sh)`, `dw = round_even(Sw*scale)`, `dh = round_even(Sh*scale)`, `dx = R.x + (R.w-dw)/2`, `dy = R.y + (R.h-dh)/2`. `fill` uses `max` and a texture-coordinate crop instead.
4. **Result:** `{rotation, viewport(dx,dy,dw,dh), texcoord crop}`.

Table to encode as the unit test. The test also covers phones we don't have, which is how panel-size variance is covered without hardware:

| Panel (portrait) | Content (landscape) | 800x480 | 1280x720 | 1920x1080 | 720x1280 portrait HU |
|---|---|---|---|---|---|
| 1080x2520 | 2520x1080 | 800x342 letterbox | 1280x548 | 1920x822 | 548x1280 → pillarbox |
| 1080x2400 | 2400x1080 | 800x360 | 1280x576 | 1920x864 | 576x1280 |
| 1080x2340 | 2340x1080 | 800x368 | 1280x590 | 1920x886 | 590x1280 |
| 720x1600 | 1600x720 | 800x360 | 1280x576 | 1920x864 | 576x1280 |
| 1080x1920 | 1920x1080 | 800x450 | 1280x720 exact | 1920x1080 exact | 720x1280 exact |
| 1440x3200 | 3200x1440 | 800x360 | 1280x576 | 1920x864 | 576x1280 |

(Round sizes to even; the encoder needs even dimensions for 4:2:0.)

### 3.3 QPA changes

- Session acceptance: reject only on invalid size (≤0, > 4096, odd) or a wrong `target_kind`. No longer reject on mismatch with the display.
- Blitter:
  - `glClearColor(0,0,0,1); glClear` on the full surface. It is needed every frame, because the encoder Surface's buffers rotate (the queue holds 2–3), so bars are not guaranteed to persist.
  - `glViewport(fit.viewport)`; the precomputed texture coordinates gain the `fill` crop.
  - Still one draw call plus a clear, still GPU-only.
- Downscale quality: at ≈0.5x, `GL_LINEAR` aliases thin text.
  - Step 1: keep `GL_LINEAR` and evaluate.
  - Step 2, if needed: a 4-tap box filter in the fragment shader (four `texture2D` taps at ±0.25 texel of the *destination* footprint), enabled when `scale < 0.75`.
  - No mipmaps: an EGLImage-backed external buffer cannot be mip-mapped without a copy.
- `mediump` texture coordinates: at 2520 px, mediump (≥10-bit mantissa) can be borderline on some GPUs. Switch the vertex texcoord to `highp` if column wobble appears.
- Handle `requestFrame` (§2.2).

### 3.4 Validation gates for A

Each gate passes only on its own evidence, not by inference from an earlier one (Rev. 4 rule).

- **A.0 Encoder AA profile** (no QPA change):
  - Run `droidscreencapsrc … profile=constrained-baseline level=31` at the native size, with `ffprobe` on a TCP capture.
  - Pass: SPS reports Constrained Baseline / 3.1 (or the platform's closest supported level, logged). `GstForceKeyUnit` sent from the host side (`gst-launch` with a periodic event, or a tiny test app) yields an IDR within one frame period, **also on an idle screen**. The first AU of a session is an IDR with current content, without touching the screen.
- **A.1 Fit:**
  - Unit test of §3.2 passes on the host.
  - On device, with real content, for 800x480, 1280x720, 1920x1080 and 720x1280, with lipstick in portrait and in landscape.
  - Pass: correct aspect (a circle UI element measures round in a decoded frame), centred bars, no stretching, `rotation` and `viewport` logged per generation.
- **A.2 Content rect:** the same runs with `content-rect` simulating margins, e.g. 1280x720 with height margin 120 → R = 0,60,1280,600. Pass: the picture sits inside R and the margins are black.
- **A.3 Quality:** decode frames of a text-heavy page (Settings) at 800x480 and 1280x720; compare `GL_LINEAR` against the 4-tap filter. Pass: text legible, no shimmer while scrolling. Keep the filter only if it measurably helps.
- **A.4 HU-path check:**
  - Feed the A.0 settings into whatever HU or decoder is available: an openauto/aasdk-based desktop HU fed via file/TCP, or at least `ffplay`/`gst` with `avdec_h264` plus a Baseline-only decoder check.
  - Pass: decodes from a mid-stream join after the next IDR and after a forced IDR; no decoder errors over a 10-minute run.
- **A.5 Sequential sessions:** portrait→landscape→800x480→1920x1080 in one lipstick run. Gate 4.3 already covers display-size changes; this adds the fitted sizes. Pass: clean detach/reattach, no stale size.

### 3.5 Optional A input (only if needed for HU testing)

AA touch maps back through the inverse of the fit (§3.2 result) to panel coordinates. It would be injected as a virtual touchscreen via `uinput`, which lipstick picks up through its evdev input stack. This is **not planned**: B2 owns input properly (§4.5). Mention it only if A must be interactive for a demo.

## 4. Option B2: nested car compositor (final)

### 4.1 Architecture

```
AA transport / test harness
   │  session(size, fps, margins, dpi) ─────────────┐
   │  touch events ──────────────┐                  │
   ▼                             ▼                  ▼
gst pipeline:                car-compositor process (Qt Quick + QtWayland compositor)
droidscreencapsrc              QPA: hwcomposer plugin, "encoder" backend (no HWC)
  target=virtual  ──Binder──▶  primary EGL window = encoder input Surface
  ▲ AUs + PTS                  renders client surfaces natively at codec size
  │                            wayland socket "car-0"
  │                                 ▲
  └─ hardware AVC ◀── Surface ◀─────┘ (one composition pass per changed frame)
                                    │
                         car apps (Qt/Silica, QT_QPA_PLATFORM=wayland,
                         WAYLAND_DISPLAY=car-0, DCONF_PROFILE=car)
```

Lipstick is untouched and keeps driving the phone panel. The car UI is a separate Wayland world rendered only into the encoder. Both subscribe to `sailfish.screencap` in `minisfservice` (§2.3).

### 4.2 Why this shape

- **Cost:** one composition pass per changed frame at codec resolution. That is lower than A, which renders lipstick at panel resolution and then downscales. Encoding cost equals A at the same size.
- **Reuse:** it keeps the proven cross-process handoff (recorder ↔ `sailfish.screencap` ↔ renderer) and leaves `droidscreencapsrc` unchanged except `target=virtual`.
- **Features:** a compositor gives several clients, a car-specific launcher/chrome and a later IME. The app-side-only variant (B1) does not.
- **Rejected alternatives:**
  - B1: no IME, no multi-app.
  - A lipstick second output: lipstick's compositor is single-output and the home QML is partly closed.
  - Zero-copy attach of the client buffer into the encoder queue: this is the raw/`attachBuffer` path rejected in Gate 3.

### 4.3 QPA "encoder" backend (`qt5-qpa-hwcomposer-plugin`)

A new backend selected by `QPA_HWC_BACKEND=encoder`, checked in `HwComposerBackend::create()` before any HWC module is opened.
- It must not open the HWC HAL. It loads `libminisf.so` and resolves the four client symbols as `HwComposerScreenCapture::create()/resolve()` do. libminisf's `startThreadPool()` gives the process its Binder threads, as in lipstick.
- **Screen:**
  - Geometry = session size, from the first `VIRTUAL` session or from `QPA_HWC_ENCODER_SIZE` while waiting.
  - Physical size derived from the HU DPI (`QPA_HWC_ENCODER_DPI`), so `QScreen::physicalDotsPerInch` is meaningful.
  - Refresh rate = session fps.
- **Window surface:** the encoder target (§2.4) **is** the window's EGL surface. `eglPresentationTimeANDROID(monotonic now)` precedes every `eglSwapBuffers`.
- **Pacing:**
  - There is no HWC vsync. Emit a synthetic vsync at session fps by posting the same `QEvent::User` that `hwc2_callback_vsync` posts, from a `QTimer`/timerfd that runs **only while the window has pending updates**.
  - Idle produces no swaps and no AUs, which preserves sparse PTS.
  - Never swap faster than fps, but **defer** a frame to the next tick, never drop it: a dropped frame may be the last change before idle (cleanup-plan §5.3).
- **Expose state follows the session**, driven by `sessionChanged` (posted from the Binder thread to the GUI thread):
  - No active generation → report the window as not exposed (`QWindowSystemInterface::handleExposeEvent(window, QRegion())`), so Qt stops rendering and nothing touches EGL.
  - On a new generation: create the surface, expose it, and render a full frame immediately so the first AU is an IDR with content.
  - Generation loss → destroy the surface and unexpose.
- **Size change between sessions:** handled with `handleScreenGeometryChange`. If that turns out fragile in Qt 5.6, restart the compositor per AA session as the documented fallback.
- **Input:** none in QPA. Input is the compositor's job (§4.5).
- **Spike first (B.1 gate):**
  - Confirm that a second process with `EGL_PLATFORM=hwcomposer` can create its *primary* window on the encoder Surface while lipstick holds the HWC. `tools/hwcomposer_screencap_egl_test.cpp` (reverted in `ea98aad`, still at `hwenc-gate4`) did most of this.
  - Confirm `eglBindWaylandDisplayWL` is exposed. libhybris provides it via `eglplatformcommon` for the hwcomposer/fbdev platforms, not for `null`.
  - Stock libhybris is enough for lipstick capture. Here the hwcomposer platform's `CreateWindow` receives a non-`HWComposerNativeWindow` as the process's only window, so B.1 decides whether libhybris `8ac75ab` (exec4 §14) is needed.

### 4.4 Car compositor (new project, e.g. `hybris/mw/sailfish-car-compositor` or a separate repo)

- Qt Quick + QtWayland compositor, using the same compositor API version lipstick links against on this image. Check the installed `qt5-qtwayland` compositor headers first, since lipstick's API usage is the reference.
- Socket `car-0` (`XDG_RUNTIME_DIR`), runs as the user, started by a user systemd unit `car-compositor.service`. Environment: `QT_QPA_PLATFORM=hwcomposer`, `QPA_HWC_BACKEND=encoder`, `EGL_PLATFORM=hwcomposer`. Not part of `lipstick.service`.
- Wayland server-side buffers come from libhybris `server_wlegl` (the same mechanism lipstick uses). Clients are ordinary Qt Wayland clients.
- **Window policy (v1):** one fullscreen client at a time, sized to the content rect (codec size − margins). The margins are painted black by the compositor. A minimal launcher QML lists allow-listed car apps.
- **Protocol surface:** whatever Sailfish Qt clients require from lipstick for basic operation. Start with `wl_shell`/`qt_surface_extension`/`qt_extended_surface` as provided by the QtWayland compositor, then log unhandled-interface warnings from a Silica client to see what else is missing.
- **Damage-driven repaint:** the scene graph repaints only on client commit. Frame callbacks are sent after the encoder swap, which throttles clients to session fps.
- **Lifecycle:**
  - `VIRTUAL` session start → expose → launch or resume the selected app.
  - Session end → unexpose. Clients are throttled by withheld frame callbacks and keep running.
  - The compositor survives AA disconnects; it exits when the car service is stopped.

### 4.5 Input

- **Local IPC from the AA transport (or a test tool) to the compositor:** a Unix socket with a minimal message set: `touch(id, action, x, y)` in **codec coordinates**, `key(code, action)`, and later `rotary`.
- **Compositor:**
  - subtract the content-rect origin; drop points outside it;
  - deliver to the focused surface through the compositor's seat/touch API (`QWaylandInputDevice`/`QWaylandSeat`, depending on Qt version);
  - map keys such as "back" to the app's back gesture equivalent.
- **Test tool:** `car-touch` CLI on the host or phone that replays taps and swipes at codec coordinates, for gates without a HU.

### 4.6 Scaling and DPI for clients

- Silica's `Theme.pixelRatio` comes from dconf (`/desktop/sailfish/silica/theme_pixel_ratio`), not from the Wayland output. Give car apps a **separate dconf profile** (`DCONF_PROFILE=car`) whose top db overrides the pixel ratio. Compute it from the HU DPI and the target physical size, so touch targets are ≥ ~9 mm at arm's length.
  - Check which other Silica keys (font sizes, icon sizes) derive from it, and whether an app reads them at start only. Restart the app on change.
- Plain Qt Quick apps follow `QT_SCALE_FACTOR` or the output scale. Use whichever the client stack honours.
- **Orientation:** the output is fixed landscape (or fixed portrait for portrait HUs). Car apps must set `allowedOrientations` to match. The compositor never rotates.

### 4.7 App launching and integration

- Booster/invoker processes are pre-connected to lipstick's display, so car apps are launched **directly** (binary or `sailfish-qml <app>`) with the car environment, never through `invoker`.
- D-Bus single-instance apps: a second instance cannot own the same bus name, so v1 targets **dedicated car apps** or apps with an explicit car mode. Mirroring arbitrary phone apps is a non-goal for v1.
- **Later gates:**
  - IME: check whether the Sailfish maliit setup can attach to a second compositor, or provide a car-specific on-screen keyboard. AA HUs restrict text input while driving anyway.
  - Notifications/system dialogs: none in v1; the policy is decided later.

### 4.8 Validation gates for B2

- **B.0 Target kind:** §2.3 in the service and lipstick. Pass: `target=display` records as before; a `target=virtual` session is ignored by lipstick (logged, no attach).
- **B.1 Second-process EGL spike** (§4.3 spike): a standalone test renders animated content into a `VIRTUAL` session at 1280x720 while lipstick runs normally, recorded by `droidscreencapsrc target=virtual`. Pass: decodable stream with correct content, sparse PTS when the animation pauses, no lipstick impact, `eglBindWaylandDisplayWL` resolvable.
- **B.2 Encoder QPA backend with a plain Qt Quick app** (no compositor yet; this is effectively B1 and is the stepping stone): `QT_QPA_PLATFORM=hwcomposer QPA_HWC_BACKEND=encoder qmlscene test.qml`. Pass:
  - 1280x720 native rendering (pixel-exact 1 px lines in decoded frames);
  - synthetic vsync caps the swap rate at fps, and the last frame before idle is sent;
  - idle produces 0 AUs;
  - CPU/GPU idle when nothing changes;
  - session stop/start re-exposes cleanly.
- **B.3 Car compositor with a Qt Quick client:** a client on `car-0` is composited into the encoder at 800x480, 1280x720 and 1920x1080 with simulated margins. Pass: correct content rect, black margins, frame callbacks throttle the client to fps, no leaks across 20 client start/stops.
- **B.4 Input:** `car-touch` taps/swipes reach the client at the correct coordinates, including margin offset and out-of-rect rejection; flick/scroll gestures behave.
- **B.5 Silica client and scaling:** a simple Silica app (pages, list, pulley menu) under `DCONF_PROFILE=car` at 800x480 and 1280x720. Pass: layout fits, text legible, page navigation works by touch. Record which lipstick-only protocols the client complains about and how it degrades.
- **B.6 Lifecycle:**
  - AA-like session churn: start/stop, resolution change between sessions, recorder kill, compositor restart, client crash, `minisfservice` restart.
  - Pass: no hang, no stale generation, lipstick never restarted, the compositor recovers or restarts by unit policy.
- **B.7 Power and latency comparison vs A:**
  - Same scrolling script for 2 min at 1280x720 in both. Sample `/sys/class/power_supply/*/current_now` and lipstick/compositor CPU.
  - Measure end-to-end latency from a touch injected at a timestamp to the AU PTS of the first changed frame.
  - Pass: B2 is ≤ A on power and has a documented latency.
- **B.8 HU check:** as A.4, but with the car compositor as the source and touch flowing back through the test transport or emulator.

## 5. Order of work

1. §2.1/§2.2 encoder profile, sync frame and repaint request, then A.0.
2. §3 fit/letterbox, A.1–A.3 and A.5. A becomes usable for HU experiments (A.4).
3. §2.3 `target_kind`/content rect, then B.0.
4. B.1 spike. **Decision point:** if a second-process primary window on the encoder Surface fails, fall back to a private in-process handoff. That means a droidmedia call exposing the encoder's `ANativeWindow` to a same-process compositor that also runs the gst pipeline, and it drops the Binder session for B2 only. Re-plan before continuing.
5. B.2 → B.8.

Each step is a separate build/deploy set; droidmedia (Android side and `droidmedia-devel`) is deployed as a matched set whenever §2.1–§2.3 change (README, "Build and deploy").

## 6. Removal list

Done by the cleanup (`hwenc-gate4..hwenc`, cleanup-plan §2): the legacy raw-capture path, the Gate 0–2 tools, the legacy service calls and libminisf symbols, the diagnostic QPA env variables and test bars, fps pacing, and `width=0` discovery. Still open:
- the positional `droid_media_screen_capture_new()` (§2.1);
- `captureSessionRotation()`, replaced by the fit (§3.2).

## 7. Open questions

1. Which HU or HU emulator is available for A.4/B.8? This decides how soon the profile/level assumptions are confirmed.
2. Is portrait-HU support (720x1280 etc.) required in v1?
3. Which first car app(s) to target in B.5? A dedicated Qt Quick app lowers B.5 risk considerably compared to an existing Silica app.
4. Is a separate `car-compositor` repo preferred, or a new `hybris/mw` submodule like the existing ones?
