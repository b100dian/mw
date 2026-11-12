# qt5-qpa-hwcomposer-plugin `master..hwenc` review: a smaller, additions-only diff

**Date:** 2026-11-12
**Basis:** qt5-qpa-hwcomposer-plugin `hwenc` `ce61cb6` plus its working tree (the libminisf
window-handle edit of [`droidmedia-review.md`](droidmedia-review.md)): 5 source files, +806/−7
against `master` `41e7bda`.
**Status:**
- Part 1 is the plan. Part 2 is its execution: all steps are done in the working tree,
  unstaged. Nothing is committed.
- Host checks pass (§E.3). The PlatformSDK build and the device run have not run yet (§E.4).

---

# Part 1: Plan

## Context

Goal: fewer things for the next reviewer to check. Only the plugin changes; droidmedia,
gst-droid and `tools/` stay as they are.

**Findings in short:** no crash or leak found. One robustness nit (1), one misleading
log/dead check (2), and the rest is diff shape and comments. No device behaviour changes,
so `checklist.md` needs no new step.

## 1. Robustness

1. **`swap()` gates capture on the `eglSwapBuffers()` result.** `captureFrame()` already does
   nothing unless `present()` handed over a buffer in this swap, so the gate only leaves
   `m_buffer` and the fence copy held after a failed swap. Call it unconditionally: master's
   `eglSwapBuffers(display, surface);` line comes back unchanged.
2. **`checkSession()` rejects `fps <= 0` with a message about sizes.** The service already
   refuses such a session (`screen_capture_service.cpp`) and the plugin only logs fps. Drop
   the fps test; the size test and its log stay (documented in `README.md`).

## 2. Upstream files: additions only

`hwcomposer_backend_v20.cpp` modified 7 master lines and `hwcomposer.pro` 2. After this, both
are pure additions.

3. **`HWC2Window`: setter in place of the constructor parameter.** Constructor declaration,
   definition and the `new HWC2Window(...)` call go back to master. Add
   `HwComposerScreenCapture *m_screenCapture = nullptr;` and a public `setScreenCapture()`.
   `createWindow()` creates the capture after the window and calls
   `hwc_win->setScreenCapture(m_screenCapture)`.
   Trade-off: constructor injection is a little tidier, but costs three edited upstream hunks.
4. **`HwComposerBackend_v20::m_screenCapture = nullptr`** in the header; the
   `, m_screenCapture(NULL)` hunk in the constructor goes.
5. **`swap()`** (with fix 1): `eglSwapBuffers()` as on master, then
   `if (m_screenCapture) m_screenCapture->captureFrame();` under one comment line.
6. **`hwcomposer.pro`**: master's two lines restored, plus
   `SOURCES += hwcomposer_screencapture.cpp` and `HEADERS += hwcomposer_screencapture.h`
   in the same `hwcomposer2` block.

## 3. `hwcomposer_screencapture.{h,cpp}`: less state

7. **One limit.** `FenceTimeoutMs` and `MaxSwapNs` are both 250 ms under one comment:
   a single `MaxWaitMs = 250`.
8. **`submit()`**: one clock read serves as presentation time and swap start.
9. **`ScopedFd` removed.** `captureFrame()` takes `m_buffer` (sets it null) and waits on
   `m_fenceFd` in place; `bufferPresented()` and the destructor already close it. One owner
   for the descriptor, no helper type.
10. **`m_width` removed**: only the attach log read it; the log uses `info.width`.
    `m_height` stays (viewport y for GL).
11. **Line length**: wrap the two lines over 100 columns.

## 4. Comments

12. `TexCoords`: "They all flip-y." becomes the reason: row 0 of a display buffer is the top
    of the screen, GL's t = 0 is the bottom.
13. `MaxWaitMs`: says it bounds both the fence wait and the encoder swap.
14. `sessionCallback()`: says why it queries on a frame request (a request for a session
    another renderer fills must not repaint lipstick).
15. `m_buffer`/`m_fenceFd` in the header: valid from `bufferPresented()` to the next one;
    `captureFrame()` consumes the buffer.

## 5. Reviewed, left as they are

- **Own `android_dlopen("libminisf.so")`**: the HWC2 backend is created with
  `libminisf = NULL`, and without `QPA_HWC_SCREENCAP` the plugin must not load it. The base
  class handle can't be reused.
- **Two calls (`bufferPresented()` inside the swap, `captureFrame()` after)**: the fence must
  be copied before `set_client_target()` takes it, and EGL can't be re-entered in `present()`.
- **`m_sources` keyed by `buffer->handle`**: the window keeps its 3 buffers for its lifetime
  (reallocation only on a format, usage or count change), and the cache is per session.
- **Session query in the Binder callback**: reads libminisf's copy under a mutex, no Binder
  call while the service is connected.
- **Fence timeout gives up the session** rather than skipping a frame: a 250 ms GPU frame is
  pathological either way, and one policy for all failures is simpler.
- **`captureFit()` inline in the header**: the host fit test includes it.
- **`uint64_t generation`** against the service's `int64_t`: same layout, matches libminisf's
  C signature.
