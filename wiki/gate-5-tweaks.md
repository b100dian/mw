# Gate 5 Tweaks: Review Preparation, Code Reuse, and Comment Cleanup

**Date:** 2026-11-03
**Basis:** `gate-5.md`, `gate-5-exec.md`, `cleanup-plan.md`, and current staged changes on `hwenc`
**Goal:** Prepare the `master..hwenc` diff (including Gate 5 Steps 1 & 2) for upstream review by:
1. Stripping timeline-referring comments and unshipped forward/backward-compatibility scaffolding.
2. Minimizing the diff against `master` across all three submodules (`droidmedia`, `gst-droid`, `qt5-qpa-hwcomposer-plugin`).
3. Reusing existing types and idioms (`DroidMediaRect`, `gst_param_spec_array`, `QWindowSystemInterface::handleExposeEvent`, `QRect`/`QSize::scaled`).
4. Lowering comment verbosity so comments are concise and focused on non-obvious constraints.
5. Ensuring all build and test instructions are complete, accurate, and up to date.

---

## 1. Minimize Diff Against `master` & Clean Working Trees

### 1.1 Revert unintended file modifications in `droidmedia`
- **`droidmedia/meson.build`**:
  - Unstage and revert the build-injected `version : 'hwenc.gate4+hwenc.20261023220925.769f0cb'` line and the `project()` formatting change.
  - Keep only the addition of `'droidmediascreencapture.h'` to `droidmedia_headers` (reducing `meson.build` diff against `master` to 2 lines).
- **`droidmedia/services/services_14_0_0.h`**:
  - Revert the `android.permission.DUMP` check and the `int32_t pid, int32_t uid` parameter rename in `MiniPermissionController::checkPermission()` back to `master` (left over from early `dumpsys` debugging; `pid` is also unused).

### 1.2 Fold `hwcomposer_screencapture_fit.h` into `hwcomposer_screencapture.{h,cpp}`
- Delete the untracked `qt5-qpa-hwcomposer-plugin/hwcomposer/hwcomposer_screencapture_fit.h` and remove it from `hwcomposer/hwcomposer.pro`.
- Keep the fit helper in `hwcomposer_screencapture.h` / `hwcomposer_screencapture.cpp` using `<QtCore/QRect>` and `<QtCore/QSize>`, so `qt5-qpa-hwcomposer-plugin` touches only 5 files total against `master`.

### 1.3 Clean untracked build artifacts before squashing
- Remove untracked build outputs left in submodule trees:
  - `droidmedia/documentation.list`
  - `gst-droid/aarch64-meego-linux-gnu/`
  - `qt5-qpa-hwcomposer-plugin/documentation.list`, `hwcomposer/.qmake.cache`, `hwcomposer/config.log`, `hwcomposer/config.tests/hwcomposer2/hwcomposer2`, `hwcomposer/lib/`, `hwcomposer/mkspecs/`, `hwcomposer/plugins/`, `qt5-qpa-hwcomposer-plugin/tools/`

---

## 2. Strip Unshipped Versioning, Forward-Compat Scaffolding, and Timeline Comments

Because `hwenc` has not yet shipped upstream, reviewers see a single squashed `master..hwenc` commit per repo. Versioning against intermediate `hwenc` builds and comments explaining what changed from earlier gates are noise and should be removed.

### 2.1 Remove Binder interface `/2` suffix and parcel-evolution comments (`droidmedia`)
- In `screen_capture_service.cpp`:
  - Change `"sailfish.IScreenCaptureSessionListener/2"` back to `"sailfish.IScreenCaptureSessionListener"`.
  - Change `"sailfish.IScreenCaptureService/2"` back to `"sailfish.IScreenCaptureService"`.
  - Remove `// The version suffix makes a peer built for another layout fail CHECK_INTERFACE.`
  - Remove `// A reader of an older layout leaves the tail unread; one of a newer layout reads zeros past the end.` above `writeSession()`.
