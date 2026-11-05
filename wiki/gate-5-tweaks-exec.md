# Gate 5 Tweaks: Execution log

**Date:** 2026-11-03
**Basis:** `gate-5-tweaks.md` (plan), checked against the code and the Qt 5.6.3 sources before execution
**Status:**
- All steps are done in the working trees, unstaged, on top of the staged Gate 5 step 2. Nothing is committed.
- Host checks pass (§4).
- The HADK `out/` binaries of 2026-11-03 23:22 are this build (§2). The device run, `checklist.md`, has not run yet (§6).

## 1. What changed

**Trees (plan §1):**
- Deleted the untracked build outputs of §1.3: both `documentation.list`, `gst-droid/aarch64-meego-linux-gnu/`, the QPA `.qmake.cache`, `config.log`, `config.tests/hwcomposer2/hwcomposer2`, `lib/`, `mkspecs/`, `plugins/`, and the stale `qt5-qpa-hwcomposer-plugin/tools/` (the removed `hwcomposer_screencap_egl_test`).
- Left the ignored files as they are (`.mb2/`, `Makefile`, `.obj/`, `droidmedia/aarch64-meego-linux-gnu/`, `gst-droid/documentation.list`). The generated `hwcomposer/Makefile` still names `hwcomposer_screencapture_fit.h`; qmake regenerates it from the `.pro`.
- `droidmedia/meson.build` is master plus the new header. HEAD (`6f6ad9c`) still has the injected `version :` line, so the working tree differs from HEAD there. The devel spec writes the line again on every devel build (`building.md`).
- `droidmedia/services/services_14_0_0.h` is back to master.
- `hwcomposer_screencapture_fit.h` is deleted and gone from `hwcomposer.pro`. The staged `.pro` listed the untracked file, so the staged tree alone did not build.

**droidmedia:**
- `ScreenCaptureSession` is `{ int64_t generation; int width, height, fps, target; DroidMediaRect content_rect; }`, 40 bytes. `screen_capture_service.h` includes `droidmedia.h`.
- `screenCaptureTargetValid(width, height, target, const DroidMediaRect&)`: all 0, or `0 <= left < right <= width` and `0 <= top < bottom <= height`. No arithmetic, so no overflow.
- The descriptors are `sailfish.IScreenCaptureService` and `sailfish.IScreenCaptureSessionListener` again. The parcels write `left, top, right, bottom`. Logs print `l,t-r,b`.
- libminisf: `minisf_screen_capture_session_query(ScreenCaptureSession *)` copies `s_session`, or a zeroed session. `MinisfScreenCaptureSessionInfo`, `<algorithm>` and `<string.h>` are gone.
- `droid_media_screen_capture_set_target(capture, target, DroidMediaRect content_rect)`, wrapped by `HYBRIS_WRAPPER_1_3` (by value, like `droid_media_convert_set_crop_rect`).
- Comments trimmed per §4.1.

**gst-droid:**
- `content-rect` is a `gst_param_spec_array` of `g_param_spec_int` (0..`G_MAXINT`), `<x, y, width, height>`, stored as a `DroidMediaRect`. `DEFAULT_CONTENT_RECT` and `parse_rect()` are gone.
- `set_target()` gets `src->content_rect`. The start error prints the property syntax, the info log `l,t-r,b`.
- Blurbs and comments trimmed per §2.3 and §4.2, with deviation 4.

**qt5-qpa-hwcomposer-plugin** (5 files against master):
- `MinisfScreenCaptureSessionInfo` has the layout of `ScreenCaptureSession`, without `size`, `memset` or `<string.h>`.
- `CaptureFit { int rotation; QRect viewport; }` and `captureFit(QSize display, QSize session, QRect content, int)` live in `hwcomposer_screencapture.h`, on `QSize::transposed()` and `QSize::scaled(..., Qt::KeepAspectRatio)`.
- `checkSession()` builds the content rect as `QRect(l, t, r - l, b - t)`. `render()` computes the GL y itself.
- `HwComposerScreenCapture` is a `QObject`. The callback posts `QEvent::User` to it, and `event()` runs the `update()`/`requestUpdate()` loop. `RepaintReceiver` and `registerEventType()` are gone.
- The `create()` log is the pre-Gate-5 text again. Restating comments are removed.

**mw:**
- `tools/screencap-fit-test` includes the plugin header and compares `rotation` and `viewport`. `cutils/native_handle.h` is a one-typedef host stub. The GL-y column is gone; that arithmetic is in `render()`.
- `README.md`, `building.md`, `auto-goal1.md` §2.3, and the curated messages of `scripts/squash-hwenc-review.sh`.

