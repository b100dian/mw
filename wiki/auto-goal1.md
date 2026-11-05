# Android Auto Goal 1: AA-resolution capture. Option A (mirror, test) and Option B2 (car compositor, final)

**Date:** 2026-10-13, revised 2026-10-23
**Status:** Plan. Nothing implemented. The baseline is the cleaned-up `hwenc` (`../README.md`, `cleanup-plan.md`): `sailfish.screencap` is hosted by `minisfservice`, libminisf receives session changes pushed by the service, and lipstick sends every frame it renders. **Gate 5** (`gate-5.md`) is the first step: the shared work (§2), Option A (§3) and the B2 spike, which is everything the upstream repositories need.
**Basis:** `../README.md`, `cleanup-plan.md`, `hwc-h264-encoding-revision4.md`, `hwc-h264-exec4.md`
**Scope:** Get a Sailfish UI into an H.264 stream at a resolution the Android Auto (AA) head unit (HU) negotiates, for any phone panel size, keeping the zero-CPU-copy hardware-encode path.
- **Option A** mirrors lipstick, scaled with letterbox/pillarbox. It is a test vehicle.
- **Option B2** is a dedicated nested Wayland "car compositor" that renders natively at the HU size. It is the product target.

**Out of scope:** the AA transport (USB/Wi-Fi, AAP framing, TLS, service discovery), audio, and AA sensor/navigation channels. The plan only fixes the interfaces the transport will need: encoded AUs, keyframe requests, a session start/stop with size/fps/margins/DPI, and touch input. The transport does not need GStreamer: it can call the droidmedia API directly, as `screencap_surface_capture_test` does. `droidscreencapsrc` is a thin wrapper for tests and GStreamer-based transports.

## 1. Requirements derived from AA video

| AA concept | What it means here |
|---|---|
| HU offers video configs: codec resolution 800x480, 1280x720, 1920x1080 (newer: 2560x1440, 3840x2160, portrait 720x1280/1080x1920/1440x2560), fps 30/60 | The encoder session size is one of a fixed set and is **unrelated to the phone panel**. QPA must stop requiring session size == display size. |
| `width_margin` / `height_margin` | The HU crops margins off the decoded frame. The visible UI area is `codec size − margins`, centred. The session must carry a **content rect**. |
| `density` (DPI, typically ~120–200) | UI scale. Irrelevant to A (it mirrors phone UI). For B2 it drives the client pixel ratio. |
| H.264 elementary stream, IDR self-contained | Already the `droidscreencapsrc` contract (README, "output"). |
| Decoder capability | Assume **Constrained Baseline** until a real HU or emulator proves otherwise. This is an assumption, not an AA requirement: no HU has confirmed it, which is why Gate 5.3 exists. The level follows from size and fps (H.264 Table A-1): 720p30 needs 3.1, 720p60 3.2, 1080p30 4.0, 1080p60 4.2; the encoder computes it from the session when none is given (`gate-5.md` §1.1). Current output is **High** (level 5.0 in exec4) with no profile/level set (`droidmedia/droidmediascreencapture.cpp:117–124`). |
| Video focus gain, error recovery, unacked-frame flow control | Need **low latency** (done: each AU is pushed at once, gst-droid `3a7e560`) and **IDR on demand**. With Surface input, `request-sync` applies to the *next input frame*, so on an idle screen an IDR also needs a repaint (§2.2). |

The phone panel is not a parameter of the stream. For A, panel size affects only the fit math (§3.2). For B2 it does not matter at all.

## 2. Work shared by A and B2 (Gate 5)

The concrete change list per repository is in `gate-5.md` §1. The design points:

### 2.1 Encoder (droidmedia)

