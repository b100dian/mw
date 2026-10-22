# Screen recording — cleanup plan and session notes

**Dates:** 2026-10-13 to 2026-10-17
**Basis:** `hwc-h264-exec4.md` (the Gate 4 code, tagged `hwenc-gate4` in each submodule)
**Status:** the cleanup is done and the device checklist passed (2026-10-15).
Device testing then showed a stale last frame in the live view, which has
three causes. The gst-droid fix and the lipstick cause were confirmed on the
device, with a Matroska viewer at `fps=120`. The QPA fix (`643f56a`) has not
been run on the device yet. The documented viewer stays raw Annex B.

## 1. Plan

**Problem.** The `hwenc` branches carried every gate's scaffolding:

| Repo | Added on `hwenc` at Gate 4 | Scaffolding |
|---|---|---|
| droidmedia | 4026 lines | the legacy raw-capture path, 3 dead tools, `AsyncCodecSource` and `private.cpp` edits |
| gst-droid | 1160 lines | 4-space style, a dead legacy API, a double copy |
| qt5-qpa-hwcomposer-plugin | 1790 lines | about 1100 lines inlined in `HWC2Window`, 8 env vars, per-frame logging, dead code |

**Goal.**
1. An `mw/README.md` with ASCII diagrams and a status section.
2. Each repo's change rebuilt as a small, idiomatic, commented commit set.
3. Screen recording keeps working.

**Decisions.**
- `sailfish.screencap` moves into `minisfservice`.
- `screencap_surface_capture_test` stays, as an optional last commit; all other tools and test modes go.
- The API gets droidmedia names (`droidmediascreencapture.h`).
- Copyright "Jolla Ltd.", with the full license text in each repo's usual form.

**Git mechanics.**
- **Cleanup commits** go on `hwenc`, on top of the Gate 4 heads (droidmedia `29762d5`, gst-droid `6688db2`, QPA `3f6d3ea`).
  - Each head is tagged locally as `hwenc-gate4`.
  - Each commit is a revert or a focused cleanup, so `git diff master..hwenc` becomes the reviewable change.
- **Squashing:** `scripts/squash-hwenc-review.sh` builds one review commit per submodule on `hwenc-review`.
- **Who commits:** the agent made the commits during this session. The user then rewrote them without the Co-Authored-By lines (`scripts/remove-coauthors.sh`), so the hashes below are the rewritten ones. From now on the user makes all commits (`init.md`).

**Comment rules.**
- **Remove:** gate, phase and revision references, history narration, "NEW —" markers, Binder debug logs, and comments that repeat the code.
- **Keep** one or two lines per non-obvious constraint:
  - the producer is published only after `MediaCodec::start()`;
  - the 500 ms detach grace exists because lipstick polls every 250 ms;
  - the recorder needs a Binder thread pool;
  - the `Surface*` → `ANativeWindow*` adjustment;
  - callbacks never run under the lock;
  - the encoder object is single-use;
  - EOS is intercepted in `send_event()`;
  - SPS/PPS go in-band;
  - capture runs after the outer `eglSwapBuffers()` returns;
  - the y-flip is needed because EGLImage rows are top-down;
  - the session poll is rate-limited.
- **Indentation:** droidmedia uses 2 spaces, gst-droid uses gst-indent, QPA uses 4-space Qt style.

## 2. Result

Commits are listed as `hwenc-gate4..hwenc`, after the user's rewrite.

**droidmedia.** Net `master..hwenc`: 12 files, +1121 / −2. About 125 of those lines are the optional tool.

| Commit | Content |
|---|---|
| `f1e9b0f` Remove the Gate 0-2 diagnostic tools | three tools and their build entries |
| `4bc0d3a` Remove the legacy raw-capture path | `screen_capture.cpp`, `screen_capture_mediasource.*`, `screen_capture_encoder.*`; `private.*`, `AsyncCodecSource.*` and `droidmedia.h` back to master, so camera recording is upstream code again |
| `9d99a3c` Host sailfish.screencap in minisfservice | `ScreenCaptureService` in `minisf.cpp` (see below) |
| `bc78f33` Trim the libminisf bridge | `libminisf.cpp` back to master; 4 C symbols left in `minisf_screen_capture.cpp` |
| `b3e94f8` Rename to the droidmediascreencapture API | `droidmediascreencapture.{h,cpp}`, `hybris.c`, `meson.build` |
| `21a2cbf` Comment and style cleanup | one comment |

Details:
- **The service** (`screen_capture_service.{h,cpp}`):
  - three calls, `getProducer`, `registerProducer` and `unregisterProducer`;
  - descriptor `sailfish.IScreenCaptureService`, service name `sailfish.screencap`;
  - instance state, with the generation counter seeded from `systemTime()`;
  - `linkToDeath` clears the session when the recorder dies.
