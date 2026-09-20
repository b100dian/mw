# HWC → H.264 Encoding — Execution 3.1

**Date:** 2026-09-20  
**Basis:** `wiki/hwc-h264-encoding-revision3.1.md`  
**Current gate:** Gate 3 — passed  
**Status:** Gates 2.2, 2.3, and 3 passed on-device. Real QPA/HWC content is hardware-encoded correctly with the device-required vertical flip. Execution is ready to proceed to Gate 4.

## 1. Starting point

The current `hwenc` heads already contain the implementation intended for the first Revision 3.1 device gate:

| Component | Revision | Relevant state |
|---|---:|---|
| `qt5-qpa-hwcomposer-plugin` | `93cf231` | Gate 2.2 post-primary-swap scheduling and one-frame test-bars mode |
| `droidmedia` | `ccee726` | Proven Gate 2.1 recorder Binder-pool/lifecycle implementation |
| libhybris hwcomposer EGL platform | `8ac75ab` as recorded by Revision 3.1 | Proven generic `ANativeWindow *` ownership fix |

The Gate 2.1a, 2.1b, and repeated Gate 2.1 device results recorded in Revision 3.1 remain the baseline. In particular, the remote producer and both the libhybris `null` and `hwcomposer` EGL paths passed at `1080x2520` after the recorder Binder thread pool was started.

No source changes were made during this execution round before Gate 2.2. The required QPA implementation was already committed at `93cf231`; the work here was to audit it and define the next device run without mixing later-gate changes into the scheduling proof.

## 2. Gate 2.2 source audit

### 2.1 Re-entrant capture was removed

`HWC2Window::present()` in `qt5-qpa-hwcomposer-plugin/hwcomposer/hwcomposer_backend_v20.cpp` no longer acquires the recorder target, creates an EGL context/surface, renders, or swaps the encoder surface.

After normal HWC validation, client-target submission, and display presentation, it records only:

- the immediate `HWComposerNativeWindowBuffer *` candidate;
- a boolean indicating that a candidate is available.

The outer `HwComposerBackend_v20::swap()` performs the primary `eglSwapBuffers(display, surface)`. Only after that call returns successfully does it invoke `HWC2Window::captureAfterPrimarySwapFromBackend()`.

This establishes the ordering required by Revision 3.1:

```text
primary eglSwapBuffers()
  -> native-window queueBuffer()
     -> HWC2Window::present(): record candidate only
  <- queueBuffer()/present return
<- primary eglSwapBuffers() returns
-> captureAfterPrimarySwap()
   -> target acquisition/EGL setup/test-bars encoder swap
```

There is no capture EGL or Binder target acquisition in `present()`.

### 2.2 Gate is deliberately test-bars-only and one-frame by default

Capture is enabled only if both of these are set before the QPA window is created:

```text
QPA_HWC_SCREENCAP=1
QPA_HWC_SCREENCAP_TEST_BARS=1
```

`QPA_HWC_SCREENCAP_FRAME_LIMIT` is clamped to at least one and defaults to one. Real source-buffer import is explicitly rejected in this gate. A successful frame is timestamped with monotonic time through `eglPresentationTimeANDROID`, swapped to the MediaCodec input Surface, and followed by capture teardown.

### 2.3 Failure containment present for this gate

For the active one-frame attempt, the implementation:

- polls for an absent recorder target no more often than every 250 ms;
- disables capture after EGL setup, timestamp, swap, stale-target, or QPA-context restore failures;
- calls `eglGetError()` directly after the failing EGL operation;
- restores the primary QPA EGL context/surfaces before teardown;
- releases the opaque target and destroys the dedicated capture EGL context/surface;
- does not retry a failed attempt every display frame.

`QPA_HWC_SCREENCAP_DEBUG=1` enables the selected EGL config and the pre-/post-primary-swap ordering messages.

### 2.4 Static boundary result

Source inspection passed the boundary relevant to Gate 2.0/2.2:

- QPA contains no `gui/*`, `ui/*`, `binder/*`, or `media/*` Android framework includes for capture;
- QPA does not include a droidmedia API header;
- the capture target remains behind the runtime-resolved `minisf_screen_capture.h` C ABI;
- the native-window value is opaque to QPA and is only supplied to EGL.

The target SDK package build passed on 2026-09-20. Host editor diagnostics are not usable for this project because the host language server does not have the Sailfish target sysroot or Android/hybris headers.

## 3. Intentionally deferred until Gate 2.2 passes

The current implementation is sufficient for the isolated one-frame scheduling proof, but it is not yet the complete Gate 2.3/product session design.