- In `screen_capture_service.h`:
  - Remove `/* New fields go at the end, and into the end of every parcel. */` above `ScreenCaptureSession`.

### 2.2 Remove `MinisfScreenCaptureSessionInfo::size` forward-compat copying (`droidmedia` & QPA)
- In `droidmedia/minisf_screen_capture.cpp`:
  - Remove `struct MinisfScreenCaptureSessionInfo` and its comment about older/newer callers.
  - Have `minisf_screen_capture_session_query(ScreenCaptureSession *info)` take `ScreenCaptureSession *` directly (as before Step 2) and assign `*info = s_session;` (or `*info = ScreenCaptureSession();` when disconnected), dropping `<algorithm>`, `<string.h>`, `memset`, and `memcpy(..., std::min(...))`.
- In `qt5-qpa-hwcomposer-plugin/hwcomposer/hwcomposer_screencapture.cpp`:
  - Remove `uint32_t size;` from `MinisfScreenCaptureSessionInfo` so its layout matches `sailfish::ScreenCaptureSession` directly:
    ```cpp
    struct MinisfScreenCaptureSessionInfo {
        int64_t generation;
        int32_t width;
        int32_t height;
        int32_t fps;
        int32_t target;
        int32_t contentLeft;
        int32_t contentTop;
        int32_t contentRight;
        int32_t contentBottom;
    };
    ```
  - Remove `memset(&info, 0, sizeof(info)); info.size = sizeof(info);` in `sessionCallback()` and `checkSession()`, and drop `#include <string.h>`.
  - Replace the comment `// libminisf's session ... It fills only the first size bytes, so this copy may lag behind or run ahead of it.` with `// Matches sailfish::ScreenCaptureSession in droidmedia/screen_capture_service.h.`.

### 2.3 Strip timeline-referring comments and log messages
- **`qt5-qpa-hwcomposer-plugin/hwcomposer/hwcomposer_screencapture.h`**:
  - Remove `"Any even session size up to 4096 works."` and `"Every rendered frame is sent; the session's fps is only the encoder's nominal rate. The compositor renders only when the screen changes, so the last frame before a still screen must not be dropped."` (which contrasts with the removed Gate 4 display-size-only and fps-cap behavior).
- **`qt5-qpa-hwcomposer-plugin/hwcomposer/hwcomposer_screencapture.cpp`**:
  - In `create()`, revert the log message from `"screencap: enabled for a %dx%d display, any session size, landscape rotation %d"` back to `"screencap: enabled for a %dx%d display, landscape rotation %d"`.
  - In `checkSession()`, remove `// Reads libminisf's copy of the session, which the service keeps up to date.` (contrasts with old Binder polling).
- **`droidmedia/minisf_screen_capture.cpp`**:
  - In the top file comment, remove `"a session query reads the state the service pushes, and only connecting to the service and acquiring a target make Binder calls."`
- **`gst-droid/gst/droidscreencapsrc/gstdroidscreencapsrc.c`**:
  - In `data_available()`, replace `/* No duration: it is only known once the next access unit arrives, and waiting for that would keep the last frame of a still screen from a live viewer. */` with `/* Leave duration unset so each access unit is pushed immediately. */`
  - Replace `/* Clear before enqueue_locked(), so set means this frame overflowed. */` with `/* waiting_for_keyframe is false before enqueue_locked(), so true means this frame overflowed. */` (or inline `if (src->waiting_for_keyframe)` into `overloaded`).

---

## 3. Reuse Existing Code and Idioms

### 3.1 Reuse `DroidMediaRect` in `droidmedia`
`droidmedia.h` (already included by `droidmediascreencapture.h`) defines:
```c
typedef struct {
  int32_t left;
  int32_t top;
  int32_t right;
  int32_t bottom;
} DroidMediaRect;
```
which is already used in `droidmediabuffer.h`, `droidmediacodec.h`, `droidmediaconvert.h`, and `gst-droid`.