- `droid_media_screen_capture_new()` takes the existing `DroidMediaCodecEncoderMetaData` (size, fps, bitrate, `codec_specific.h264.profile/level`) instead of positional arguments. No new struct and no shim: the API is not upstream. Profile and level go through the block the camera encoder already uses (`droidmediacodec.cpp:455–473`): a level of 0 becomes `ACodec::getAVCLevelFor()`, so AA only picks a profile and the lowest legal level comes out by itself.
- The target kind (`DISPLAY` | `VIRTUAL`) and the content rect are session properties, set with `droid_media_screen_capture_set_target()` before `start()`. Whoever starts the recording picks the target: the mirror asks for `DISPLAY`, the car UI for `VIRTUAL`.
- `droid_media_screen_capture_request_sync_frame()` sets `request-sync` **and** asks the compositor to repaint (§2.2), in one call.
- Validate profile/level acceptance on device (Gate 5.0): Codec2 may silently ignore an unsupported profile. Baseline is known to work, because every camera recording on this device already configures it through the same block.
- Not `repeat-previous-frame-after`: Android 14's GraphicBufferSource repeats the last frame 10 times after every change and can drop a real frame that follows a repeat (cleanup-plan §5.3).

### 2.2 Keyframes and repaint

- In `droidscreencapsrc`: `profile`, `level`, `target` and `content-rect` properties. An upstream `GstForceKeyUnit` event, handled in `GstBaseSrcClass::event`, calls `request_sync_frame`, so an AA transport element only has to send that standard event. The overload "drop until keyframe" path calls it too. `h264parse` already puts the SPS profile/level into the caps.
- **Repaint request:** `requestFrame(generation)` on the service reaches the subscribed compositors as a oneway `frameRequested`. libminisf hands it, and session changes, to a callback; the compositor queues `QQuickWindow::update()` on its window (`QWindow::requestUpdate()` only schedules a sync, and the threaded render loop does not render an unchanged scene; `gate-5.md` §1.3). The recorder sends it with each sync-frame request. The first IDR needs no request: the compositor repaints on the session change and attaches inside that frame, so the first AU is the current screen (today it waits for the next screen change, README "Known limits"), and a forced IDR also works on an idle screen.

### 2.3 Session contract (droidmedia `sailfish.screencap`)

The service holds one session, keyed by a generation, and pushes every change to its listeners (`screen_capture_service.h`). Two renderers will exist (lipstick for A, the car compositor for B2), so the session must say **who should render into it**:

- `ScreenCaptureSession` (and its parcels) gains `target_kind` and the content rect. Lipstick only attaches to `DISPLAY` sessions, the car compositor only to `VIRTUAL` ones. The service already keeps a list of listeners, so both can subscribe at once.
- Keep one active session at a time. Two concurrent recorders are not a goal.
- **Matched set:** `writeSession()`/`readSession()` carry the whole session in every parcel, the interface descriptors have no version suffix, and the QPA's `MinisfScreenCaptureSessionInfo` declares the layout of `ScreenCaptureSession` (content rect as a `DroidMediaRect`) field for field. A new field changes droidmedia and the QPA together, and the four packages are built and installed as one set. Nothing is shipped upstream yet, so no older peer has to keep working; versioning can be added when a released interface first changes (`gate-5-tweaks.md` §2).

### 2.4 QPA structure (`qt5-qpa-hwcomposer-plugin`)