1. The service ABI still publishes width, height, and generation, but not encoder FPS. QPA currently takes diagnostic FPS from `QPA_HWC_SCREENCAP_FPS`.
2. `targetIsCurrent()` performs a Binder `getProducer()` transaction immediately before the submitted frame. A paced multi-frame implementation must change this to the bounded session-query protocol from Revision 3.1 rather than transact once per encoded frame.
3. Failure disabling is process-wide for this QPA window, rather than latched specifically to generation G and automatically retried for generation G+1. Restarting lipstick gives Gate 2.2 a clean attempt; generation-specific restart behavior is required before Gate 2.3.
4. Capture operation duration and hard latency circuit-breaking are not yet complete. The one-frame run must therefore retain timestamps and report visible UI behavior. Measured device latency will set the Gate 2.3 warning and cutoff values.
5. Real HWC source EGL-image import/blitting remains disabled. It must not be enabled until the post-swap bars gate passes.

These are not being changed before Gate 2.2 because doing so would combine the scheduling experiment with a Binder ABI and continuous-capture rewrite.

## 4. Build and deployment status

The user built the `qt5-qpa-hwcomposer-plugin` package from current `hwenc` revision `93cf231` with:

```sh
rpm/dhd/helpers/build_packages.sh -b hybris/mw/qt5-qpa-hwcomposer-plugin/
```

Result:

```text
Building of qt5-qpa-hwcomposer-plugin finished successfully
```

This clears the QPA package-build portion of Gate 2.0. No compiler warnings or errors were reported in the supplied output. Deploy the resulting package/plugin, whose runtime path is:

```text
/usr/lib64/qt5/plugins/platforms/libhwcomposer.so
```

For this first Gate 2.2 run, `droidmedia` and libhybris do not need new builds if the exact artifacts that passed the final Gate 2.1 run are still installed:

```text
/usr/libexec/droid-hybris/system/lib64/libdroidmedia.so   # ccee726 set
/usr/libexec/droid-hybris/system/lib64/libminisf.so      # ccee726 set
/usr/lib64/libhybris/eglplatform_hwcomposer.so            # 8ac75ab fix
/home/defaultuser/screencap_surface_capture_test          # ccee726 set
```

If any of those have changed since Gate 2.1, rebuild/deploy the matched `droidmedia` set and record all package revisions. Do not combine an old `libminisf` with a different recorder/service implementation.

## 5. Gate 2.2 device procedure

### 5.1 QPA environment

Set these before lipstick creates its HWC window, then restart lipstick using the same mechanism used for the prior Gate 2 runs:

```sh
QPA_HWC_SCREENCAP=1
QPA_HWC_SCREENCAP_TEST_BARS=1
QPA_HWC_SCREENCAP_DEBUG=1
QPA_HWC_SCREENCAP_FPS=30
QPA_HWC_SCREENCAP_FRAME_LIMIT=1
QPA_HWC_SCREENCAP_FRAME_SKIP=1
```

A lipstick restart is required for each fresh attempt because capture intentionally disables itself after the one-frame attempt or a failure. Restarting `minisfservice` is not expected to be necessary; the capture Binder service is registered from the lipstick/QPA process.

Before starting the recorder, confirm that the service exists:

```sh
/system/bin/service list | grep sailfish.screencap
```

### 5.2 Recorder

Use a fresh output path:

```sh
rm -f /tmp/screencap-gate2.2.h264
LD_LIBRARY_PATH=/usr/libexec/droid-hybris/system/lib64 \
/home/defaultuser/screencap_surface_capture_test \
    1080 2520 8000000 30 10 /tmp/screencap-gate2.2.h264
```

Interact with the UI during the recorder interval and report whether it remains responsive, hitches briefly, freezes until recorder exit, or causes lipstick to restart.

### 5.3 Expected log ordering

A successful scheduling attempt should contain this order:

```text
Surface encoder ready: 1080x2520 @30 fps generation=G
screencap: candidate recorded in present, awaiting primary swap return
screencap: primary swap returned at ...; submitting test-bars frame 1
screencap: submitted test-bars frame 1 pts=...
screencap: Gate 2.2 frame limit reached; disabling capture
releasing encoder Surface target ... generation=G
```

The exact EGL config should also be logged when debug mode is enabled. Any `eglCreateWindowSurface`, `eglMakeCurrent`, `eglPresentationTimeANDROID`, encoder `eglSwapBuffers`, or QPA restore failure and its immediate hexadecimal EGL error must be retained.

The decisive ordering fact is that `primary swap returned` appears after the candidate was recorded from `present()` and before the encoder frame submission. No target acquisition or encoder EGL operation should appear from inside the `present()` callback.

### 5.4 Artifact checks

Record file size and run:

```sh
ls -l /tmp/screencap-gate2.2.h264
ffprobe -v error -show_streams /tmp/screencap-gate2.2.h264
ffmpeg -v error -i /tmp/screencap-gate2.2.h264 \
    -frames:v 1 /tmp/screencap-gate2.2.png
```

Retain the H.264 file and decoded PNG. The PNG should show the deterministic vertical test bars.

Some encoders may buffer a single input until a later input or EOS. Therefore a successful QPA encoder `eglSwapBuffers()` with an empty recorder file is useful scheduling evidence but does **not** satisfy the strict Gate 2.2 pass criterion from Revision 3.1. If that occurs, preserve the complete logs and do not immediately change the QPA path; the next diagnostic will distinguish codec output buffering from capture submission failure.

## 6. Evidence requested from the first run

Provide:

1. QPA package revision/build result and deployed `libhwcomposer.so` package version.
2. Confirmation that the retained `libdroidmedia`, `libminisf`, recorder utility, and `eglplatform_hwcomposer.so` are the Gate 2.1-proven versions, or their replacement build revisions.
3. Journal/log output covering lipstick startup, recorder start, the capture attempt, and recorder stop. Include unfiltered errors around any lipstick crash/restart in addition to a `screencap`, `ScreenCaptureSurfaceEnc`, and `MiniSfScreenCapture` filtered extract.
4. Recorder stdout/stderr.
5. `/tmp/screencap-gate2.2.h264`, its size, and `ffprobe` output.
6. The decoded PNG or a statement of the FFmpeg decode error.
7. Observed UI responsiveness and approximate hitch/freeze duration.

## 7. Gate decision

Gate 2.2 passes only if:

- the QPA package builds and deploys cleanly without violating the Android framework boundary;
- capture EGL setup and one encoder swap occur after the primary swap returns;
- the recorder receives a decodable H.264 access unit at `1080x2520` showing test bars;
- the UI remains responsive;
- target release and recorder shutdown complete without a hang.

Do not proceed to paced bars, source import, or GStreamer integration until this evidence is reviewed.

## 8. Gate 2.2 result — passed (2026-09-20)

The rebuilt QPA plugin was deployed and tested with the one-frame configuration at `1080x2520 @30 fps`.

Recorder result:

```text
Gate-2 Surface capture test: 1080x2520 @30 fps for 10 seconds
producer registered; encoder and output drain are ready
waiting 10 seconds for encoder-Surface frames...
output format: 1080x2520
Gate-2 recorder stopped: frames=1 error=0 output=/tmp/screencap-gate2.2.h264
```

The decisive QPA log ordering was:

```text
screencap: candidate recorded in present, awaiting primary swap return
screencap: EGL config id=9 surface=0x15a5 renderable=0x45 recordable=1 visual=1 rgba=8/8/8/8
screencap: encoder Surface target=0x7b740a2cd0 generation=1
screencap: primary swap returned at 86068273295636; submitting test-bars frame 1
screencap: submitted test-bars frame 1 pts=86068318511823
screencap: Gate 2.2 frame limit reached; disabling capture
```

This proves that target acquisition, capture EGL setup, timestamping, rendering, and the encoder-surface swap ran only after the primary `eglSwapBuffers()` returned. The former re-entrant `present()` scheduling defect is removed.

`ffprobe` identified the artifact as H.264 High profile, `1080x2520`, progressive `yuv420p`, level 5.0, with a nominal `30/1` frame rate. The artifact contained exactly one decoded test-bars frame. The UI remained responsive throughout the attempt.

The candidate-recorded debug line appeared 155 times while QPA waited for the recorder/session and completed the one-frame attempt. This was harmless—`present()` still performed no Binder or capture EGL work—but the log is unnecessarily noisy and will be limited for Gate 2.3.

**Gate decision:** Gate 2.2 passes. Proceed to the paced test-bars/session-lifecycle implementation for Gate 2.3. Real source import remains blocked until Gate 2.3 passes.

## 9. Gate 2.3 implementation

The paced test-bars/session-lifecycle changes are now implemented in the worktree and require a matched QPA+droidmedia rebuild.

### 9.1 Private session contract

The recorder now publishes:

```text
producer + width + height + fps + generation
```

The private Binder request/reply layouts, in-process service implementation, recorder registration, `libminisf`, and remote EGL diagnostic were updated together. Producer registration rejects a non-positive FPS.

`libminisf` adds two C symbols while retaining the Gate 2.1 diagnostic API:

```c
int minisf_screen_capture_session_query(MinisfScreenCaptureSessionInfo *info);
void *minisf_screen_capture_target_acquire_generation(uint64_t expected_generation);
```