- **`droidmediascreencapture.h`**:
  - Change `droid_media_screen_capture_set_target()` to take `DroidMediaRect rect`:
    ```c
    bool droid_media_screen_capture_set_target(DroidMediaScreenCapture *capture,
                                               DroidMediaScreenCaptureTarget target,
                                               DroidMediaRect content_rect);
    ```
  - Keep `DroidMediaScreenCaptureCallbacks` as a single struct passed to `droid_media_screen_capture_new()` (splitting into `DroidMediaCodecCallbacks` + `DroidMediaCodecDataCallbacks` would require two extra setter functions/wrappers and expose an unused `size_changed` callback).
- **`hybris.c`**:
  - Change wrapper from `HYBRIS_WRAPPER_1_6` to:
    ```c
    HYBRIS_WRAPPER_1_3(bool,DroidMediaScreenCapture*,DroidMediaScreenCaptureTarget,DroidMediaRect,droid_media_screen_capture_set_target);
    ```
    (matching `HYBRIS_WRAPPER_0_4(DroidMediaConvert*,DroidMediaRect,int32_t,int32_t,droid_media_convert_set_crop_rect)` at `hybris.c:266`).
- **`screen_capture_service.h` & `screen_capture_service.cpp`**:
  - Include `"droidmedia.h"` (or use `DroidMediaRect content_rect` in `ScreenCaptureSession` instead of `content_x`, `content_y`, `content_width`, `content_height`).
  - Simplify `screenCaptureTargetValid(int width, int height, int target, const DroidMediaRect& rect)`:
    ```cpp
    bool screenCaptureTargetValid(int width, int height, int target, const DroidMediaRect& rect)
    {
      if (target != SCREEN_CAPTURE_TARGET_DISPLAY && target != SCREEN_CAPTURE_TARGET_VIRTUAL) {
        return false;
      }
      if (rect.left == 0 && rect.top == 0 && rect.right == 0 && rect.bottom == 0) {
        return true;
      }
      return rect.left >= 0 && rect.top >= 0 &&
             rect.left < rect.right && rect.top < rect.bottom &&
             rect.right <= width && rect.bottom <= height;
    }
    ```
  - Serialize `rect.left`, `rect.top`, `rect.right`, `rect.bottom` in `writeSession()` / `readSession()`.
- **`droidmediascreencapture.cpp`**:
  - Replace `m_content_x`, `m_content_y`, `m_content_width`, `m_content_height` with `DroidMediaRect m_content_rect`.

### 3.2 Reuse `gst_param_spec_array` and `DroidMediaRect` in `gst-droid`
GStreamer elements (`GstVideoOverlay` `render-rectangle` in `videooverlay.c:534`, `v4l2src` `crop-bounds` in `gstv4l2src.c:233`) represent `(x, y, width, height)` rectangles using `gst_param_spec_array`.

- **`gstdroidscreencapsrc.h`**:
  - Replace `gint content_x, content_y, content_width, content_height;` with `DroidMediaRect content_rect;`.