## 2. Deviations from the plan

1. **§3.3: the repaint keeps `QQuickWindow::update()`** (user's choice). With this plugin, `isExposed()` stays true after lipstick's `hide()` at display off, because the default `QPlatformWindow::setVisible()` sends a full expose. A synthetic `handleExposeEvent()` would make `QSGThreadedRenderLoop::handleExposure()` render the hidden window to the powered-off display. The `QObject` base and `QEvent::User` from §3.3 are kept; `<QtCore/QMetaObject>` stays.
2. **§3.4: `CaptureFit` has no default member initializers.** It stays an aggregate in C++11, which the plan's host command uses (the device builds with `-std=c++1z`). The content rect is `QRect(l, t, r - l, b - t)`, not inclusive `QPoint` corners.
   - `QSize::scaled()` is the same in Qt 5.6.3 and the host's 5.15.
   - The new fit differs from the old integer math only on sub-pixel ties: the 34 test cases match, and a 145,800-case host sweep (9 panels, sessions 2..4096 in steps of 46, whole frame and an inset rect) found 12 differences, all on 9:20 panels in an inset rect. Each one is 2 px taller, re-centred, even and inside the rect (e.g. 1080x2400 into 168x375 gives 168x374, not 168x372).
3. **§3.2: no `w == 0 && h == 0` special case.** The values map straight to left/top/right/bottom. `<0,0,0,0>` is still the whole frame, and `<10,10,0,0>` becomes `10,10-10,10`, which fails at start; the plan would have turned it into the whole frame without a word. An `x + w` or `y + h` above `G_MAXINT` is ignored with the same warning as a wrong element count.
4. **§2.3: `overloaded = src->waiting_for_keyframe;` stays under `output_lock`.** Reading it after the unlock would race `start()` and `stop()`, which reset it under the lock on another thread. The comment is `/* enqueue_locked() sets it on overflow. */`. The duration comment is `/* No duration: it needs the next access unit, which an idle screen may not send. */`: the plan's "so each access unit is pushed immediately" gives the wrong cause.
5. **§2.2: QPA `target` is `int32_t`, so `checkSession()` logs it with `%d`.** Above `ScreenCaptureSession`, the comment `/* qt5-qpa-hwcomposer-plugin declares the same layout; keep them in sync. */` is back. Without `size`, it is the only guard against layout drift.
   - The QPA `generation` stays `uint64_t`, not the plan's `int64_t`. The layout is the same, and it matches `m_generation`, `PRIu64` and libminisf's `target_acquire_generation(uint64_t)`; `int64_t` would add `-Wsign-compare` warnings.
6. **§5.1: `gate-5.md` and `gate-5-exec.md` stay as history** (user's choice). This log records the tweaks.

Smaller choices:
- `meson.build` keeps the plan's trailing comma after `'droidmediascreencapture.h'`. That is 2 lines added and 1 removed against master.
- The install check greps the log format strings: `content %d,%d-%d,%d` is only in this build, and `content %d,%d %dx%d` only in Gate 5 step 2 (`building.md`).
  - The `set_target` symbol the plan greps for is in step 2 too.
  - The descriptors can't be grepped either: `IMPLEMENT_META_INTERFACE` stores them as UTF-16 (`u"" NAME`, `IInterface.h:163`), so an ASCII `/2` grep prints 0 on every build.
  - Checked on today's `out/` binaries: libminisf, minisfservice and libdroidmedia have the new string and not the old one.
- A negative `content-rect` element never reaches `set_property()`: GObject rejects the value against the element pspec with a `GLib-GObject-CRITICAL`. The old string parser logged a `GST_WARNING`.

## 3. Unchanged on purpose

- `DroidMediaScreenCaptureCallbacks` (plan §3.1).
- `validSessionSize()` and `MaxSessionSize` (4096); only the restating comment is gone.
- The `glClear`, `eglSwapInterval(0)` and `eglGetProcAddress` comments in the QPA.

## 4. Host checks (2026-11-03)

- **Fit test:** `g++ -std=c++17 -Wall -W -fPIC -I/usr/include/qt -Itools/screencap-fit-test tools/screencap-fit-test/screencap_fit_test.cpp -lQt5Core`. Result: 34 cases, `PASS: 0 failed`, no warnings. The same with `-std=c++11`.
- **Syntax:** `gcc -fsyntax-only -Wall -W` on `gstdroidscreencapsrc.c` (GStreamer 1.28 headers) and `gcc -fsyntax-only -Wall` on `droidmedia/hybris.c`: clean.
- **QPA `.cpp`:** `clang++ -std=c++17 -fsyntax-only -Wall -Wextra` against the tree's libhybris and AOSP headers, with an empty `android-config.h`: clean.
- **droidmedia C++** (`screen_capture_service.cpp`, `minisf_screen_capture.cpp`, `droidmediascreencapture.cpp`): not compiled on the host. AOSP's Binder headers clash with glibc there; the HADK build compiles them.
- **Layout:** both struct definitions, extracted from the sources into one file, give equal `offsetof` for every field and 40 bytes, for x86_64 and `--target=aarch64-linux-gnu`.
- **`content-rect` on host GStreamer**, with droidmedia stubbed:

  | Set | Get | Stored l,t,r,b |
  |---|---|---|
  | (default) | `<0, 0, 0, 0>` | 0,0,0,0 |
  | `<0, 0, 1280, 600>` | `<0, 0, 1280, 600>` | 0,0,1280,600 |
  | `<0,0,0,0>` | `<0, 0, 0, 0>` | 0,0,0,0 |
  | `<10, 10, 0, 0>` | `<10, 10, 0, 0>` | 10,10,10,10 (start fails) |
  | `<1, 2, 3>`, `<2147483000, 0, 1000, 10>` | unchanged, with a warning | |
  | `<-1, 0, 10, 10>` | unchanged; GObject CRITICAL | |

- **Indent:** `gst-indent-1.0` is not on the host. GNU indent 2.2.13 with the classic gst-indent options gives exactly the same changes on the edited file as on the staged one (only the `Type * p` spacing of this indent version), so the edits follow gst-indent.
- **Diff size against master:**
  - droidmedia: 15 files, +1598/−15 (was 16 files, +1707/−17);
  - gst-droid: 5 files, +1166/−2 (was +1188/−2);
  - QPA: 5 files, +809/−7.
  - `meson.build` is +2/−1. No untracked files are left in the submodules.
- **Grep:** no `/2"`, `content_x`, `contentX`, `RepaintReceiver` or `_fit.h` is left in the sources, scripts or current docs.

## 5. Build

Build (plan §5.2 B):
```sh
# HADK croot
make libdroidmedia minimediaservice minisfservice libminisf screencap_surface_capture_test
# PlatformSDK
rpm/dhd/helpers/build_packages.sh -g
rpm/dhd/helpers/build_packages.sh -b hybris/mw/droidmedia -s rpm/droidmedia-devel.spec
rpm/dhd/helpers/build_packages.sh -b hybris/mw/gst-droid
rpm/dhd/helpers/build_packages.sh -b hybris/mw/qt5-qpa-hwcomposer-plugin
```
After the devel build, `git -C droidmedia diff master -- meson.build` shows the `version :` line again; drop it before committing.

Install and the device checks are `checklist.md`, from step 1 (§6).

## 6. Device checks

The device run is `checklist.md`, steps 0–16. It repeats Gates 5.1 and 5.2 of `gate-5.md` §2 on this build, with the regression set that `gate-5.md` §2 asks for after each deploy. For this build:
- step 2 (old service) applies: until step 3, the device runs the step 2 `minisfservice`, with the `/2` descriptors;
- `content-rect` takes the array syntax;
- step 6 (display off) checks deviation 1.

Step 2 covers the step 2 to tweaks transition only. A pre-Gate-5 service has the same descriptors as this build and a shorter parcel. The new readers would get target 0 and an all-zero rect past its end. As a result:
- `content-rect` is ignored;
- a `target=virtual` session is mirrored;
- frame requests are dropped as unknown transactions.

That is the matched-set contract of `auto-goal1.md` §2.3.

### 6.1 Results

| Step | Check | Result |
|---|---|---|
| 1 | copy, install, `sc-build` | not run |
| 2 | old `minisfservice` (5.1) | not run |
| 3 | restart, `gst-inspect-1.0` | not run |
| 4 | first IDR, key units on an idle screen (5.1) | not run |
| 5 | `target=virtual` (5.1) | not run |
| 6 | display off (5.1) | not run |
| 7 | portrait and landscape, raw and MP4 | not run |
| 8 | `ffprobe` | not run |
| 9 | Gallery playback | not run |
| 10 | letterbox, content rect, levels (5.2) | not run |
| 11 | streaming to the host | not run |
| 12 | droidmedia test tool | not run |
| 13 | app in qt-runner (optional) | not run |
| 14 | recorder killed | not run |
| 15 | lipstick without capture | not run |
| 16 | camera recording | not run |