The query returns only an active generation with valid dimensions and FPS. Generation-checked acquire re-queries the service and refuses a producer if the session changed between query and acquire. Android `sp<>`, Binder, `Surface`, and producer types remain inside droidmedia/libminisf.

### 9.2 QPA session state and pacing

QPA resolves the new symbols at runtime and:

- queries session state at most every 250 ms;
- uses the registered encoder FPS by default;
- permits `QPA_HWC_SCREENCAP_FPS` only as a diagnostic override;
- advances an absolute monotonic deadline instead of resetting the deadline to `now + period`, avoiding cadence drift on a 60 Hz display;
- acquires only the generation returned by the preceding query;
- removes the per-encoded-frame `targetIsCurrent()` Binder call;
- detaches on an inactive or changed generation;
- latches EGL/capture failures to generation G while allowing generation G+1 to start without restarting lipstick;
- resets frame counters and pacing for each new generation;
- supports unlimited diagnostic capture with `QPA_HWC_SCREENCAP_FRAME_LIMIT=0`;
- logs the first candidate only once instead of once per rendered frame.

The source path remains deterministic test bars only.

### 9.3 Diagnostics and circuit breaker

Debug output now includes:

- session generation, dimensions, FPS, and query duration;
- target-acquire duration;
- context and window-surface creation duration;
- post-primary-swap capture start, submitted frame, PTS, and encoder-swap duration;
- session detach and circuit-breaker reason.

An encoder swap over one 60 Hz display period emits a warning. A swap over 250 ms latches the current generation as failed after the operation returns. The cutoff cannot interrupt a vendor EGL call already in progress, but it prevents repeated submissions after an unacceptable delay.

The recorder utility supports `SCREENCAP_SURFACE_DEBUG=1` to print every encoded output buffer's size, PTS, and flags. It rejects regressing non-codec-config PTS and reports total encoded bytes.

### 9.4 Stop ordering

Recorder stop now:

1. unregisters the active generation;
2. keeps MediaCodec and the output drain alive for a bounded 500 ms grace interval, twice QPA's session-poll interval;
3. stops the codec and joins the output thread.

The grace uses an EINTR-safe monotonic `nanosleep` loop. It is deliberately bounded: an idle display has no producer swap to race, while a swap already blocked in the vendor path is forced to return by the subsequent codec stop.

### 9.5 Review/static validation

- `git diff --check` passes in both modified submodules.
- Binder writer/reader parcel layouts were reviewed as symmetric.
- The dynamic C session struct has identical field order and types on both sides.
- A separate lifecycle review found no remaining Gate 2.3 blocker after the detach-grace and EGL cleanup fixes.
- No target build has yet been run for these new changes.

## 10. Gate 2.3 build request

Build and deploy as one matched set. There are two distinct droidmedia steps:

1. From the Android build environment after `croot`, run the Android target build (for example `make droidmedia`, with the configured target set also producing the required diagnostics). This is the step that compiles `libdroidmedia.so`, `libminisf.so`, `screencap_surface_capture_test`, and `screencap_surface_remote_egl_test`.
2. The droidmedia RPM build normally packages the already-produced Android output; it is not a substitute for the Android `croot` build.
3. Build `qt5-qpa-hwcomposer-plugin` from the current worktree to produce the updated `libhwcomposer.so`.

For the current manual test, directly copying the two Android libraries and recorder/remote-EGL test binaries is sufficient. The proven libhybris `eglplatform_hwcomposer.so` does not need another rebuild. The droidmedia and QPA artifacts must be deployed together because the private Binder parcel and runtime C ABI changed.

## 11. Gate 2.3 device procedure

Configure QPA before restarting lipstick:

```sh
QPA_HWC_SCREENCAP=1
QPA_HWC_SCREENCAP_TEST_BARS=1
QPA_HWC_SCREENCAP_DEBUG=1
QPA_HWC_SCREENCAP_FRAME_LIMIT=0
QPA_HWC_SCREENCAP_FRAME_SKIP=1
```

Do not set `QPA_HWC_SCREENCAP_FPS`; this run must prove that QPA uses the recorder-published 30 fps value.

After restarting lipstick, retain a live journal covering both recorder sessions. Run two five-second recordings without restarting lipstick between them, using fresh output files and `SCREENCAP_SURFACE_DEBUG=1`. Validate each stream with `ffprobe` and decode several frames with FFmpeg. Gate 2.3 requires both generations to work, monotonic output PTS near the requested cadence, no circuit breaker, bounded swap latency, clean detach/reacquire, and a responsive UI.

## 12. First Gate 2.3 attempt — configuration/default failure

The first paced attempt produced one valid frame in session 1 and no output in session 2:

```text
session 1: frames=1 bytes=6873 error=0
session 2: frames=0 bytes=0 error=0
```

`ffprobe` decoded session 1 as High-profile H.264 at `1080x2520`; session 2 was empty. The journal identified the exact cause:

```text
screencap: post-swap test bars enabled: fps=recorder session, limit=1
screencap: session query active=1 generation=1 1080x2520@30
screencap: submitted test-bars frame 1 ... swap=1.142ms
screencap: frame limit reached; disabling capture
```

Positive evidence from this attempt:

- the new matched Binder/C ABI worked;
- QPA used the recorder-published `30 fps`, not an environment override;
- session query and generation-checked acquire succeeded;
- target acquisition took `0.954 ms`;
- context creation took `2.043 ms` and window-surface creation `1.552 ms`;
- the encoder swap took `1.142 ms`, well below one display period;
- the resulting frame decoded correctly.

The failure was not a pacing, codec, or generation-acquire failure. `QPA_HWC_SCREENCAP_FRAME_LIMIT=0` was not present in lipstick's effective environment, and the code still defaulted to the old Gate 2.2 limit of one. Reaching that limit set `m_captureEnabled=false`, so QPA could not observe session 2.

After Gate 2.2 has passed, a one-frame default is unsafe for subsequent tests. The source default is now changed to `0` (unlimited); an explicit positive frame limit remains available for diagnostics. Only the QPA plugin needs rebuilding for the retry. The already-deployed matched droidmedia artifacts remain valid.

## 13. Gate 2.3 retry — media and sequential sessions passed

After rebuilding QPA with the unlimited default, two recorder sessions ran without restarting lipstick. Both outputs were valid changing test-bars streams:

```text
session 1: High-profile H.264, 1080x2520, yuv420p
           r_frame_rate=30/1, avg_frame_rate=30/1, decoded frames=120
session 2: High-profile H.264, 1080x2520, yuv420p
           r_frame_rate=30/1, avg_frame_rate=30/1, decoded frames=46
```

The different decoded-frame counts are expected for this event-driven QPA producer. Capture can submit only after a primary display swap; a mostly idle screen provides fewer capture opportunities, while UI interaction produces more. The important cadence result is that both generated streams report `avg_frame_rate=30/1` rather than being fed at display rate.

The small flickering block on the right-hand side is intentional. The test-bars fragment shader alternates that marker every submitted frame to prove the encoded stream contains changing frames rather than repeated static output.

This passes the Gate 2.3 media, pacing, and generation-restart portions.

## 14. Gate 2.3 final journal review — passed

The updated successful-run journal closes the remaining lifecycle and latency criteria:

- QPA started in recorder-session pacing mode with `limit=0`.
- Generation `1` was queried and acquired at `1080x2520@30`, submitted 120 frames, then was observed inactive and detached cleanly.
- Generation `3` was subsequently queried and acquired without restarting lipstick, submitted 46 frames, then detached cleanly.
- Target acquisition took approximately `0.43–0.47 ms`.
- Capture-context creation took approximately `1.46–1.83 ms` and encoder window-surface creation `0.99–1.27 ms`.
- Observed encoder swaps were approximately `0.58–3.65 ms`, all well below one 60 Hz display period.
- No swap-latency warning, circuit breaker, EGL error, lipstick restart, or retry storm appeared.
- Submitted PTS values were monotonic. When the UI rendered continuously, submissions followed the expected roughly 30-fps cadence; idle intervals correctly produced no duplicate synthetic frames.
- Lipstick remained the same running process across both sessions. User interaction generated frames and no UI freeze was reported.
- Both artifacts decoded as changing High-profile H.264 at `1080x2520`, `yuv420p`, with `r_frame_rate=30/1` and `avg_frame_rate=30/1`.

**Gate decision:** Gate 2.3 passes. The Surface-input encoder, remote producer, libhybris window path, post-primary-swap scheduling, registered-FPS pacing, bounded session polling, stop/detach ordering, and restart across generations are proven with deterministic test bars.

Execution stops here before Gate 3. No real HWC source import is enabled yet.

## 15. Next gate

The next gate is **Gate 3 — real QPA/HWC source content**:

1. import the completed `HWComposerNativeWindowBuffer` as an `EGLImageKHR` in the dedicated capture context;
2. bind it as a GLES texture and blit it into the MediaCodec encoder surface;
3. validate the correct on-screen content, orientation, crop, alpha/color behavior, and motion;
4. keep source-import/blit failures distinct from encoder-surface/session failures;
5. repeat lifecycle and latency checks with real content.

Gate 4, GStreamer integration, remains blocked until Gate 3 passes.