- **The libminisf bridge:**
  - always `checkService()`, never `getService()`, which waits up to 5 s on Android 14 and this runs on lipstick's render thread;
  - the proxy is cached, and looked up again when the binder is dead;
  - `startThreadPool()` is called once, on first use;
  - no link to libdroidmedia.
- **The encoder:**
  - timestamps are in ns, as in the rest of droidmedia;
  - `finish()` reads the EOS result after joining the output thread;
  - a dequeue error during recording is reported;
  - in `hybris.c`, `droid_media_screen_capture_new()` returns NULL if the library lacks it (Android < 8).
- **When squashing,** `Android.mk` has to be split by block (`libdroidmedia`, `minisfservice`, `libminisf`, the tool).

**gst-droid.** Net `master..hwenc`: 5 files, +892 / −2.

| Commit | Content |
|---|---|
| `ca89313` Require width/height | no more dimension discovery; 0 is an error in `start()` |
| `dcb94fd` Port to droidmediascreencapture | new API, `DroidMediaCodecData` |
| `5e5da25` Queue GstBuffers directly | `gst_buffer_new_allocate` + `gst_buffer_fill`; not `gst_buffer_new_memdup` (needs 1.20) and not `g_memdup2` (needs GLib 2.68) |
| `00ab3d9` Register droidscreencapsrc with GST_RANK_NONE | never autoplugged instead of the camera |
| `40d446a` gst-indent and comment cleanup | `GST_PARAM_MUTABLE_READY`; `gstvideo` dependency dropped |
| `3a7e560` Push each access unit as soon as it is encoded | §5.2 |
| `b86b3a2` Describe fps as the nominal frame rate | §5.3 |

**qt5-qpa-hwcomposer-plugin.** Net `master..hwenc`: 5 files, +725 / −7. `hwcomposer_backend.cpp`, the top-level `.pro` and the spec are identical to master.

| Commit | Content |
|---|---|
| `ea98aad` Revert the tools/ screen capture EGL test | |
| `d5bb2f3` Drop diagnostic env vars and test bars; make the y-flip unconditional | only `QPA_HWC_SCREENCAP` and `QPA_HWC_SCREENCAP_LANDSCAPE_ROTATION` remain |
| `f30d531` Move capture into HwComposerScreenCapture | new `hwcomposer_screencapture.{h,cpp}` (see below) |
| `643f56a` Capture every frame the compositor renders | §5.3 |

Details:
- **Backend hooks:** three, in `hwcomposer_backend_v20`.
  - `createWindow()` creates the capture object; the backend owns it.
  - `present()` calls `bufferPresented()` before `set_client_target()`.
  - `swap()` calls `captureFrame()` after a successful `eglSwapBuffers()`.
- **Rendering:** rotation and the y-flip are precomputed texture coordinates.
- **Fences:** if duplicating the acquire fence fails, that frame is skipped.

**mw.** Contains `README.md` and its updates; the README tips match the table above.

**Deviations from the plan:**
- **Commit order:** droidmedia removes the tools before the raw path, and gst-droid's "Require width/height" moved first, so that every commit builds.
- **No separate style or logging commits:** the droidmedia style commit is a single comment, and QPA has no logging commit, because the rewritten code was already clean.
- **Line counts** are above the targets: about 850 + 150, about 750, and about 600 were planned.

## 3. Checks without the device

- **droidmedia:** every new or changed file compiles with the exact kati flags (`-Wall -Werror`). The flags come from `out/build-lineage_pdx224.ninja`; the script was `/tmp/dmcheck/check.py`.
- **gst-droid:**
  - the element compiles against the 1.26.11 sources in `mw/gstreamer`, with headers generated by `meson setup /tmp/gst-1.26.11 …/subprojects/gstreamer` (`/tmp/gstcheck.sh`);
  - it also compiles with the SDK cross gcc against the xqcq54 target (GStreamer 1.26.11, GLib 2.86).
- **QPA:**
  - compiled with the SDK cross g++ 13.4 against Qt 5.6.3 (`/tmp/qpacheck.sh`), using `-Wall -W`;
  - the compiler is run through the tooling's `lib/ld-linux.so.2 --library-path …` and `-wrapper`; run directly, it crashes with a floating-point exception;
  - host clang can't parse the Qt 5.6 headers.
- **Element behaviour,** in `/tmp/sctest`:
  - the real element runs against a stub droidmedia that delivers access units on a schedule, synthetic or real x264 frames, with still pauses;
  - it runs on the host's GStreamer 1.28;
  - the end-to-end variant times delivery through `matroskamux` and `tcpserversink` into ffmpeg.
- These checks don't cover linking, packaging or behaviour on the device. `/tmp` doesn't persist.

## 4. Device run (2026-10-15)