- **`gstdroidscreencapsrc.c`**:
  - Remove `DEFAULT_CONTENT_RECT` and delete `gst_droidscreencapsrc_parse_rect()` completely (saving ~30 lines of manual string splitting/parsing).
  - Install `content-rect` with `gst_param_spec_array`:
    ```c
    g_object_class_install_property (gobject_class, PROP_CONTENT_RECT,
        gst_param_spec_array ("content-rect", "Content rectangle",
            "Content rectangle ('<x, y, width, height>', all 0 for the whole frame)",
            g_param_spec_int ("rect-value", "Rectangle Value",
                "One of x, y, width or height", 0, G_MAXINT, 0,
                G_PARAM_READWRITE | G_PARAM_STATIC_STRINGS),
            G_PARAM_READWRITE | G_PARAM_STATIC_STRINGS |
            GST_PARAM_MUTABLE_READY));
    ```
  - In `gst_droidscreencapsrc_set_property()`:
    ```c
    case PROP_CONTENT_RECT:{
      gint x, y, w, h;

      if (gst_value_array_get_size (value) != 4) {
        GST_WARNING_OBJECT (src,
            "ignoring content-rect: expected <x, y, width, height>");
        break;
      }
      x = g_value_get_int (gst_value_array_get_value (value, 0));
      y = g_value_get_int (gst_value_array_get_value (value, 1));
      w = g_value_get_int (gst_value_array_get_value (value, 2));
      h = g_value_get_int (gst_value_array_get_value (value, 3));
      if (w == 0 && h == 0) {
        memset (&src->content_rect, 0, sizeof (src->content_rect));
      } else {
        src->content_rect.left = x;
        src->content_rect.top = y;
        src->content_rect.right = x + w;
        src->content_rect.bottom = y + h;
      }
      break;
    }
    ```
  - In `gst_droidscreencapsrc_get_property()`:
    - Append `left`, `top`, `right - left`, `bottom - top` to `value` with `gst_value_array_append_value()`.
  - In `gst_droidscreencapsrc_start()`:
    - Pass `src->content_rect` directly to `droid_media_screen_capture_set_target(capture, src->target, src->content_rect)`.

### 3.3 Reuse `QWindowSystemInterface::handleExposeEvent` in `qt5-qpa-hwcomposer-plugin`
- **`hwcomposer_screencapture.h` & `hwcomposer_screencapture.cpp`**:
  - Make `HwComposerScreenCapture` inherit `public QObject` and override `bool event(QEvent *e) override` (using `QEvent::User`, matching `HwComposerBackend_v11::event()` and `HwComposerBackend_v20::event()`).
  - Delete `class RepaintReceiver` and `QObject *m_repaintReceiver` (saving ~30 lines and an extra heap object).
  - Remove `#include <QtCore/QMetaObject>`. Add `#include <qpa/qwindowsysteminterface.h>` (already used in `qeglfswindow.cpp:43` and `qeglfsscreen.cpp:52`).
  - In `sessionCallback()`, post `new QEvent(QEvent::User)` directly to `capture`:
    ```cpp
    QCoreApplication::postEvent(capture, new QEvent(QEvent::User));
    ```
  - In `HwComposerScreenCapture::event(QEvent *e)`:
    ```cpp
    bool HwComposerScreenCapture::event(QEvent *e)
    {
        if (e->type() != QEvent::User)
            return QObject::event(e);

        for (QWindow *window : QGuiApplication::topLevelWindows()) {
            if (window->isExposed())
                QWindowSystemInterface::handleExposeEvent(window, QRegion(QPoint(), window->size()));
        }
        return true;
    }
    ```
  - **Why `if (window->isExposed())` is kept:** `QGuiApplicationPrivate::processExposeEvent()` sets `window->d_func()->exposed = !region.isEmpty()`. Checking `window->isExposed()` first ensures we do not mark lipstick's window exposed while the display is asleep, while for an already-exposed `QQuickWindow`, `QQuickWindow::exposeEvent()` -> `QSGThreadedRenderLoop::handleExposure()` calls `polishAndSync(w, true /* inExpose */)`, which forces a render and swap even when the scene graph is unchanged.

### 3.4 Reuse `QRect` and `QSize::scaled(..., Qt::KeepAspectRatio)` in `qt5-qpa-hwcomposer-plugin`
Matching `nemo-qtmultimedia-plugins/src/videotexturebackend/videotexturebackend.cpp:740`:
- Define `CaptureFit` and `captureFit()` in `hwcomposer_screencapture.h`:
  ```cpp
  struct CaptureFit {
      int rotation = 0;
      QRect viewport;
  };

  inline CaptureFit captureFit(const QSize &display, const QSize &session,
                               const QRect &content, int landscapeRotation)
  {
      const QRect rect = content.isEmpty() ? QRect(QPoint(), session) : content;
      const bool rotate = (rect.width() > rect.height() && display.width() < display.height()) ||
                          (rect.width() < rect.height() && display.width() > display.height());
      const QSize source = rotate ? display.transposed() : display;

      QSize fitted = source.scaled(rect.size(), Qt::KeepAspectRatio);
      fitted.rwidth() &= ~1;
      fitted.rheight() &= ~1;

      return {
          rotate ? landscapeRotation : 0,
          QRect(rect.x() + (rect.width() - fitted.width()) / 2,
                rect.y() + (rect.height() - fitted.height()) / 2,
                fitted.width(), fitted.height())
      };
  }
  ```