- `ScopedCaptureContext`, the shader helpers, `event()` with `QQuickWindow::update()`
  (gate-5-tweaks deviation 1): correct and already minimal.

---

# Part 2: Execution (2026-11-12)

## E.1 What changed

qt5-qpa-hwcomposer-plugin (working tree, unstaged): `hwcomposer/hwcomposer.pro`,
`hwcomposer_backend_v20.{h,cpp}`, `hwcomposer_screencapture.{h,cpp}`.

`master..` working tree, sources: 5 files, +792/−0 (was +806/−7). `hwcomposer.pro` +2,
`hwcomposer_backend_v20.cpp` +16, `hwcomposer_backend_v20.h` +2.

mw: this file and `init.md`.

## E.2 Deviations from the plan

- `hwcomposer_backend_v20.cpp` is +16/−0, not the estimated +17.
- The rejection log keeps `@fps` in its `%dx%d@%d` (only the test went).
- **Syntax check:** `clang++` 21 can't parse Qt 5.6.3's headers (`qtypetraits.h`, `QFlags`
  operators), and the host's Qt 5.15 lacks Sailfish's private headers (`qsystrace_p.h`). The
  check uses host `g++ -std=c++11` against the `sony-xqcq54-aarch64` SDK target's Qt, droid
  and hybris headers instead (§E.3).
- **Not in the plan, not changed:** the plugin's build output is now **staged** (`A` in the
  index): `hwcomposer/.qmake.cache`, `config.log`, `config.tests/hwcomposer2/hwcomposer2`,
  `lib/cmake/…/Qt5Gui_QEglFShwcIntegrationPlugin.cmake`, `mkspecs/modules{,-inst}/…pri`,
  `plugins/platforms/libhwcomposer.so` (3.8 MB). A plain `git commit` would take it. The
  window-handle edit of `hwcomposer_screencapture.{h,cpp}` is staged as well; this review's
  edits on top are not. `documentation.list` is untracked.

## E.3 Host checks

From `mw/`:
- `git -C qt5-qpa-hwcomposer-plugin diff --stat master` on the 5 sources: +792/−0;
  `git diff master -- hwcomposer/hwcomposer_backend_v20.{cpp,h} hwcomposer/hwcomposer.pro |
  grep '^-[^-]'` prints nothing. (Without a path filter the stat also lists the staged build
  output, §E.2.)
- The fit test of [`building.md`](building.md): `PASS: 0 failed`.
- Syntax, both `.cpp` files: 0 errors, 0 warnings with
  ```sh
  T=/home/srv/mer/targets/sony-xqcq54-aarch64; Q=$T/usr/include/qt5
  g++ -std=c++11 -fsyntax-only -Wall -Wextra -Wno-deprecated-copy -Wno-attributes -fPIC \
    -DHWC_PLUGIN_HAVE_HWCOMPOSER1_API -DHWC_PLUGIN_HAVE_HWCOMPOSER2_API \
    -DMESA_EGL_NO_X11_HEADERS -DQT_CORE_LIB -DQT_GUI_LIB \
    -Iqt5-qpa-hwcomposer-plugin/hwcomposer -I$T/usr/include/droid-devel/droid-headers \
    -I$T/usr/include/hybris/hwcomposerwindow -I$T/usr/include/hybris/eglplatformcommon \
    -I$T/usr/include/hybris/platformcommon -I$T/usr/include/hybris/hwc2 -I$T/usr/include \
    -I$Q -I$Q/QtCore -I$Q/QtGui -I$Q/QtCore/5.6.3 -I$Q/QtCore/5.6.3/QtCore \
    -I$Q/QtGui/5.6.3 -I$Q/QtGui/5.6.3/QtGui -I$Q/QtPlatformSupport/5.6.3 \
    -I$Q/QtPlatformSupport qt5-qpa-hwcomposer-plugin/hwcomposer/hwcomposer_screencapture.cpp
  ```
  (and the same for `hwcomposer_backend_v20.cpp`). The two suppressed warnings come from
  Qt 5.6 (`-Wdeprecated-copy`) and the droid headers' `annotate` attribute.
- `grep -rn "FenceTimeoutMs\|MaxSwapNs\|ScopedFd" hwcomposer/`: nothing; `m_width` only in
  upstream `hwcomposer_screeninfo.cpp`.
- No line over 100 columns in `hwcomposer_screencapture.{h,cpp}`.

## E.4 Build and device run

Not run yet. Unstage the build output first (it stays on disk), then build in `sfossdk`:
```sh
git -C qt5-qpa-hwcomposer-plugin restore --staged hwcomposer/.qmake.cache hwcomposer/config.log \
  hwcomposer/config.tests hwcomposer/lib hwcomposer/mkspecs hwcomposer/plugins
rpm/dhd/helpers/build_packages.sh -b hybris/mw/qt5-qpa-hwcomposer-plugin
```
Then [`checklist.md`](checklist.md) steps 1, 3, 4 (first IDR on an idle screen), 5
(`target=virtual` ignored once), 7, 14 and 15 (lipstick without capture). To clear the build
output afterwards: `git -C qt5-qpa-hwcomposer-plugin clean -nd` to list, `-fd` to delete.
