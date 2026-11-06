# B2 spike (Gate 5.4)

A test tool, not part of any submodule. It checks the assumption B2 depends on: a second
process, which is not lipstick and never opens the HWC, can render with libhybris EGL
(`hwcomposer` platform) into a `VIRTUAL` session's encoder input, and can bind a Wayland
display for its clients (`wiki/gate-5.md` §5.4).

`b2_spike.c`:
1. requires `EGL_PLATFORM=hwcomposer`, and no other `HYBRIS_EGLPLATFORM`;
2. resolves the libminisf screen capture API with `android_dlopen`/`android_dlsym`;
3. creates a recordable RGBA8888 GLES2 context, current with no surface;
4. binds a `wl_display_create()` display with `eglBindWaylandDisplayWL` (no socket, no clients);
5. waits for a session with `target == 1` (`VIRTUAL`) and ignores the others;
6. attaches: `target_acquire_generation` → `target_native_window` → `eglCreateWindowSurface`;
7. runs the script at the session's fps, on attached time: animate 5 s, pause 5 s (no swaps;
   one repaint per `FRAME_REQUESTED`, and one on an attach), animate 5 s;
8. on a session end or change, destroys the surface, releases the target and waits for the next
   session (the script and the frame counter carry on);
9. at exit, lists the mapped libraries whose path contains `composer` or `hwc`, then prints
   `render: PASS|FAIL` and `wayland bind: PASS|FAIL`.

Each frame: colour bars, a black bar at `x = t mod width` (`t` is the script time in ms, so
1 px/ms), and the frame number as 16 blocks (white 1, black 0, most significant bit on the left)
on a grey strip at the top left. Each swap logs `frame N t=… x=… pts=… swap=…ms`, where `pts`
is seconds since the first frame of the attach. An optional argument sets the seconds per phase.

With stock libhybris, `eglBindWaylandDisplayWL` only registers the `android_wlegl` global and
always returns `EGL_TRUE`. A PASS shows that the platform was built with Wayland support and
that the bind works next to an encoder surface; importing client buffers is a later test.

## Build

`[sdk]` In the PlatformSDK:
```sh
sfossdk
sb2 -t $VENDOR-$DEVICE-$PORT_ARCH -m sdk-install -R zypper --plus-repo $ANDROID_ROOT/droid-local-repo/$DEVICE \
    in libhybris-devel libhybris-libEGL-devel libhybris-libGLESv2-devel wayland-devel   # if missing
cd $ANDROID_ROOT/hybris/mw/tools/b2-spike
sb2 -t $VENDOR-$DEVICE-$PORT_ARCH gcc -O2 -Wall -o b2-spike b2_spike.c \
    -lEGL -lGLESv2 -lwayland-server -lhybris-common -lpthread
```
No droidmedia headers: the session struct is copied, and libminisf is resolved at run time.
The binary `b2-spike` stays untracked.

`[host]` Syntax check, from `mw/`:
```sh
gcc -std=gnu99 -Wall -Wextra -fsyntax-only tools/b2-spike/b2_spike.c
```

## Run

The shells and the `sc-*` helpers are those of `wiki/checklist.md` §0. Lipstick runs, with
capture enabled.

`[phone]` Copy the binary:
```sh
. ~/sc/host; scp -q "$HOST:$MW/tools/b2-spike/b2-spike" ~/
```

`[phone]` The recorder, in the background, then the spike within 10 s:
```sh
sc-mp4 virtual 30 target=virtual width=1280 height=720 &
EGL_PLATFORM=hwcomposer ~/b2-spike 2>&1 | tee /tmp/b2.log
wait
ffprobe -v error -show_entries packet=pts_time,flags -of csv=p=0 ~/Videos/sc-virtual.mp4
devel-su journalctl -b --since -2min | grep screencap:
sc-push ~/Videos/sc-virtual.mp4 /tmp/b2.log
```

`[host]` A frame, in `/tmp/sc`:
```sh
ffmpeg -v error -y -ss 2 -i sc-virtual.mp4 -frames:v 1 f.png && ffplay -v error f.png
```

`[phone]` Recorder death and restart. Start the spike with longer phases, kill the recorder
during the first animation, start a new one:
```sh
gst-launch-1.0 -q -e droidscreencapsrc target=virtual width=1280 height=720 ! h264parse ! \
    filesink location=/tmp/b2-a.h264 &
sleep 2; EGL_PLATFORM=hwcomposer ~/b2-spike 10 > /tmp/b2-restart.log 2>&1 &
sleep 5; pkill -9 gst-launch-1.0
sleep 2; sc-raw b2-b 30 target=virtual width=1280 height=720
wait; grep -E 'attached|detached|render:' /tmp/b2-restart.log
```

`[phone]` Optional, `FRAME_REQUESTED` during the pause: `sc-keyunits` with `target=virtual`
sends a `GstForceKeyUnit` every 5 s:
```sh
sed 's/width=1280/target=virtual width=1280/' ~/sc/sc-keyunits > /tmp/kv
python3 /tmp/kv 30 /tmp/b2-fku.mp4 &
EGL_PLATFORM=hwcomposer ~/b2-spike 2>&1 | grep -E 'repaint|pause|animate'; wait
```

`[phone]` Baseline for the maps list: a process that loads libminisf's Android dependencies and
never opens the HWC:
```sh
/usr/libexec/droid-hybris/system/bin/screencap_surface_capture_test 1280 720 4000000 30 10 /tmp/base.h264 &
sleep 3; grep -E 'composer|hwc' /proc/$!/maps | awk '{print $6}' | sort -u; wait
```

## Pass

| Criterion | Evidence |
|---|---|
| A second process renders into the encoder | `ffprobe` decodes `sc-virtual.mp4`; `f.png` shows the bars, the moving bar and the counter. |
| Right content | The counter in a decoded frame matches the spike's `frame N` line with the same `pts`, and the bar is at that line's `x`. |
| Sparse PTS during the pause | About 5 s without packets (or one packet per `FRAME_REQUESTED`), then dense packets again. |
| Lipstick unaffected | The journal has `screencap: ignoring session N: target 1 is not the display` once per generation, and no `attached`; the UI stays smooth. |
| Wayland bind works | `eglBindWaylandDisplayWL: EGL_TRUE` and `wayland bind: PASS`. |
| No HWC in the spike | The spike's list adds nothing to the baseline's but `eglplatform_hwcomposer.so`. A HAL module (`/vendor/lib*/hw/hwcomposer.*.so`), a composer client (`android.hardware.graphics.composer@*`, `vendor.qti.hardware.display.composer*`) or `libhwc2` that the baseline lacks is a FAIL. |
| Recorder death and restart | `detached from session N: ended` (or `ended during the frame`), then `attached to session N+1`, `render: PASS`; the counter in `b2-b.h264` continues from the last frame of `b2-a.h264`. |

A FAIL names its step in the log: `eglInitialize`, the config, `eglCreateWindowSurface`,
`eglMakeCurrent`, a frame's `eglPresentationTimeANDROID` or `eglSwapBuffers`, or the bind. The
fallback is the decision point of `wiki/auto-goal1.md` §5. The result goes in
`wiki/gate-5-exec.md`.
