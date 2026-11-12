# droidmedia `master..hwenc` review: fixes and a smaller diff

**Date:** 2026-11-12
**Basis:** droidmedia `hwenc` `67e65de` plus its uncommitted working tree (15 files, +1601/−16
against `master` `8b82f5e`); qt5-qpa-hwcomposer-plugin `hwenc` `ce61cb6`.
**Status:**
- Part 1 is the plan. Part 2 is its execution: all steps are done in the working trees,
  unstaged. Nothing is committed.
- Host checks pass (§E.3). The HADK build and the device run have not run yet (§E.4).

---

# Part 1: Plan

## Context

Review of droidmedia's `master..hwenc` diff plus its uncommitted working-tree changes, before the
next reviewer reads it. The review found one race in the API, a broken RPM build in the working
tree, two build artifacts in the tree, and a few places where the diff carries more types and
state than it needs. Decisions taken with the user: the test tool leaves the RPM, and the
libminisf window-handle simplification is included together with its plugin edit.

## 1. Bugs

1. **`finish()` races `destroy()` (use after free).** `finish()` called `teardown()`, which
   publishes `STOPPED` and releases `m_lock`, then locked `m_lock` again to read `m_eos`. A
   `destroy()` on another thread waits in `stop()` for `STOPPED` and deletes the object in that
   gap. The header documents `stop()` as safe during `finish()`, and `destroy()` is `stop()` +
   delete.
   Fix: `teardown()` returns `m_eos`, read under the same lock that sets `STOPPED`; `finish()`
   uses the return value and touches nothing of `capture` afterwards.
2. **RPM build fails in the working tree.** `detect_build_targets.sh` was back at master, but
   `rpm/droidmedia.spec` still copied and listed `screencap_surface_capture_test`. At HEAD both
   name the tool unconditionally, while `Android.mk` defines it only for Android ≥ 8 and without
   `LOCAL_32_BIT_ONLY`, so older and 32-bit adaptations would break.
   Fix: `rpm/droidmedia.spec` back to master. The tool stays an `optional` module, built by hand.
3. **Build artifacts in the tree.** `meson.build` had the injected `version :` line and the
   reformatted `project()` call (also in HEAD); `documentation.list` was untracked.
   Fix: `project()` block back to master; delete `documentation.list`.

## 2. Simplifications in droidmedia

4. **Duplicate target enum.** `sailfish::ScreenCaptureTarget` repeated
   `DroidMediaScreenCaptureTarget` and nothing checked it. `screen_capture_service.h` includes
   `droidmediascreencapture.h`, the enum is gone, `screenCaptureTargetValid()` uses
   `DROID_MEDIA_SCREEN_CAPTURE_TARGET_*`.
5. **Two generations in the service.** `m_session.generation` is the live session's (0: none),
   `m_generation` the last one handed out; `sessionLocked()` is gone.
6. **`run()`**: the `continue` branch folded into the error branch.
7. **`private.h`**: the original whitespace-only line restored, so the hunk is pure additions.
8. **Test tool**: no `LOCAL_CPPFLAGS` (it includes only the public C header); a write failure
   sets the `error` flag like the other two error paths.

## 3. libminisf window handle (droidmedia, plugin, `tools/b2-spike`)

9. The handle is the `ANativeWindow` itself, with a reference held through
   `window->common.incRef/decRef`: `minisf_screen_capture_window_acquire(generation)` and
   `minisf_screen_capture_window_release(window)` replace `target_acquire_generation`,
   `target_native_window` and `target_release`. `struct MinisfScreenCaptureTarget` and the
   "Detached from session" log are gone (the plugin logs the detach). An unmatched
   plugin/libminisf pair fails at `android_dlsym` ("capture disabled") instead of misreading the
   handle.
10. The plugin resolves the two new names and passes `m_target` to `eglCreateWindowSurface()`.
11. `b2_spike.c` and its README: the same three-to-two change.

## 4. Comments

12. `droid_media_screen_capture_new()`: which fields of `meta` it uses; profile 0 leaves profile
    and level to the encoder.
13. `teardown()`: returns whether the stream ended; the object may be destroyed once it returns.

## 5. Reviewed, left as they are

- `droid_media_codec_set_h264_profile_level()`: the move out of the encoder builder keeps its
  behaviour (default profile at the caller, level 0 computed); the `static_assert`s cover the
  enum values.
- `stop()` during `finish()` (`m_stop_requested`): `droidscreencapsrc` never does it, but it is
  what makes `destroy()` safe from another thread; with fix 1 it is correct.
