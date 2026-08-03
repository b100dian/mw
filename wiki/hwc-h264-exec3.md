# HWC H.264 Encoding — Execution 3

**Date:** 2026-08-02
**Basis:** `wiki/hwc-h264-encoding-revision2.md`  
**Target:** v1 screen recording with one CPU copy into the hardware H.264 encoder; no audio; zero-copy deferred.

## 1. Execution status and constraints

Revision 2 identified two hard blockers before HWC/GStreamer integration can be meaningful:

1. The QPA plugin directly includes the `droidmedia` API even though its build does not declare that dependency.
2. The encoder path crashes in `MediaBuffer` ownership/refcount handling before producing output.

The staged implementation is being corrected in source. The Android build root is available and `droidmedia` was built successfully against the configured A14/`lineage_pdx224` target during this execution; it emitted only the existing `IServiceManager::getService()` deprecation warning in `screen_capture.cpp`. Device-only checks (`ffprobe`, gralloc import, Binder/SELinux, HWC output) remain pending.

The implementation order is deliberately gated:

- **0′ — build boundary:** expose the screen-capture producer/consumer/dimension API from `libminisf.so`; make the QPA plugin resolve it at runtime and remove its direct `droidmedia` include/dependency.
- **1′ — encoder correctness:** make the production source copy RGBA in `meta_data=0` mode, provide complete raw-frame metadata, make the metadata path an explicit opt-in/fallback, and fix reader/source shutdown ordering so returned buffers cannot outlive the source. Keep the standalone harness aligned with the ownership contract.
- **2′ — BufferQueue lifecycle:** stop installing the old callback listener on the consumer wrapper; add a source-owned listener/condition and interruptible reads; constrain acquired buffers to the HWC slot budget; guard consumer-side release bookkeeping.
- **3′ — HWC producer safety:** first implement the low-risk correctness fixes to the existing GPU fallback (viewport dimensions, bounded fence wait, per-window GL resources). The `attachBuffer` producer path is not implemented blindly: it requires the Tier-2 cross-process gralloc probe and device confirmation because it couples HWC buffer lifetime to encoder backpressure.
- **4′ — GStreamer lifecycle:** default the element to copy mode, add an opt-in metadata property, wake blocked `create()` calls during stop/flush, and bound the encoded-output queue.
- **5′ — validation/documentation:** add host-visible source checks and target-SDK build recipes where possible; document that this checkout cannot claim device success until Tier 1 (`ffprobe`) and the later Binder/HWC tests run on target.

## 2. Planned file changes

### 2.1 `libminisf` build boundary (Phase 0′)

- Add a small `minisf_screen_capture.cpp` implementation to `libminisf`.
- Export `minisf_screen_capture_init`, `minisf_screen_capture_consumer_new`, and `minisf_screen_capture_get_dimensions` as C symbols, forwarding to the existing `libdroidmedia` implementation.
- Add that source to the `libminisf` module; keep the existing `libminisf -> libdroidmedia` dependency and do not introduce the reverse edge.
- Add a tiny public declaration header usable by the QPA plugin without importing `droidmedia` headers.
- Resolve the three symbols beside `startMiniSurfaceFlinger` through the already-loaded `libminisf` handle. Fail capture initialization cleanly if any symbol is unavailable.
- Remove `<droidmedia/droidmedia.h>` and direct droidmedia screen-capture calls from `hwcomposer_backend_v20.cpp`; leave `hwcomposer.pro` and its RPM build requirements unchanged.

### 2.2 Encoder/source (Phase 1′)