Done by the cleanup (`f30d531`): capture lives in `HwComposerScreenCapture` (`hwcomposer_screencapture.{h,cpp}`), with three hooks in `hwcomposer_backend_v20.cpp`. Its two halves serve different modes:
- the **blitter** (`render()`: EGLImage of lipstick's presented buffer → one quad into the encoder Surface) exists only for `DISPLAY`. In B2 the scene graph renders straight into the encoder Surface, so there is nothing to copy;
- the **session/target** half (attach per generation, EGL surface on the encoder Surface, presentation time and swap) is what B2 shares.

Split the class only when the encoder backend (§4.3) needs the target half.

## 3. Option A: mirror with letterbox/pillarbox (test vehicle)

### 3.1 Goal and limits

Any recorder-requested session size works on any phone. Lipstick's current frame is scaled with its aspect ratio preserved into the session's content rect, and the bars are black. It is used to:
1. validate encoder profile/level and IDR-on-demand against a HU or HU emulator early;
2. exercise the session/target/content-rect contract;
3. provide a fallback "mirror" mode.

**Not a product UI:** phone-density UI, the whole lipstick (status bar, notifications) is visible, and no input unless §3.5 is done.

### 3.2 Fit computation

A pure function, so it can be checked on the host, without the device, against the table below, including panels we don't have. The QPA has no test suite; a small host-only test program is enough.

Inputs:
- native display `Wn x Hn`, always portrait on these devices;
- lipstick orientation, which decides whether the *content* is landscape;
- session `Ws x Hs`;
- content rect `R` (defaults to the full session);
- policy `fit` (default) | `fill` (crop) | `stretch` (debug only).

Steps:
1. **Rotation.** If the session content rect is landscape (`R.w > R.h`) and the panel is portrait, rotate by `QPA_HWC_SCREENCAP_LANDSCAPE_ROTATION` (270 default); otherwise 0.
   - Today rotation is inferred from an exact transposed size match (`captureSessionRotation()`, `hwcomposer_screencapture.cpp:94`). It becomes `captureFit()`, which also returns the fit.
   - Consequence of this rule: a landscape session always rotates, even while lipstick's UI is portrait, and a portrait session never does. That is today's known limit (README "Known limits"), unchanged.
   - Later refinement, not Gate 5: follow lipstick's actual UI orientation, so a portrait UI on a landscape HU is pillarboxed instead of turned sideways. Lipstick already reports it: `LipstickCompositor::setScreenOrientation` calls `QWindowSystemInterface::handleScreenOrientationChange(primaryScreen, …)` (`lipstick/src/compositor/lipstickcompositor.cpp:774`), so the QPA can read `QScreen::orientation()` instead of guessing from the size. Inverted landscape vs landscape also gives the direction, which replaces `QPA_HWC_SCREENCAP_LANDSCAPE_ROTATION`. Caveat: `QScreen::orientation()` only updates for values in the screen's `orientationUpdateMask`, which lipstick does not set; the QPA would have to, and jolla-home's QML `Screen.orientation` would then start changing too.
2. **Source size after rotation:** `Sw x Sh` (2520x1080 for landscape on the Xperia 5 IV).
3. **Fit:** `scale = min(R.w / Sw, R.h / Sh)`, `dw = round_even(Sw*scale)`, `dh = round_even(Sh*scale)`, `dx = R.x + (R.w-dw)/2`, `dy = R.y + (R.h-dh)/2`. `fill` uses `max` and a texture-coordinate crop instead.
4. **Result:** `{rotation, viewport(dx,dy,dw,dh), texcoord crop}`.

| Panel (portrait) | Content (landscape) | 800x480 | 1280x720 | 1920x1080 | 720x1280 portrait HU, rotation 0 |
|---|---|---|---|---|---|
| 1080x2520 | 2520x1080 | 800x342 letterbox | 1280x548 | 1920x822 | 548x1280 pillarbox |
| 1080x2400 | 2400x1080 | 800x360 | 1280x576 | 1920x864 | 576x1280 |
| 1080x2340 | 2340x1080 | 800x368 | 1280x590 | 1920x886 | 590x1280 |
| 720x1600 | 1600x720 | 800x360 | 1280x576 | 1920x864 | 576x1280 |
| 1080x1920 | 1920x1080 | 800x450 | 1280x720 exact | 1920x1080 exact | 720x1280 exact |
| 1440x3200 | 3200x1440 | 800x360 | 1280x576 | 1920x864 | 576x1280 |

(Round sizes to even; the encoder needs even dimensions for 4:2:0.) The last column is the unrotated panel fitted into a portrait HU, as step 1 produces for a portrait session: it shows the panel as is, so a landscape UI appears sideways in it, and a portrait UI upright.

### 3.3 QPA changes

- Session acceptance: reject only on invalid size (≤0, > 4096, odd) or a wrong `target_kind`. No longer reject on mismatch with the display.
- Blitter:
  - `glClear` of the full surface every frame. After a swap EGL leaves the buffer contents undefined, so uncleared bars would show older frames from that buffer slot. Today's full-surface quad needs no clear; letterboxing does. On Adreno a full clear also saves loading the old contents into tile memory.
  - `glViewport(fit.viewport)`; the precomputed texture coordinates gain the `fill` crop.
  - Still one draw call plus a clear, still GPU-only.
- Downscale quality: `GL_LINEAR` *is* bilinear, but it reads only 2x2 texels however far the image shrinks, so at ≈0.5x and below it skips source pixels and thin text aliases.
  - Step 1: keep `GL_LINEAR` and evaluate.
  - Step 2, if needed: a 4-tap box filter in the fragment shader (four bilinear taps at ±0.25 texel of the *destination* footprint, about 16 source texels), enabled when `scale < 0.75`.
  - Not trilinear (`GL_LINEAR_MIPMAP_LINEAR`): mipmaps on an EGLImage-backed texture would replace its storage, which is a copy.
- `mediump` texture coordinates: at 2520 px, mediump (≥10-bit mantissa) can be borderline on some GPUs. Switch the vertex texcoord to `highp` if column wobble appears.
- Handle the libminisf callback (§2.2): queue `update()` on lipstick's window.

### 3.4 Validation gates for A

Gate 5.0–5.3 (`gate-5.md` §2): encoder profile, session contract and repaint, letterbox (fit, content rect, quality, sequential sessions), HU path.

### 3.5 Optional A input (only if needed for HU testing)

AA touch maps back through the inverse of the fit (§3.2 result) to panel coordinates. It would be injected as a virtual touchscreen via `uinput`, which lipstick picks up through its evdev input stack. This is **not planned**: B2 owns input properly (§4.5). Mention it only if A must be interactive for a demo.

## 4. Option B2: nested car compositor (final)

### 4.1 Architecture

```
AA transport / test harness
   │  session(size, fps, margins, dpi) ─────────────┐
   │  touch lines → FIFO ────────┐                  │
   ▼                             ▼                  ▼
droidmedia API (or            car compositor (qt-runner based: Qt Quick + QtWayland)
droidscreencapsrc)             QPA: hwcomposer plugin, "encoder" backend (no HWC)
  target=VIRTUAL  ──Binder──▶  primary EGL window = encoder input Surface
  ▲ AUs + PTS                  renders client surfaces natively at codec size
  │                            own wayland socket
  │                                 ▲
  └─ hardware AVC ◀── Surface ◀─────┘ (one composition pass per changed frame)
                                    │
                         car apps (Qt/Silica, QT_QPA_PLATFORM=wayland,
                         WAYLAND_DISPLAY=<socket>, DCONF_PROFILE=car)
```

Lipstick is untouched and keeps driving the phone panel. The car UI is a separate Wayland world rendered only into the encoder. Both subscribe to `sailfish.screencap` in `minisfservice` (§2.3).

### 4.2 Why this shape

- **Cost:** one composition pass per changed frame at codec resolution. That is lower than A, which renders lipstick at panel resolution and then downscales. Encoding cost equals A at the same size.
- **Reuse:** it keeps the proven cross-process handoff (recorder ↔ `sailfish.screencap` ↔ renderer); the recorder only sets `target=VIRTUAL`.
- **Features:** a compositor gives several clients, a car-specific launcher/chrome and a later IME. The app-side-only variant (B1) does not.
- **Upstream footprint:** after Gate 5, only the optional encoder backend touches an upstream repository. The compositor is an application.
- **Rejected alternatives:**
  - B1: no IME, no multi-app.
  - A lipstick second output: lipstick's compositor is single-output and the home QML is partly closed.
  - Zero-copy attach of the client buffer into the encoder queue: this is the raw/`attachBuffer` path rejected in Gate 3.

### 4.3 QPA "encoder" backend (`qt5-qpa-hwcomposer-plugin`)

EGL renders into whatever native window it is given, and the encoder's input Surface is one. HWC only displays buffers. So the backend makes the encoder Surface the window, and Qt's scene graph renders into the encoder's buffers as it would into a screen's. Lipstick capture already creates an EGL surface on that Surface (`hwcomposer_screencapture.cpp:405`) with stock libhybris.

Selected by `QPA_HWC_BACKEND=encoder` in `HwComposerBackend::create()`, before any HWC module is opened. It implements the backend interface (`hwcomposer_backend.h:108–117`):
- `display()`: `EGL_DEFAULT_DISPLAY`;
- `createWindow()`: the session's encoder Surface (`minisf_screen_capture_target_native_window`), not an HWC window;
- `swap()`: sleep until `lastSwap + 1/fps`, `eglPresentationTimeANDROID(monotonic now)`, then `eglSwapBuffers`, which queues the frame to the encoder. The blocking swap is the pacing (below);
- `requestUpdate()`: returns `false`, so Qt's default update timer drives the render loop;
- `getScreenSizes()` / `refreshRate()`: the size from `QPA_HWC_ENCODER_SIZE`, the HU DPI (`QPA_HWC_ENCODER_DPI`) for the physical size, session fps.

libminisf is loaded and resolved as `HwComposerScreenCapture::create()/resolve()` do; its `startThreadPool()` gives the process its Binder threads.

- **The window exists before the Surface does.** `QEglFSWindow::create()` creates the EGL surface at once and `resetSurface()` calls `qFatal` on failure (`qeglfswindow.cpp:73–115`). In encoder mode the surface creation is deferred until a `VIRTUAL` session exists.
- **Expose follows the session**, driven by the libminisf callback (§2.2), posted to the GUI thread:
  - new generation → create the surface, expose, render a full frame at once so the first AU is an IDR with content;
  - session end or replacement → unexpose first (the threaded render loop stops rendering that window), then destroy the surface; a new session creates a new one.
- **The size is fixed per compositor process** (v1 rule). A `VIRTUAL` session whose size differs from the window is rejected and logged, and the transport restarts the unit, which starts with the new `QPA_HWC_ENCODER_SIZE`. No `handleScreenGeometryChange` in Qt 5.6. The deferred surface creation above stays: the Surface still appears only with the session.
- **Pacing: the swap blocks to fps.** There is no HWC vsync, and none is synthesised. `swap()` sleeps until one frame period after the previous swap, which is what a vsync-blocking swap does on a real display: never faster than fps, and never a dropped frame, so the last change before idle is sent (cleanup-plan §5.3). Idle produces no swaps and no AUs, which preserves sparse PTS.
- **Input:** none in the backend. A generic plugin injects it (§4.5).
- **libhybris:** its hwcomposer platform takes any `ANativeWindow` (`eglplatform_hwcomposer.cpp:63–65`), and `eglBindWaylandDisplayWL` is in the shared platform code (`eglplatformcommon.cpp:68`), so stock libhybris should do; `8ac75ab` is likely not needed. The Gate 5.4 spike confirms it, and that a process on this platform works without ever opening HWC.

### 4.4 Car compositor: based on qt-runner

`mw/qt-runner` is a nested compositor on the QtWayland compositor API lipstick also uses (Qt 5.4 era: `QWaylandQuickCompositor`, `QWaylandSurfaceItem`). Today it runs as a lipstick client (`QT_QPA_PLATFORM=wayland`) and shows on the phone. It already has:
- a free socket picked under the runtime dir, and the app started with `WAYLAND_DISPLAY`, `QT_WAYLAND_FORCE_DPI` and `QT_SCALE_FACTOR` (`src/runner.cpp`);
- one fullscreen client, with touch forwarded by the surface item (`qml/WindowContainer.qml`);
- frame callbacks after rendering (`afterRendering` → `sendCallbacks`);
- per-app settings; server-side buffers through libhybris `server_wlegl`.

Limits: `wl_shell` only, no dialogs (its README).

Run as `QT_QPA_PLATFORM=hwcomposer QPA_HWC_BACKEND=encoder EGL_PLATFORM=hwcomposer` from a user systemd unit (not part of `lipstick.service`), it becomes the car compositor. Missing:
1. **Input:** load the `remotetouch` plugin (§4.5).
   - **Client environment:** the runner copies its own environment to the client (`src/runner.cpp:64`). In encoder mode it must set `QT_QPA_PLATFORM` and `EGL_PLATFORM` to `wayland` and drop `QPA_HWC_*` and `QT_QPA_GENERIC_PLUGINS`. Otherwise the client would also render into the encoder and read the touch FIFO.
2. **Content rect:** the client is sized to codec size − margins; the margins are black QML.
3. **Lifecycle:** follow `VIRTUAL` sessions instead of the phone UI. On session end, withheld frame callbacks throttle the clients, which keep running. The compositor survives AA disconnects; only a session at another size restarts it (§4.3).
4. **Client throttling at session fps:** send frame callbacks after the encoder swap (`frameSwapped`), unless `afterRendering` proves close enough.
5. **A car launcher** instead of the settings page (§4.7).
6. **Protocols:** log unhandled-interface warnings from a Silica client to see what Sailfish clients need beyond `wl_shell`/`qt_surface_extension`.

### 4.5 Input

There is no touchscreen behind the encoder window, so input arrives as text and is injected into Qt:
- **`remotetouch`**, a Qt generic plugin (`QT_QPA_GENERIC_PLUGINS=remotetouch:<fifo>`, default `$XDG_RUNTIME_DIR/remotetouch`), works like Qt's `evdevtouch`:
  - It creates the FIFO, reads lines from it, reopens it at EOF, and calls `QWindowSystemInterface::handleTouchEvent` on a registered `QTouchDevice`.
  - QGuiApplication loads generic plugins under any QPA. So the plugin works for `qmlscene` on the encoder backend (Gate 5.5) as well as for the compositor, whose surface item forwards the touch to the client as today.
  - It ships with the compositor, not upstream.
  - lipstick2vnc's input can't be reused: it writes into the real touchscreen's evdev node (`lipstick2vnc/src/screentovnc.cpp:311`), and lipstick reads that node.
- **Protocol:** one event per line, in **codec coordinates**: `d <id> <x> <y>` (down), `m <id> <x> <y>` (move), `u <id>` (up); later `k <code> <0|1>` for keys such as "back", and rotary input.
  - The window is the session size, so codec coordinates are window coordinates.
  - Touches in the margins land on the black margin item. Qt's item mapping ignores them, so no explicit content-rect test is needed.
- **Sources:**
  - the AA transport writes the same lines;
  - scripted gates use `printf 'd 0 640 360\nu 0\n' > "$XDG_RUNTIME_DIR/remotetouch"`;
  - interactive tests use the remote view: video from the test tool over SSH into mpv (`gate-5.md` §3), and touch from an mpv Lua script back over a second SSH connection into the FIFO, below.
- **Touch from mpv** (B.4): an mpv Lua script (`--script=remote-touch.lua`, about 50 lines) maps the pointer to codec pixels and writes `d`/`m`/`u` lines to `io.popen("ssh phone 'cat > \"$XDG_RUNTIME_DIR/remotetouch\"'", "w")`, flushing each line.
  - Mapping: `MBTN_LEFT` is bound with `{complex = true}` for down and up, and `MOUSE_MOVE` for moves while the button is held. The `mouse-pos` property, minus the `osd-dimensions` margins, is scaled to the `video-params` size.
  - One pointer only: no pinch.
  - Needs mpv 0.33 or later, built with Lua (most distribution builds are). Start mpv with `--no-input-default-bindings`, so that clicks only reach the script.

### 4.6 Scaling and DPI for clients

- Silica's `Theme.pixelRatio` comes from dconf (`/desktop/sailfish/silica/theme_pixel_ratio`), not from the Wayland output. Give car apps a **separate dconf profile** (`DCONF_PROFILE=car`) whose top db overrides the pixel ratio. Compute it from the HU DPI and the target physical size, so touch targets are ≥ ~9 mm at arm's length.
  - Check which other Silica keys (font sizes, icon sizes) derive from it, and whether an app reads them at start only. Restart the app on change.
- Plain Qt Quick apps follow `QT_SCALE_FACTOR`/`QT_WAYLAND_FORCE_DPI`, as qt-runner already sets them.
- **Orientation:** the output is fixed landscape (or fixed portrait for portrait HUs). Car apps must set `allowedOrientations` to match. The compositor never rotates.

### 4.7 App launching and integration

- A **car launcher** in the compositor, with its own `.desktop` entries, separate from lipstick's. Apps are started directly with the car environment, never through `invoker`: invoker's `--single-instance` asks lipstick to raise an existing window, and the boosters are already connected to lipstick's display.
- The app does not also run on the phone. Many Sailfish apps own a fixed session-bus name, so the launcher checks whether that name is already owned and says so instead of starting a broken second copy.
- Known limit: opening the app on the phone while it runs in the car goes through invoker, which tries to raise a window lipstick doesn't have.
- **Later gates:**
  - IME: check whether the Sailfish maliit setup can attach to a second compositor, or provide a car-specific on-screen keyboard. AA HUs restrict text input while driving anyway.
  - Notifications/system dialogs: none in v1; the policy is decided later.

### 4.8 Validation gates for B2

B.0–B.2 are Gate 5: target kind (5.1), the second-process spike (5.4), the encoder backend with a plain Qt Quick app (5.5).

- **B.3 Car compositor with a Qt Quick client:** a client is composited into the encoder at 800x480, 1280x720 and 1920x1080 with simulated margins. Pass: correct content rect, black margins, frame callbacks throttle the client to fps, no leaks across 20 client start/stops.
- **B.4 Input:** scripted taps and swipes through the FIFO, then interactive use through the remote view. Pass: touches reach the client at the correct coordinates, including the margin offset, and touches in the margins are ignored; flick and scroll gestures behave.
- **B.5 Silica client and scaling:** a simple Silica app (pages, list, pulley menu) under `DCONF_PROFILE=car` at 800x480 and 1280x720. Pass: layout fits, text legible, page navigation works by touch. Record which lipstick-only protocols the client complains about and how it degrades.
- **B.6 Lifecycle:**
  - AA-like session churn: start/stop, a resolution change between sessions (rejected session, unit restart, §4.3), recorder kill, compositor restart, client crash, `minisfservice` restart.
  - Pass: no hang, no stale generation, lipstick never restarted, the compositor recovers or restarts by unit policy.
- **B.7 Power and latency comparison vs A:**
  - Same scrolling script for 2 min at 1280x720 in both. Sample `/sys/class/power_supply/*/current_now` and lipstick/compositor CPU.
  - Measure end-to-end latency from a touch injected at a timestamp to the AU PTS of the first changed frame.
  - Pass: B2 is ≤ A on power and has a documented latency.
- **B.8 HU check:** as Gate 5.3, but with the car compositor as the source and touch flowing back through the test transport or emulator.

## 5. Order of work

1. **Gate 5** (`gate-5.md`): §2, Option A, the B2 spike and, if it passes, the encoder backend. This is the content of the upstream PR.
2. **Decision point at Gate 5.4:** if a second-process primary window on the encoder Surface fails, fall back to a private in-process handoff. That means a droidmedia call exposing the encoder's `ANativeWindow` to a same-process compositor that also runs the encoder, and it drops the Binder session for B2 only. Re-plan before continuing.
3. B.3 → B.8 in the qt-runner-based compositor. Only the encoder backend touches an upstream repository, if it did not make the PR.

## 6. Removal list

Done by the cleanup (`hwenc-gate4..hwenc`, cleanup-plan §2): the legacy raw-capture path, the Gate 0–2 tools, the legacy service calls and libminisf symbols, the diagnostic QPA env variables and test bars, fps pacing, and `width=0` discovery. Still open, both in Gate 5:
- the positional `droid_media_screen_capture_new()` (§2.1);
- `captureSessionRotation()`, replaced by the fit (§3.2).

Not added, so nothing to remove later: a `requestFrame` in `start()` (`gate-5.md` §1.1).

## 7. Open questions

1. Which HU or HU emulator is available for Gate 5.3/B.8? This decides how soon the profile/level assumptions are confirmed.
2. Is portrait-HU support (720x1280 etc.) required in v1?
3. Which first car app(s) to target in B.5? A dedicated Qt Quick app lowers B.5 risk considerably compared to an existing Silica app.
4. Car mode in upstream qt-runner, or a fork?