All 11 steps of the checklist passed:
- `gst-inspect-1.0` shows the properties and rank none;
- portrait and landscape;
- TCP;
- MP4;
- portrait → landscape → portrait in one lipstick run, which closes Gate 4.3;
- `kill -9` of the recorder;
- lipstick without capture;
- the droidmedia-only tool;
- camera recording.

Notes from the run:
- **"sailfish.screencap is not running"** appeared at first. The env vars can't cause it; they only affect lipstick.
  - At `hwenc-gate4`, lipstick registered the service through `startMiniSurfaceFlinger()`. Now only `minisfservice` does, so an old `minisfservice` that wasn't restarted, or an SELinux denial, would cause the message.
  - It went away on the device; the exact cause wasn't recorded.
- **SELinux denials** from the service manager appear in logcat, not `dmesg`. The README and the checklist said `dmesg`; the README is fixed.
- **Checklist step 9 was wrong.** It checked that `grep minisf /proc/$(pidof lipstick)/maps` is empty, but master QPA always loads libminisf for `startMiniSurfaceFlinger()` (only true for HWC1, see §7). Check instead that there is no `screencap: enabled` line in the journal.
- **Killing the recorder:** start the recording in one SSH session, then `pkill -9 -f droidscreencapsrc` from another.
  - Expect `Recorder died, session N ended` in logcat (`-s ScreenCaptureService`) and `screencap: session N ended, detaching` in lipstick's journal.
  - Record raw `.h264` for this test, because a killed MP4 has no index.

## 5. Stale last frame in the live view

Symptom: after typing in the Terminal app, the live view on the PC kept the frame with the key highlighted until the screen changed again. It wasn't an off-by-one in the capture, and it wasn't a regression from the cleanup: `hwenc-gate4` behaved the same. There were three causes, one after the other.

### 5.1 Viewer: raw Annex B over TCP

- **Cause:** with `ffplay -f h264`, ffmpeg knows a frame is complete only once the next one starts, so a still screen always shows one frame behind.
- **Fix:** mux into Matroska, which stores each frame with its size. The sender used on the device:
  ```
  gst-launch-1.0 -v droidscreencapsrc height=1080 width=2520 target-bitrate=4000000 fps=60 ! \
    h264parse ! matroskamux streamable=true ! \
    tcpserversink host=0.0.0.0 port=5000 sync=false \
    sync-method=latest-keyframe units-max=200 units-soft-max=150 recover-policy=keyframe
  ```
  and the receiver `ffplay -fflags nobuffer -flags low_delay -f matroska tcp://$PHONE_IP:5000`.
- **`-framerate` must not be passed with `-f matroska`:** ffplay quits with "Option framerate not found" before opening a window. ffprobe accepts the option, which is misleading.
- **Checked in the 1.26 sources:**
  - matroskamux puts its header into the caps, and `tcpserversink` sends it to every new client;
  - only the cluster starts at keyframes are sync points; block headers and frame data are `DELTA_UNIT`. So `latest-keyframe` and `recover-policy=keyframe` start a client cleanly;
  - `units-*` count buffers, and matroskamux sends two per frame.
- **Host timing:** through `h264parse ! matroskamux` and these `tcpserversink` settings, into ffmpeg with `-fflags nobuffer -flags low_delay`, every frame was decoded within 1–2 ms of encoding, including after 2 s pauses.
- **Side notes:**
  - `-flags low_delay` also turns off ffmpeg's frame-threaded decoding, which would hold frames back.
  - `-fflags nobuffer` discards the packets read while probing the stream, keyframe included, so a viewer starts at the next keyframe.
  - Possible, but not tested: with `latest-keyframe`, a viewer that connects to a running stream gets everything since the last keyframe at once, and ffplay plays it at the original pace, staying that far behind. If that happens, start ffplay right after the sender, or use `sync-method=next-keyframe`.
- **Decision (2026-10-17):** the repo scripts and the README stay with raw Annex B, and Matroska is not documented there. The README keeps the one-line limitation: with raw Annex B, ffplay shows a frame only once the next one starts, so a still screen shows the frame before the last one.

### 5.2 Element: one-access-unit lookahead (gst-droid `3a7e560`)

- **Cause:** `droidscreencapsrc` held each access unit until the next one arrived, so that its duration would cover the idle gap after it. The last change before a still period therefore left the element only with the next change.
- **Fix:** push each access unit at once, with no duration.
- **Measured** with the stub test:
  - before, each frame waited for the next one (600 ms during a 600 ms pause), and the last one only came out at EOS;
  - after, every frame is pushed within 1 ms, with the same PTS.
  - Real H.264 frames mux correctly into MP4 and Matroska. MP4 takes each sample's duration from the next PTS.