- Add an explicit `metadataMode` selection to `ScreenCaptureMediaSource`; production defaults to copy mode because the target rejected `meta_data=1`.
- In copy mode, acquire the `GraphicBuffer`, lock with read usage, copy visible rows using the source stride, unlock, release the BufferQueue item immediately, and return a plain unobserved `MediaBuffer` containing actual RGBA pixels. Set `kKeyMaxInputSize`, stride, and slice height.
- In metadata mode, retain the existing handle payload only when explicitly selected; mark it internally and retain it with Android's standard `MediaBufferHolder`; do not claim it is the default.
- Make encoder creation try the requested metadata mode, then retry with copy mode if metadata codec creation returns `NULL`. Report the selected mode through the encoder API/logging.
- Preserve timestamps and define a clear source state for start/stop/read errors.
- Do not use an ad-hoc long-lived reference to a returned `MediaBuffer`: the synchronous `AsyncCodecSource` input copy owns/release-completes the source buffer. Ensure `AsyncCodecSource::stop()` stops the reader thread before stopping/destroying the underlying source, and make the reader observe read errors rather than treating an uninitialized buffer as EOS.
- Update the standalone harness comments and cleanup to use the same safe ownership/lifecycle assumptions. Its pass condition must require all requested frames and a non-empty output; decodability remains a device-gated `ffprobe` check.

### 2.3 BufferQueue/lifecycle (Phase 2′)

- Do not call `_DroidMediaBufferQueue::connectListener()` for the consumer used by `ScreenCaptureMediaSource`; direct `acquireBuffer()` and the legacy listener cannot race.
- Add a source-owned `ConsumerListener` and condition variable. `read()` waits in short bounded intervals and checks `mStarted`; `stop()` disconnects/signals so it cannot leave the encoder blocked for five seconds.
- Configure `maxAcquiredBufferCount` to no more than the HWC slot budget (3 for the chosen v1 path), with error logging/failure handling.
- Make screen-capture initialization all-or-nothing: only publish the consumer after producer wrapping succeeds and return an error/null output on failure.
- Make consumer-side wrapper release helpers reject the legacy slot-map path unless the slot/frame-number bookkeeping is valid; the capture source continues to release using the acquired item’s slot and frame number.

### 2.4 HWC and GStreamer safety (Phases 3′–4′)

- Fix the existing GPU fallback’s ignored destination dimensions and 1×1 viewport, use a bounded fence wait, and move FBO/program ownership from function statics to `HWC2Window` lifecycle. This fallback is kept correct even while `attachBuffer` remains gated on device probing.
- Add `flushing`/stop wakeup handling to `droidscreencapsrc`, reset it on start, and make `create()` return `GST_FLOW_FLUSHING` rather than wait forever.
- Bound the output queue to a small live-capture limit and drop the oldest non-keyframe (or oldest frame if no better candidate exists) when full.
- Add `metadata-mode` as an opt-in property with default `FALSE`, pass the chosen mode into the encoder API, and update user-facing descriptions to say copy mode is the supported default.

## 3. Validation gates

1. **Source/build inspection:** no QPA source includes `droidmedia`; the new `libminisf` symbols are declared, defined, added to the module, and resolved through the existing Android loader. The configured Android `droidmedia` build passed; only the `getService()` deprecation warning was reported.
2. **Tier 1 device gate (not available locally):** build/install `libdroidmedia`, `libminisf`, `libgstdroid`, QPA, and `screencap_enc_test`; run copy mode; require clean exit, non-zero H.264, `ffprobe` success, and a decoded frame.
3. **Tier 2 device gate (not available locally):** run the BufferQueue/`attachBuffer` gralloc probe. Only if cross-process `lock()` succeeds should the HWC producer be changed to attach source buffers; otherwise keep the corrected GPU fallback.
4. **Tier 3/4 device gates:** PPM/full-screen validation from HWC and then the end-to-end GStreamer pipeline, followed by stop/restart, process-kill, and resolution-change tests.

No device result is recorded as passed by this execution note. In particular, the previous “Phase-0 passed” claim is not reused. The successful build is not a Tier-1 runtime pass. The subsequent source edits in this execution (metadata holder alignment, GStreamer lifecycle changes, and harness cleanup) have not been rebuilt yet because the user is running the build.

## 4. Non-goals

- No audio path.
- No claim of Codec2 `C2GraphicBlock` zero-copy.
- No SELinux policy invented without the target droid-hal policy layout; SELinux additions remain a packaging/device follow-up after the service context and audit logs are available.
- No commit or branch creation.

## 5. Build update

The user-built Android `droidmedia` target completed successfully. The only reported diagnostic was the A14 deprecation warning for `IServiceManager::getService()` in `screen_capture.cpp:80`; this is retained for cross-version behavior and is not a build failure. The next build should cover the post-build source edits before any device Tier-1 run.