- Note: `QSize::transposed()` is in Qt 5.0+ (`qsize.h`), and `QSize::scaled(rect.size(), Qt::KeepAspectRatio)` uses `qint64` cross-multiplication internally in QtCore (`qsize.cpp`), preserving exact integer aspect ratios just like the manual `int64_t` math did.
- In `HwComposerScreenCapture::checkSession()`:
  ```cpp
  const QRect content(QPoint(info.contentLeft, info.contentTop),
                      QPoint(info.contentRight - 1, info.contentBottom - 1));
  attach(info, captureFit(QSize(m_displayWidth, m_displayHeight),
                          QSize(info.width, info.height),
                          content, m_landscapeRotation));
  ```
- In `HwComposerScreenCapture::render()`:
  ```cpp
  const QRect &vp = m_fit.viewport;
  glViewport(vp.x(), m_height - vp.y() - vp.height(), vp.width(), vp.height());
  ```
- Update `mw/tools/screencap-fit-test/screencap_fit_test.cpp` to include `<QRect>` and `<QSize>` and build with:
  ```sh
  g++ -std=c++11 -Wall -W -fPIC -I/usr/include/qt -I/usr/include/qt/QtCore     screencap_fit_test.cpp -lQt5Core -o /tmp/screencap_fit_test && /tmp/screencap_fit_test
  ```

---

## 4. Comment Focus & Verbosity Reduction

Reviewers should see short, factual comments only where the code is non-obvious.

### 4.1 `droidmedia`
- **`droidmediascreencapture.h`**:
  - Shorten the top block comment from 9 lines to 3 lines:
    `/* Hardware H.264 screen recorder using an Android input Surface registered with sailfish.screencap. Single-use: new, [set_target], start, finish/stop, destroy. */`
  - Trim `droid_media_screen_capture_new`, `set_target`, `request_sync_frame`, `finish`, and `stop` docblocks to 1–2 lines each.
- **`droidmediascreencapture.cpp`**:
  - Keep the 1-line comments on `DETACH_GRACE_MS`, `startThreadPool()`, publishing the producer after `m_codec->start()`, `requestFrame()` in `request_sync_frame()`, and `m_lock` not being held during callbacks.
  - Trim multi-sentence prose comments to 1 line each.
- **`screen_capture_service.{h,cpp}`**:
  - Trim the class header comment above `IScreenCaptureService` from 9 lines to 3 lines.
  - Trim `notifyLocked()` and `requestFrame()` comments to 1 line: `// Hold m_lock so oneway listener calls arrive in generation order.`
- **`minisf_screen_capture.cpp`**:
  - Trim the file header comment and `minisf_screen_capture_set_callback` comment to 2 lines each.

### 4.2 `gst-droid`
- **`gstdroidscreencapsrc.c`**:
  - Shorten the top element comment to state the pipeline usage and core behavior (Surface input, sparse PTS, in-band SPS/PPS, `GstForceKeyUnit` support) without repeating every property description.
  - Shorten property blurbs (`width`, `fps`, `level`, `content-rect`) to 1 concise sentence each, matching `gstdroidcamsrc.c` / `gstdroidvenc.c`.
  - Keep concise 1–2 line comments for non-obvious GStreamer mechanics:
    - Why `codec_config` is cached and prepended to IDR frames instead of pushed as a buffer.
    - Why duplicate PTS are dropped.
    - Why `send_event()` intercepts `EOS` and `GstForceKeyUnit`.
    - Why `stop()` drops `output_lock` before `droid_media_screen_capture_stop()`.