- `signal_eos`: only the test tool sets it; it mirrors `DroidMediaCodecCallbacks`.
- Idle screen after a `minisfservice` restart: already a documented limit (`README.md`).
- `sailfish.screencap` has no access check: any process that reaches the service manager can
  register a producer and receive the screen. Expect the question in review; it belongs to
  [`portal-discussion.md`](portal-discussion.md), not to this change.

---

# Part 2: Execution (2026-11-12)

## E.1 What changed

droidmedia (working tree, unstaged): `Android.mk`, `detect_build_targets.sh` and
`rpm/droidmedia.spec` (both now equal to master), `droidmediascreencapture.{h,cpp}`,
`meson.build`, `minisf_screen_capture.cpp`, `private.h`, `screen_capture_service.{h,cpp}`,
`tools/screencap_surface_capture_test.cpp`; `documentation.list` deleted.

`master..` working tree: 13 files, +1560/−13 (was 15 files, +1601/−16). `meson.build` is +2/−1.

qt5-qpa-hwcomposer-plugin: `hwcomposer/hwcomposer_screencapture.{h,cpp}`, +10/−14.

mw: `tools/b2-spike/{b2_spike.c,README.md}`, `README.md`, `wiki/building.md`,
`wiki/checklist.md` (step 12 copies the tool by hand), `scripts/squash-hwenc-review.sh` (commit
message line for the tool), `wiki/init.md`.

## E.2 Deviations from the plan

- The HADK product directory is `out/target/product/pdx224`, not `xqcq54` (that is the
  `droid-local-repo` name). Checklist step 12 copies from `$MW/../../out/target/product/pdx224/`.
- The test tool's `RecordingState::error` is a `bool`, as it is only ever set to `true`.
- `tools/b2-spike`: the `target` field of `struct spike` is now `window`, and the
  "no target" message says "no window"; the session's `target` field is unchanged.
- Not in the plan, not changed: `sc-build` can't tell this build from the gate-5 tweaks one
  (both have the `content %d,%d-%d,%d` format string). `grep -c minisf_screen_capture_window_acquire`
  on `libminisf.so` does.
- Not in the plan, not changed: qt5-qpa-hwcomposer-plugin has untracked build output
  (`documentation.list`, `hwcomposer/.qmake.cache`, `config.log`, `config.tests/…/hwcomposer2`,
  `lib/`, `mkspecs/`, `plugins/`). It is not in the diff, but it should go before the squash.

## E.3 Host checks

From `mw/`:
- `git -C droidmedia diff --stat master`: 13 files, `meson.build` +2/−1, no
  `detect_build_targets.sh` or `rpm/`; `git -C droidmedia status --short` has no untracked file.
- The `grep` for `sessionLocked`, the old enum values, `MinisfScreenCaptureTarget`,
  `target_native_window` and `target_acquire_generation` in `droidmedia`,
  `qt5-qpa-hwcomposer-plugin/hwcomposer` and `tools` finds nothing (besides the
  `DROID_MEDIA_…` enum values).
- `gcc -fsyntax-only -Idroidmedia droidmedia/hybris.c`: OK.
- `gcc -fsyntax-only` of `gstdroidscreencapsrc.c`: OK.
- The fit test of [`building.md`](building.md): `PASS: 0 failed`.
- `gcc -std=gnu99 -Wall -Wextra -fsyntax-only tools/b2-spike/b2_spike.c`: OK, no warnings.
- `g++ -fsyntax-only -Wall -W -Idroidmedia droidmedia/tools/screencap_surface_capture_test.cpp`:
  OK, no warnings.
- The other droidmedia C++ files don't compile on the host (Binder headers); the HADK build does.

## E.4 Build and device run

Not run yet. HADK `croot`:
```sh
make libdroidmedia minimediaservice minisfservice libminisf screencap_surface_capture_test
```
PlatformSDK (`sfossdk`):
```sh
rpm/dhd/helpers/build_packages.sh -g
rpm/dhd/helpers/build_packages.sh -b hybris/mw/qt5-qpa-hwcomposer-plugin
```
gst-droid needs no rebuild (the C API is unchanged). Then [`checklist.md`](checklist.md): steps
1, 3, 4 (first IDR on an idle screen), 5 (`target=virtual`), 7, 12 (test tool, copied by hand),
14 (recorder killed) and 15 (lipstick without capture); 17 if the B2 spike is rebuilt. After a
devel build, `meson.build` has the `version :` line again; drop it before committing.