- **Cost:** the tail. Before, the last frame of an MP4 lasted until the recording stopped; it was 0.27 s in the test. Now it gets one nominal frame period (`h264parse` sets a duration when there is none, `gsth264parse.c:2832`).
  - Neither `qtmux` nor `matroskamux` can extend a sample once it has been pushed, and `qtmux` ignores GAP events (`gstqtmux.c:5121`).
  - If the tail matters for file recordings, a property could turn the hold back on.
- **Correction:** the README (and exec4's status line) said `h264parse` drops the durations, so that the tail is "only visible at the element boundary". That's wrong. `h264parse` keeps a valid upstream duration, as exec4 §1.2 itself says, and the tail reached `mp4mux` in the host test. The README is fixed.

### 5.3 Lipstick: frame-rate cap (QPA `643f56a`, gst-droid `b86b3a2`)

- **Cause:** `captureFrame()` sent at most one frame per 1/fps and dropped any frame that came sooner. Lipstick only renders when the screen changes, so a dropped frame that was the last one before a still period was never replaced.
- **Confirmed on the device:** with `fps=120`, which never drops a frame on this 60 Hz display, the stale frame was gone. The encoder kept up with every frame.
- **Fix:** send every frame the compositor renders. `fps` is now only the encoder's nominal rate and the caps framerate; use the display refresh rate (60). The README examples use `fps=60`, and the property default is 60 (changed on 2026-10-17). The droidmedia test tool still defaults to 30.
- **Rejected:** capping in the encoder instead, with `max-fps-to-encoder` plus `repeat-previous-frame-after`.
  - Android 14's GraphicBufferSource does keep a frame it dropped for the rate limit as the latest one (`frameworks/av/media/module/bqhelper/GraphicBufferSource.cpp:722`), and repeats it later.
  - But it repeats the last frame `kRepeatLastFrameCount` (10) times after every change.
  - And `calculateCodecTimestamp_l()` drops a real frame whose timestamp is not later than a repeat that has just been sent, so the stale frame could still appear occasionally.
- **Also rejected:** a timer in lipstick. It means more compositor code, and Qt timers may not run on the threaded render loop's thread.

## 6. Open items

- **Device run of QPA `643f56a`** at `fps=60`: after typing, the highlight should disappear right away. Check `journalctl --user -u lipstick | grep screencap` for "the encoder blocked a swap".
- **The MP4 tail** trade-off from §5.2: keep it as is, or add a property for file recordings.
- **Still to run on the device:** the RTP proof, and slow downstream with keyframe recovery (Gate 4.4).
- **Follow-ups from the README:**
  - libhybris `8ac75ab` as an optional upstream PR;
  - the `SurfaceFlingerAIDL` check in `startMiniSurfaceFlinger()`;
  - encoder profile and level through `DroidMediaCodecEncoderMetaData` (auto-goal1 §2.1);
  - a repaint on attach, so the first IDR comes at once;
  - landscape rotation that follows lipstick's orientation.

**Rollback:** `git checkout hwenc-gate4` in the three submodules, rebuild and redeploy that set, and add `QPA_HWC_SCREENCAP_SOURCE=1` and `QPA_HWC_SCREENCAP_FLIP_Y=1` to the lipstick drop-in.

## 7. Corrections (2026-10-18)

- **libminisf in lipstick on HWC2.** §4 says master QPA always loads libminisf for `startMiniSurfaceFlinger()`. Only the HWC 0.x/1.x backends do: `initLegacyHwComposerQuirks()` loads it and is called only for them (`hwcomposer_backend.cpp:149–181`). Every HWC2 path creates `HwComposerBackend_v20(NULL, NULL)`, without libminisf and without `startMiniSurfaceFlinger()`.
  - On the Xperia 5 IV (HWC2), `HwComposerScreenCapture::create()` is the only place lipstick loads libminisf, and libminisf's `startThreadPool()` starts lipstick's `/dev/binder` thread pool. Lipstick needs it for incoming calls: the encoder queue's buffer-released callbacks to the `Surface`, and, with push-mode session updates, `sessionChanged` and the death of `minisfservice`.
  - The checklist step 9 explanation is therefore wrong for this phone. If `/proc/<lipstick>/maps` listed libminisf with capture disabled, something else loaded it; that was not investigated. The replacement check (no `screencap: enabled` line in the journal) stays valid.
  - The `SurfaceFlingerAIDL` follow-up (`startMiniSurfaceFlinger()` checks for `"SurfaceFlinger"`) only affects HWC1 devices.
- **"sailfish.screencap is not running"** (§4) reappeared after installing a new droidmedia: the old `minisfservice` was still running. `kill $(pgrep minisfservice)` fixed it; init restarts the service. `setprop svc.stop …` does nothing; init's control property is `ctl.restart minisf`, with the service name from `init/minisfservice.rc`.