### 4.3 `qt5-qpa-hwcomposer-plugin`
- **`hwcomposer_screencapture.h`**:
  - Condense the 16-line class comment to 5 lines describing the flow (`bufferPresented()` -> `captureFrame()` -> `captureFit()` into the `sailfish.screencap` Surface for `DISPLAY` sessions, plus expose-driven repaints on session changes and frame requests).
- **`hwcomposer_screencapture.cpp`**:
  - Remove comments that restate the code (`// The largest session side accepted`, `// Clip space, -1..+1 is the whole viewport`, `// libminisf's session targets and callback events`).
  - Keep the 1-line comments explaining:
    - Why `glClear` is required every frame (undefined buffer contents after swap + Adreno tile load).
    - Why `eglSwapInterval(0)` is set (async mode so lipstick never blocks on the encoder).
    - Why `eglGetProcAddress` is used for `EGLImage` functions (libhybris buffer mapping).

---

## 5. Build and Testing Instructions Check

### 5.1 Documentation updates to align with the tweaks
1. **`wiki/building.md`**:
   - Replace the stale `make screencap_enc_test` at line 30 with:
     ```sh
     make libdroidmedia libminisf minisfservice screencap_surface_capture_test
     ```
   - Add the `rpm -Uvh --force` note for reinstalling rebuilt `droidmedia` RPMs when the git commit hash has not changed (`gate-5-exec.md` §4).
2. **`README.md`, `wiki/gate-5.md`, `wiki/gate-5-exec.md`**:
   - Update `content-rect` examples and documentation from `"0,0,1280,600"` to GStreamer array syntax `"<0, 0, 1280, 600>"`:
     ```sh
     gst-launch-1.0 -e droidscreencapsrc width=1280 height=720 content-rect="<0, 0, 1280, 600>" !        h264parse ! filesink location=/tmp/rect.h264
     ```
   - Remove mentions of `/2` Binder interface descriptor suffixes and `MinisfScreenCaptureSessionInfo::size` in `README.md` ("Components", "Build and deploy"), `wiki/gate-5.md` (§1.1, §2.1), and `wiki/auto-goal1.md` (§2.3).
   - Update `README.md` ("Components") and `wiki/gate-5.md` (§1.3) to describe `QWindowSystemInterface::handleExposeEvent` instead of `RepaintReceiver` / `QQuickWindow::update()`.
   - Update `scripts/squash-hwenc-review.sh` curated commit messages (`get_curated_msg`) so they include the Gate 5 additions (H.264 profile/level, `target` and `content_rect`, `request_sync_frame` / `GstForceKeyUnit`, and QPA `captureFit` letterboxing).

### 5.2 Verification & Test Plan

#### Step A: Host checks (no device needed)
1. **Fit unit test (`tools/screencap-fit-test`)**:
   ```sh
   g++ -std=c++11 -Wall -W -fPIC -I/usr/include/qt -I/usr/include/qt/QtCore      tools/screencap-fit-test/screencap_fit_test.cpp -lQt5Core -o /tmp/screencap_fit_test &&
     /tmp/screencap_fit_test
   ```
   Pass: 34/34 cases pass (`PASS: 0 failed`).

#### Step B: Build & deploy matched set
1. **In HADK Android build env (`croot`)**:
   ```sh
   make libdroidmedia libminisf minisfservice screencap_surface_capture_test
   ```
2. **In PlatformSDK (`sfossdk`)**:
   ```sh
   rpm/dhd/helpers/build_packages.sh -g
   rpm/dhd/helpers/build_packages.sh -b hybris/mw/droidmedia -s rpm/droidmedia-devel.spec
   rpm/dhd/helpers/build_packages.sh -b hybris/mw/gst-droid
   rpm/dhd/helpers/build_packages.sh -b hybris/mw/qt5-qpa-hwcomposer-plugin
   ```