## 16. Gate 2.3 closure and continuation checkpoint

Gate 2.3 is complete; no further build, deployment, or device log is needed to close it. The full successful journal is retained as `journal.log` at the `mw` root, and the decisive media/lifecycle evidence is summarized in Sections 13–14.

The current worktree intentionally contains the uncommitted Gate 2.3 implementation in both `droidmedia` and `qt5-qpa-hwcomposer-plugin`. Preserve those changes as the baseline for the next round. In particular, do not remove the generation-aware private session ABI, post-primary-swap scheduler, absolute monotonic pacing, bounded session polling, detach grace, or latency circuit breaker when enabling real content.

The next implementation round is **Gate 3**, not Gate 4. Its first task is to audit the existing disabled source-import helper before enabling it. `eglCreateImageKHR(..., EGL_NATIVE_BUFFER_ANDROID, ...)` is expected to receive the native `ANativeWindowBuffer *` exposed by `HWComposerNativeWindowBuffer::getNativeBuffer()`, not the buffer's `buffer_handle_t`; the handle may still be used as the cache identity. Confirm this against the local libhybris native-window types before changing the call.

Gate 3 should then:

1. add an explicit real-source mode while retaining the test-bars mode for diagnosis;
2. resolve and validate the EGL-image/GLES extension entry points;
3. import and cache each HWC source slot as an `EGLImageKHR` in the dedicated capture context;
4. compile/link-check the blit shaders, bind the image as a texture, and synchronously blit it after the primary swap;
5. preserve the proven timestamping, pacing, encoder swap, QPA-context restore, generation latching, and teardown behavior;
6. log source import, shader/blit, encoder swap, and QPA restore failures as distinct failure classes;
7. determine vertical orientation from decoded device output rather than assuming the native-buffer texture origin.

Do not move the source buffer to a background thread: the present design has no independent ownership/fence protocol for retaining it beyond the immediate post-swap call. Do not revive raw metadata, source `attachBuffer()`, or CPU-copy capture paths.

If Gate 3 changes only QPA, the next device request should require only a rebuilt/deployed `qt5-qpa-hwcomposer-plugin`; rebuild the Android droidmedia artifacts only if the private ABI changes. Device validation should use a recognizable moving UI pattern at `1080x2520`, run two recorder sessions without restarting lipstick, inspect decoded orientation/content/motion, and retain recorder output plus the complete lipstick journal and swap-latency evidence.

Gate 3 passes only with correct real screen content and orientation, no capture-only EGL/GL errors, clean generation detach/reacquire, and no persistent UI hitch. **Gate 4** is then the `droidscreencapsrc` refactor to consume `ScreenCaptureSurfaceEncoder`, with bounded output buffering and restart-safe cleanup.

## 17. Gate 3 implementation — ready for build

Gate 3 is implemented in `qt5-qpa-hwcomposer-plugin/hwcomposer/hwcomposer_backend_v20.cpp`. The private recorder ABI is unchanged, so the Gate 2.3-proven droidmedia artifacts remain valid.

### 17.1 Explicit capture modes

Capture still requires `QPA_HWC_SCREENCAP=1`, and now requires exactly one explicit producer mode:

```text
QPA_HWC_SCREENCAP_TEST_BARS=1   # retained Gate 2 diagnostic
QPA_HWC_SCREENCAP_SOURCE=1      # Gate 3 real HWC source
```

Setting both or neither disables capture. The startup log identifies the selected mode. `QPA_HWC_SCREENCAP_FLIP_Y=1` is an explicit diagnostic orientation switch; the first source run must leave it unset so device output determines whether a vertical flip is required.

### 17.2 Native-buffer import correction

The disabled helper previously passed `buffer_handle_t` as the `EGLClientBuffer` for `EGL_NATIVE_BUFFER_ANDROID`. Gate 3 now follows libhybris's native-window contract:

- `src->handle` remains the EGLImage/texture cache key;
- `src->getNativeBuffer()` supplies the required `ANativeWindowBuffer *` to `eglCreateImageKHR()`.

Each HWC source slot is imported once per recorder generation/capture context and cached with its GLES texture. Cache teardown destroys GL objects with the capture context current and destroys display-level EGLImages even if making that context current during cleanup fails.

### 17.3 Source synchronization

Primary `eglSwapBuffers()` returning does not by itself prove that GPU rendering into the source buffer has completed. While still inside `present()`, the source mode therefore performs only one additional bounded/non-blocking ownership operation: it duplicates the source acquire fence before HWC takes the original. No wait, EGL call, Binder call, or capture rendering occurs there.