3. **On device (`devel-su`)**:
   ```sh
   rpm -Uvh --force droidmedia-*.rpm droidmedia-devel-*.rpm gstreamer1.0-droid-*.rpm qt5-qpa-hwcomposer-plugin-*.rpm
   kill $(pgrep minisfservice)
   systemctl-user restart lipstick.service
   ```
   Verify symbols in `libdroidmedia.so`:
   ```sh
   grep -c droid_media_screen_capture_set_target /usr/libexec/droid-hybris/system/lib64/libdroidmedia.so
   ```

#### Step C: Device Gate 5 verification
1. **Inspect properties (`gst-inspect-1.0`)**:
   ```sh
   gst-inspect-1.0 droidscreencapsrc
   ```
   Verify `Rank: none (0)` and properties `width`, `height`, `target-bitrate`, `fps`, `profile`, `level`, `target`, and `content-rect` (`GstValueArray` of `gint`).
2. **Gate 5.1 — Repaint & `GstForceKeyUnit` on an idle screen (verifies `handleExposeEvent`)**:
   Leave the phone screen untouched and run:
   ```python
   python3 - << 'PY'
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
   PY
   ffprobe -v quiet -show_entries frame=pict_type,pkt_size -of csv=p=0 /tmp/fku.h264
   ```
   Pass: Initial IDR arrives without touching the screen, and each 5 s `GstForceKeyUnit` produces an `I` frame on the idle screen.
3. **Gate 5.1 — `target=virtual` ignored by lipstick**:
   ```sh
   gst-launch-1.0 -q -e droidscreencapsrc width=1280 height=720 target=virtual ! h264parse ! filesink location=/tmp/virt.h264 &
   p=$!; sleep 5; kill -INT $p; wait $p
   ls -l /tmp/virt.h264
   devel-su journalctl -b | grep "screencap:"
   ```
   Pass: `/tmp/virt.h264` is 0 bytes; journal logs `screencap: ignoring session ...: target 1 is not the display`.
4. **Gate 5.2 — Letterbox sizes, `content-rect` array, and H.264 profile/level**:
   ```sh
   r() { n=$1; shift; gst-launch-1.0 -q -e droidscreencapsrc "$@" ! h264parse ! filesink location=/tmp/$n.h264 & p=$!; sleep ${S:-10}; kill -INT $p; wait $p; }
   r s800  width=800  height=480
   r s1280 width=1280 height=720
   r s1920 width=1920 height=1080
   r s720p width=720  height=1280
   r rect  width=1280 height=720 content-rect="<0, 0, 1280, 600>"
   r l31   width=1280 height=720 fps=30 profile=constrained-baseline level=31
   r l32   width=1280 height=720 fps=60 profile=constrained-baseline level=32
   devel-su journalctl -b | grep -E "screencap: (attached|session)"
   ffprobe -v quiet -show_entries stream=profile,level,width,height -of csv=p=0 /tmp/l31.h264 /tmp/l32.h264 /tmp/rect.h264
   ```
   Pass: Viewports match the table (`0,69 800x342`, `0,86 1280x548`, `0,129 1920x822`, `86,0 548x1280`, `0,26 1280x548`), `ffprobe` reports `Constrained Baseline,31` and `Constrained Baseline,32`, and each session detaches cleanly.
5. **Regression checklist (`README.md`)**:
   - Portrait (`1080x2520`) and landscape (`2520x1080`) raw `.h264` and `.mp4` (`qtmux`).
   - Live TCP stream (`scripts/sharing-tcp.sh` + `scripts/receiving-tcp.sh`).
   - Recorder killed with `pkill -9 -f droidscreencapsrc`, followed by a fresh recording session.
   - Standalone droidmedia tool: `/usr/libexec/droid-hybris/system/bin/screencap_surface_capture_test 1080 2520 8000000 30 5 /tmp/t.h264`.
   - Camera video recording still works.