The immediate post-primary-swap path owns the duplicate through all early returns. Only when a source frame is actually due does it call `sync_wait()` with a 250 ms timeout before importing/sampling the buffer. The duplicate is then closed automatically. A duplication failure or bounded wait failure latches the current recorder generation through the existing circuit breaker.

### 17.4 Checked import and blit

The dedicated capture context now:

1. verifies `EGL_KHR_image`/`EGL_KHR_image_base`, `EGL_ANDROID_image_native_buffer`, and `GL_OES_EGL_image`;
2. verifies the dynamically resolved create/destroy/image-target entry points;
3. reports the immediate EGL error from native-buffer image creation;
4. binds the image to a `GL_TEXTURE_2D` and reports immediate GL errors;
5. compiles and link-checks the GLES2 blit shaders with info logs;
6. draws a full-surface textured quad, optionally flipping Y through a shader uniform;
7. checks draw and flush errors before timestamping and swapping the encoder surface.

Source-extension, source-import, source-texture, shader/link, draw/flush, timestamp, encoder-swap, and QPA-restore failures are logged separately. All failures retain generation latching and restore the primary QPA context before teardown whenever possible.

The proven Gate 2.3 session query, absolute pacing, presentation timestamps, encoder-swap latency warning/circuit breaker, detach grace, and sequential-generation behavior are unchanged.

### 17.5 Static review

- `git diff --check` passes in `qt5-qpa-hwcomposer-plugin`.
- An independent focused review found no Gate 3 blocker in fence ownership, context restoration, native-buffer typing, cache lifetime, shader handling, or target C++ compatibility.
- That review identified a possible EGLImage leak if teardown could not make the capture context current; cleanup was corrected so EGLImage destruction does not depend on a current GL context.
- Host editor diagnostics remain unusable because the Sailfish/Android target headers and Qt target configuration are absent.
- The target `qt5-qpa-hwcomposer-plugin` package build completed successfully on 2026-09-20 with no reported compiler error.

### 17.6 Build and deployment

The QPA-only package build passed:

```text
Building of qt5-qpa-hwcomposer-plugin finished successfully
```

Deploy the resulting `libhwcomposer.so`. Do not rebuild or replace `libdroidmedia.so`, `libminisf.so`, the recorder test, or libhybris for this attempt if the Gate 2.3-proven artifacts remain installed.

### 17.7 First Gate 3 device procedure

Before restarting lipstick, configure:

```sh
QPA_HWC_SCREENCAP=1
QPA_HWC_SCREENCAP_SOURCE=1
QPA_HWC_SCREENCAP_DEBUG=1
QPA_HWC_SCREENCAP_FRAME_LIMIT=0
QPA_HWC_SCREENCAP_FRAME_SKIP=1
```

Ensure `QPA_HWC_SCREENCAP_TEST_BARS`, `QPA_HWC_SCREENCAP_FLIP_Y`, and `QPA_HWC_SCREENCAP_FPS` are unset. Confirm startup contains:

```text
screencap: post-swap HWC source enabled: fps=recorder session, limit=0
```

Use a visually asymmetric screen (different content at the top and bottom), then scroll or animate it throughout two recorder sessions without restarting lipstick:

```sh
rm -f /tmp/screencap-gate3-s1.h264 /tmp/screencap-gate3-s2.h264

SCREENCAP_SURFACE_DEBUG=1 \
LD_LIBRARY_PATH=/usr/libexec/droid-hybris/system/lib64 \
/home/defaultuser/screencap_surface_capture_test \
    1080 2520 8000000 30 5 /tmp/screencap-gate3-s1.h264

SCREENCAP_SURFACE_DEBUG=1 \
LD_LIBRARY_PATH=/usr/libexec/droid-hybris/system/lib64 \
/home/defaultuser/screencap_surface_capture_test \
    1080 2520 8000000 30 5 /tmp/screencap-gate3-s2.h264
```

Validate both streams:

```sh
ffprobe -v error -count_frames -select_streams v:0 \
    -show_entries stream=codec_name,profile,width,height,pix_fmt,r_frame_rate,avg_frame_rate,nb_read_frames \
    -of default=noprint_wrappers=1 /tmp/screencap-gate3-s1.h264

ffprobe -v error -count_frames -select_streams v:0 \
    -show_entries stream=codec_name,profile,width,height,pix_fmt,r_frame_rate,avg_frame_rate,nb_read_frames \
    -of default=noprint_wrappers=1 /tmp/screencap-gate3-s2.h264

ffmpeg -v error -i /tmp/screencap-gate3-s1.h264 \
    -vf "select=eq(n\\,0)+eq(n\\,30)+eq(n\\,60)" -vsync 0 \
    /tmp/screencap-gate3-s1-%02d.png
```

Retain both recorder logs, both H.264 files, representative decoded frames, and the complete lipstick journal. Report whether content is correct, vertically inverted, otherwise transformed/cropped, stale, black, or corrupted, plus UI responsiveness. If the only defect is vertical inversion, restart lipstick with `QPA_HWC_SCREENCAP_FLIP_Y=1` and repeat; do not change the shader based on assumption alone.

## 18. First Gate 3 device result — source path passed, orientation retry required

The first real-content run successfully imported and encoded the HWC source in two sessions without restarting lipstick:

```text
session 1: generation=1, frames=40, bytes=1726105
session 2: generation=3, frames=113, bytes=5113385
```

Both streams were High-profile H.264 at `1080x2520`, 30 fps nominal. The videos showed recognizable changing screen content. The content was vertically inverted, with no other reported corruption; this confirms that the device's native-buffer texture origin requires the implemented `QPA_HWC_SCREENCAP_FLIP_Y=1` path.

Journal review found:

- all three HWC source slots imported successfully in each capture context;
- 153 submitted real-source frames across the two sessions;
- source acquire-fence waits: `0.006–4.640 ms`, average `0.064 ms`;
- encoder swaps: `0.624–3.205 ms`, average `1.271 ms`;
- two clean generation detaches;
- no source import, shader, GL/EGL, restore, latency, circuit-breaker, or restart failure.

Gate 3's real source-import/blit, synchronization, hardware encoding, and sequential-session lifecycle therefore pass. Correct orientation remains to be confirmed with the existing flip switch before declaring the full gate passed.

### 18.1 Idle session-query cost

The `active=0` message is emitted only with `QPA_HWC_SCREENCAP_DEBUG=1`. The underlying query is not performed on every display frame: it is capped by the existing 250 ms session-check deadline and can run only following a primary swap. In this journal, 52 inactive queries took `0.183–1.963 ms`, averaging `0.827 ms`.

This is low average load (at most four short Binder queries per second while the display is continuously swapping), but it is synchronous work on the UI thread and therefore is not literally free. No corresponding UI hitch was reported. Debug journal formatting adds separate overhead and is disabled in normal operation. A longer idle backoff or event-driven registration notification may be considered for product polish, but changing discovery semantics is not required to validate Gate 3.

### 18.2 Apparent speed-up and idle-frame semantics

The recorder log proves that MediaCodec preserves the QPA monotonic presentation timestamps, including idle gaps. For example, session 1 contains gaps of approximately 0.51, 0.53, and 0.67 seconds between output access units. The standalone diagnostic writes only raw Annex-B H.264 bytes, which have no container sample timestamps. Playback therefore reconstructs a constant nominal 30 fps timeline and compresses those gaps, making the video appear sped up.

The product path should not force lipstick to render and re-encode a duplicate frame 30 times per second merely to represent inactivity. Gate 4 should carry each MediaCodec output PTS into the corresponding GStreamer buffer/container sample. A normal timestamp-aware player then holds the previous decoded frame until the next sample PTS, naturally representing a UI stall without redundant GPU/encoder work. The final sample also needs a duration extending to recorder stop/EOS. Constant-frame-rate duplication can remain an optional downstream conversion policy, not a requirement of the QPA capture path.

## 19. Gate 3 orientation retry and final decision — passed

The QPA source mode was restarted with:

```text
QPA_HWC_SCREENCAP_FLIP_Y=1
```

The resulting recording had the correct orientation. This confirms that the device's HWC native-buffer texture origin requires a vertical flip and that the implemented shader switch performs the required transform. The source content, motion, dimensions, hardware encoding, bounded source synchronization, encoder-surface swaps, and sequential generation lifecycle had already passed in the two-session run recorded in Section 18.

The second raw `.h264` artifact was not consistently recognized by the Gallery application after playback. This does not invalidate Gate 3: both artifacts were produced as temporary raw Annex-B diagnostics rather than a supported media container, and raw H.264 carries neither the MediaCodec sample PTS timeline nor a reliable duration/index for Gallery. The same limitation explains accelerated playback across idle presentation gaps. Containerization, timestamp propagation, final-sample duration, and application-facing media compatibility belong to Gate 4.

**Gate decision:** Gate 3 passes. The completed QPA/HWC display buffer is imported as an EGLImage, synchronously blitted with the correct vertical orientation into the remote MediaCodec input Surface, and hardware-encoded as real changing screen content without capture errors or persistent UI disruption.

The next gate is **Gate 4 — refactor `droidscreencapsrc` to use `ScreenCaptureSurfaceEncoder` and preserve MediaCodec PTS/duration through GStreamer/container output**.
