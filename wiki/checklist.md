# Device test checklist

The device run after every deploy of the `hwenc` set.

**Build under test:** the gate-5-tweaks build (RPMs of 2026-11-03), run on 2026-11-04. Its results go in `gate-5-tweaks-exec.md` §6.

**Keeping it current.**
- A change that adds or alters device behaviour updates its step here, in the same change, and drops the steps that no longer apply.
- Results go in the exec log of the build under test, by step number.
- This file holds only the current procedure: no results, no history.

**Conventions.**
- Each command block is tagged:
  - `[host]`: the build computer, in `/tmp/sc`;
  - `[phone]`: a `defaultuser` shell on the phone;
  - `[root]`: a `devel-su` shell on the phone.
- Every copy starts on the phone, with `ssh` and `scp` to the host: the host runs sshd, the phone doesn't need to.
- Keep one shell of each open. Each step is a short instruction, its commands, and `Pass:` criteria.
- The phone helpers are scripts in `~defaultuser/sc/`, all named `sc-…`, so `sc-` and Tab lists them. Each new phone or root shell puts them on the path with `export PATH=/home/defaultuser/sc:$PATH`.
- The phone's shell is busybox ash, so the phone blocks and helpers are POSIX sh.
- Every block can be run again: the setup blocks overwrite what they wrote, and steps 1 and 3 update the phone after a rebuild.
- Lipstick logs to the system journal and droidmedia to logcat. Both need root: `devel-su journalctl`, `devel-su logcat` from the phone shell, without `devel-su` from the root shell.
- Recordings run as `defaultuser`, and `ffprobe` checks them on the phone. Only what needs looking at (a picture, `ffplay`) goes to the host, with `sc-push`.

## 0. Once

`[root]` The drop-in must enable capture:
```sh
cat /etc/systemd/user/lipstick.service.d/51-screencap.conf    # Environment=QPA_HWC_SCREENCAP=1
```
On the phone, set Settings → Display → Sleep after to more than 1 minute.

`[host]` The host needs sshd, ffmpeg and ffplay. Keep this shell open for the whole run:
```sh
MW=${MW:-$PWD}                                 # this repository: the first time, run from its top directory
mkdir -p /tmp/sc && cd /tmp/sc
which ffmpeg ffplay
```

`[phone]` The helpers. Set `HOST` and `MW` to the host's login and repository. Run the block again after changing a helper here. `sc` alone lists them:
```sh
mkdir -p ~/sc && rm -f ~/sc/sc-*
cat > ~/sc/host << 'EOF'
HOST=vlad@192.168.2.14                 # the build computer
MW=/mnt/datas/nagara/hadk/hybris/mw    # its copy of this repository
EOF
cat > ~/sc/sc << 'EOF'
#!/bin/sh
# The sc-* helpers of wiki/checklist.md; each sc-NAME is a link to this script.
#   sc-push FILE...            copy FILEs to the host's /tmp/sc
#   sc-raw NAME SECS [PROPS]   raw H.264 to /tmp/NAME.h264
#   sc-mp4 NAME SECS [PROPS]   MP4 to ~/Videos/sc-NAME.mp4
#   sc-build [FILE...]         the droidmedia build of each FILE; by default the libraries and
#                              the running service (needs root)

. "${0%/*}/host"
# SECS seconds of gst-launch-1.0 -e; it turns the SIGINT into EOS.
run() { s=$1; shift; gst-launch-1.0 -q -e "$@" & p=$!; sleep "$s"; kill -INT $p; wait $p; }

case ${0##*/} in
sc-push)
  scp -q "$@" "$HOST:/tmp/sc/" ;;
sc-raw)
  n=$1 s=$2; shift 2
  run "$s" droidscreencapsrc "$@" ! h264parse ! filesink location=/tmp/$n.h264 ;;
sc-mp4)
  n=$1 s=$2; shift 2
  run "$s" droidscreencapsrc "$@" ! h264parse config-interval=-1 ! \
    video/x-h264,stream-format=avc,alignment=au ! qtmux ! filesink location=$HOME/Videos/sc-$n.mp4 ;;
sc-build)
  l=/usr/libexec/droid-hybris/system/lib64
  [ $# -gt 0 ] || set -- $l/libminisf.so $l/libdroidmedia.so /proc/$(pgrep minisfservice)/exe
  for f; do echo "$f: tweaks $(grep -c 'content %d,%d-%d,%d' "$f"), step2 $(grep -c 'content %d,%d %dx%d' "$f")"; done ;;
*)
  sed -n 's/^#   //p' "$0"; exit 2 ;;
esac
EOF
cat > ~/sc/sc-keyunits << 'EOF'
#!/usr/bin/env python3
# sc-keyunits SECS OUTPUT: 1280x720@30 with a GstForceKeyUnit every 5 s, then EOS. An OUTPUT
# ending in .mp4 is muxed with qtmux. The element logs at level 5 to OUTPUT's name with .log.
import os, sys
secs, out = int(sys.argv[1]), sys.argv[2]
os.environ.update(GST_DEBUG='droidscreencapsrc:5', GST_DEBUG_NO_COLOR='1')
os.dup2(os.open(os.path.splitext(out)[0] + '.log', os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o644), 2)
import gi
gi.require_version('Gst', '1.0'); gi.require_version('GstVideo', '1.0')
from gi.repository import GLib, Gst, GstVideo
mux = ' ! video/x-h264,stream-format=avc,alignment=au ! qtmux' if out.endswith('.mp4') else ''
Gst.init(None)
p = Gst.parse_launch('droidscreencapsrc width=1280 height=720 fps=30 ! h264parse name=parse'
                     + mux + ' ! filesink location=' + out)
pad = p.get_by_name('parse').get_static_pad('sink')
GLib.timeout_add_seconds(5, lambda: pad.push_event(
    GstVideo.video_event_new_upstream_force_key_unit(Gst.CLOCK_TIME_NONE, True, 0)) or True)
GLib.timeout_add_seconds(secs, lambda: p.send_event(Gst.Event.new_eos()) and False)
loop = GLib.MainLoop(); bus = p.get_bus(); bus.add_signal_watch()
bus.connect('message::eos', lambda *a: loop.quit())
bus.connect('message::error', lambda b, m: (print(m.parse_error()), loop.quit()))
p.set_state(Gst.State.PLAYING); loop.run(); p.set_state(Gst.State.NULL)
EOF
chmod +x ~/sc/sc ~/sc/sc-keyunits
for c in push raw mp4 build; do ln -sf sc ~/sc/sc-$c; done
export PATH=/home/defaultuser/sc:$PATH
which ffprobe scp
. ~/sc/host; scp -q "$HOST:$MW/scripts/sharing-tcp.sh" ~/
```
Optional, so that the copies don't ask for the host's password:
```sh
[ -f ~/.ssh/id_ed25519 ] || ssh-keygen -q -t ed25519 -N '' -f ~/.ssh/id_ed25519
k=$(cat ~/.ssh/id_ed25519.pub); ssh "$HOST" "grep -qxF '$k' ~/.ssh/authorized_keys 2>/dev/null || echo '$k' >> ~/.ssh/authorized_keys"
```

## 1. Copy and install

Copy `droidmedia*.rpm`, `gstreamer1.0-droid*.rpm` and `qt5-qpa*.rpm` from the host's `droid-local-repo/xqcq54` to an empty `/tmp/rpms` on the phone: 7 packages, as `droidmedia*` brings `-devel` and `-flashlight`, and `gstreamer1.0-droid*` brings `-devel` and `-tools`, all from the same builds.

`[root]` Install with zypper, never `rpm`. `-f` reinstalls a package whose version didn't change: the droidmedia version comes from `git describe` only, so an uncommitted rebuild keeps it:
```sh
export PATH=/home/defaultuser/sc:$PATH
sc-build                          # the installed build: tweaks 0, step2 non-zero
zypper in -f /tmp/rpms/*.rpm
sc-build                          # libraries: tweaks non-zero, step2 0; the service is still the old one
```
Don't restart `minisfservice` or lipstick yet.

Pass: zypper installs the 7 packages, and both libraries show the new build.

## 2. Old service

Run this step only when the build changes the Binder interface and the old `minisfservice` still runs. Today it does: the descriptors lose their `/2`.

`[root]` Lipstick gets the new plugin, the service stays old:
```sh
systemctl-user restart lipstick.service; sleep 10
logcat -c
```
`[phone]`
```sh
gst-launch-1.0 -e droidscreencapsrc width=1280 height=720 ! fakesink    # then touch the screen once
devel-su logcat -d | grep -E "enforceInterface|Cannot subscribe|registerProducer failed|Cannot register the input Surface"
devel-su journalctl -b --since -2min | grep screencap:
```
Pass:
- gst-launch stops at once with `Failed to start screen capture`;
- logcat has:
  - `enforceInterface() expected 'sailfish.IScreenCaptureService/2'`, from the service;
  - `registerProducer failed: -1` and `Cannot register the input Surface`, from the recorder;
  - `Cannot subscribe to sailfish.screencap: -1`, from lipstick, at most every 250 ms while it renders;
- the journal has `screencap: enabled` and no `attached`.

## 3. Restart and inspect

`[root]` Lipstick restarts after the service, so that it subscribes at its first frame:
```sh
kill $(pgrep minisfservice); sleep 2          # init restarts it
sc-build                                      # all three: tweaks non-zero, step2 0
systemctl-user restart lipstick.service; sleep 10
journalctl -b --since -1min | grep screencap:
```
`[phone]`
```sh
gst-inspect-1.0 droidscreencapsrc
```
Pass:
- `screencap: enabled for a 1080x2520 display, landscape rotation 270`;
- `Rank` is `none (0)`;
- the properties are `width`, `height`, `target-bitrate`, `fps`, `profile`, `level`, `target` and `content-rect`, the last a `GstValueArray` of `gint`.

From now until step 4 has finished, don't touch the screen.

## 4. First IDR and key units on an idle screen

`[phone]` 32 s, with a key-unit request every 5 s:
```sh
sc-keyunits 32 /tmp/fku.h264
grep -E "requested a key unit|pushing" /tmp/fku.log
ffprobe -v quiet -show_entries frame=pict_type,pkt_size -of csv=p=0 /tmp/fku.h264
sc-push /tmp/fku.h264
```
`[host]`
```sh
ffmpeg -v error -y -i fku.h264 -frames:v 1 fku.png
```
Pass:
- 7 frames, all `I`: the first, and one for each request at 5..30 s. A status-bar minute change adds a frame;
- each `requested a key unit` line is followed by exactly one `pushing` line, whose buffer flags lack `0x2000` (delta unit). Record the time between the two (request to IDR);
- `fku.png` shows the screen as it was.

## 5. `target=virtual`

`[phone]` Touch the screen during the 10 s:
```sh
sc-raw virt 10 width=1280 height=720 target=virtual
ls -l /tmp/virt.h264
devel-su journalctl -b --since -1min | grep screencap:
```
Pass:
- `/tmp/virt.h264` is 0 bytes;
- exactly one `screencap: ignoring session N: target 1 is not the display`, and no `attached`.

## 6. Display off

`[phone]` 60 s. Blank the screen with the power key at about 15 s and wake it at about 40 s:
```sh
sc-keyunits 60 /tmp/off.mp4
grep "requested a key unit" /tmp/off.log
devel-su journalctl -b --since -2min | grep -iE "screencap:|hwc|composer"
ffprobe -v quiet -show_entries frame=pts_time,pict_type -of csv=p=0 /tmp/off.mp4
```
Pass:
- an I frame about every 5 s while the screen is on, and none while it is off, although the requests still log;
- frames resume at wake;
- no `screencap:` warnings or HWC errors in the journal.

## 7. Portrait and landscape, raw and MP4, while using the phone

`[phone]` In each 20 s run, scroll Settings, leave the screen still for about 3 s, then type in Terminal:
```sh
sc-raw port  20 width=1080 height=2520
sc-mp4 port  20 width=1080 height=2520
sc-raw land  20 width=2520 height=1080      # phone turned to landscape, camera key up
sc-mp4 land  20 width=2520 height=1080
sc-raw port2 20 width=1080 height=2520      # back to portrait
devel-su journalctl -b --since -3min | grep -E "screencap: (attached|session)"
```
Pass:
- one `attached` line per run:
  - portrait: `rotation 0, viewport 0,0 1080x2520`;
  - landscape: `rotation 270, viewport 0,0 2520x1080`;
- each run's `session N ended, detaching` comes before the next attach.

## 8. Inspect the files

`[phone]` Listing the frames decodes them, so a decode error prints:
```sh
for f in /tmp/port.h264 /tmp/land.h264 /tmp/port2.h264 ~/Videos/sc-port.mp4 ~/Videos/sc-land.mp4; do
  echo "$f: $(ffprobe -v error -show_entries stream=profile,width,height -of csv=p=0 $f)," \
    "$(ffprobe -v error -show_entries frame=pts_time -of csv=p=0 $f | wc -l) frames"
done
for f in ~/Videos/sc-port.mp4 ~/Videos/sc-land.mp4; do
  echo "$f: $(ffprobe -v error -show_entries format=duration -of csv=p=0 $f) s"
  ffprobe -v error -show_entries frame=pts_time -of csv=p=0 $f | awk 'NR > 1 && $1 - t > 1 { print "  gap " t " -> " $1 } { t = $1 }'
done
```
Pass:
- `High,1080,2520` for portrait and `High,2520,1080` for landscape;
- no other lines: every file decodes without errors;
- each MP4 lasts about 20 s, less any still time at its end: an MP4 ends one frame after the last screen change;
- each MP4 has a gap of about 3 s, where the screen was still.

## 9. Play on the device

Open `sc-port` and `sc-land` in Gallery.

Pass: both play, upright and unstretched, and show the scrolling, the pause and the typing.

## 10. Letterbox, content rect, levels

Host: the fit test passes (`building.md`, "On the host").

`[phone]` Settings on screen, in portrait unless noted, and no lipstick restart since step 3. Scroll Settings during each run:
```sh
sc-raw s800  10 width=800  height=480
sc-raw s1280 20 width=1280 height=720       # turn the phone to landscape early in this run, then back
sc-raw s1920 10 width=1920 height=1080
sc-raw s720p 10 width=720  height=1280
sc-raw rect  10 width=1280 height=720 content-rect="<0, 0, 1280, 600>"
sc-raw l31   10 width=1280 height=720 fps=30 profile=constrained-baseline level=31
sc-raw l32   10 width=1280 height=720 fps=60 profile=constrained-baseline level=32
devel-su journalctl -b --since -4min | grep -E "screencap: (attached|session)"
for n in s800 s1280 s1920 s720p rect l31 l32; do
  echo "$n: $(ffprobe -v error -show_entries stream=profile,width,height,level -of csv=p=0 /tmp/$n.h264)"
done
sc-push /tmp/s1280.h264 /tmp/rect.h264
```
`[host]`
```sh
for n in s1280 rect; do ffmpeg -v error -y -i $n.h264 -frames:v 1 $n.png; done
ffplay -v error s1280.h264
```
Pass:
- **Journal.** One `attached` line per run, with these values, and each session's `session N ended, detaching` before the next attach:

  | Run | Rotation, viewport |
  |---|---|
  | s800 | 270, `0,69 800x342` |
  | s1280 | 270, `0,86 1280x548` |
  | s1920 | 270, `0,129 1920x822` |
  | s720p | 0, `86,0 548x1280` |
  | rect | 270, `0,26 1280x548` |
  | l31, l32 | 270, `0,86 1280x548` |

- **Levels.** `Constrained Baseline,1280,720,31` and `Constrained Baseline,1280,720,32`. The other files have their own size.
- **Picture:**
  - `s1280.png`: upright, with 86 px black bars at the top and bottom. A round element (a switch or an avatar) measures round;
  - `rect.png`: 26 px black at the top and 146 px at the bottom.
- **Rotation.** In `ffplay`, s1280 stays upright and letterboxed while lipstick turns.
- **Quality.** Text at 1280x720 is legible while scrolling. At 800x480 it aliases: a known limit.

## 11. Stream to the computer

Touch the screen while watching: an idle screen sends no frames.

**(a) Full size, with the repository scripts.** `[phone]`
```sh
sh ~/sharing-tcp.sh
```
`[host]`
```sh
$MW/scripts/receiving-tcp.sh                # PHONE_IP=... if the phone isn't 192.168.2.15
```

**(b) Head-unit shape.** `[phone]`
```sh
gst-launch-1.0 -e droidscreencapsrc width=1280 height=720 fps=30 target-bitrate=4000000 profile=constrained-baseline level=31 ! tcpserversink host=0.0.0.0 port=5000 sync=false
```
`[host]` The same receiver:
```sh
$MW/scripts/receiving-tcp.sh
```
Pass, for both:
- a live picture that follows the touches: full screen in (a), letterboxed in (b);
- ffplay quit and started again while the sender runs shows a picture within about 1 s (the next IDR);
- with raw Annex B, a still screen may show the frame before the last change. That is a known limit: note it, don't fail it.

## 12. droidmedia test tool

The droidmedia RPM doesn't ship the tool: copy it from the HADK build after each install of step 1.

`[phone]`:
```sh
. ~/sc/host; scp -q "$HOST:$MW/../../out/target/product/pdx224/system/bin/screencap_surface_capture_test" /tmp/
```
`[root]`:
```sh
install -m 755 /tmp/screencap_surface_capture_test /usr/libexec/droid-hybris/system/bin/
```

`[phone]` Touch the screen during each 5 s run:
```sh
T=/usr/libexec/droid-hybris/system/bin/screencap_surface_capture_test
$T 1080 2520 8000000 30 5 /tmp/t.h264; echo "exit $?"
$T 1280 720 4000000 30 5 /tmp/t720.h264; echo "exit $?"
devel-su journalctl -b --since -1min | grep -E "screencap: (attached|session)"
for f in /tmp/t.h264 /tmp/t720.h264; do echo "$f: $(ffprobe -v error -show_entries stream=width,height -of csv=p=0 $f)"; done
```
Pass:
- each run prints `graceful finish: reached codec EOS`, then `N frames, … eos callback 1, error 0`, then `exit 0`. With 0 frames the tool exits 1;
- `1080,2520` and `1280,720`;
- the 1280x720 session attached with `rotation 270, viewport 0,86 1280x548`.

## 13. App in a nested compositor (qt-runner)

Optional until the B2 spike (Gate 5.4). If qt-runner or the app doesn't come up, record what it printed and leave the step to the spike.

`[root]` Prerequisites:
```sh
rpm -q qt-runner qt5-qtdeclarative-qmlscene
zypper in qt5-qtdeclarative-qmlscene           # if missing
```
If qt-runner is missing:
- build it in the PlatformSDK with `rpm/dhd/helpers/build_packages.sh -b hybris/mw/qt-runner`;
- copy `qt-runner-0*.rpm` to the phone and install it with `zypper in -f`.

`[phone]` A tap moves a red circle and counts. Tap 5 times, in different places, during the recording:
```sh
cat > /tmp/touch.qml << 'EOF'
import QtQuick 2.0
Rectangle {
    width: 540; height: 1200; color: "white"
    property int taps: 0
    Text { text: "taps: " + parent.taps; font.pixelSize: 64 }
    Rectangle { id: dot; width: 120; height: 120; radius: 60; color: "red" }
    MouseArea {
        anchors.fill: parent
        onClicked: { parent.taps++; dot.x = mouse.x - 60; dot.y = mouse.y - 60 }
    }
}
EOF
eval "$(systemctl --user show-environment | grep -E '^(WAYLAND_DISPLAY|QT_QPA_PLATFORM|XDG_RUNTIME_DIR|DBUS_SESSION_BUS_ADDRESS)=' | sed 's/^/export /')"
qt-runner $(command -v qmlscene) /tmp/touch.qml & Q=$!
sleep 5; sc-raw nested 20 width=1280 height=720
devel-su journalctl -b --since -1min | grep screencap:
sc-push /tmp/nested.h264
```
Then stream it as in 11 (b), tapping again, and stop the app with `kill $Q`.

`[host]`
```sh
ffplay -v error nested.h264
```
Pass:
- the app shows inside qt-runner, and each tap moves the circle and raises the count;
- the recording and the stream show every tap, letterboxed;
- no `screencap:` warnings.

## 14. Recorder killed

`[phone]` Touch the screen during both recordings:
```sh
gst-launch-1.0 -q -e droidscreencapsrc width=1080 height=2520 ! h264parse ! filesink location=/tmp/killed.h264 &
sleep 5; pkill -9 -f droidscreencapsrc; wait $!
sc-raw after 10 width=1080 height=2520
ls -l /tmp/after.h264
devel-su logcat -d -s ScreenCaptureService | tail -n 5
devel-su journalctl -b --since -1min | grep screencap:
```
Pass:
- logcat has `Recorder died, session N ended`;
- the journal has `screencap: session N ended, detaching` for it, then one `attached` and a clean detach for `after`;
- `/tmp/after.h264` is not empty.

## 15. Lipstick without capture

`[root]` Without the drop-in. `t` keeps the earlier steps' lines out of the journal check:
```sh
D=/etc/systemd/user/lipstick.service.d
mv $D/51-screencap.conf /root/
t=$(date '+%F %T'); systemctl-user daemon-reload; systemctl-user restart lipstick.service; sleep 10
journalctl -b --since "$t" | grep screencap:
```
Use the phone for a minute: unlock, open and close apps, scroll. Then restore the drop-in:
```sh
mv /root/51-screencap.conf $D/
t=$(date '+%F %T'); systemctl-user daemon-reload; systemctl-user restart lipstick.service; sleep 10
journalctl -b --since "$t" | grep screencap:
```
`[phone]` Touch the screen during the run:
```sh
sc-raw back 10 width=1080 height=2520
devel-su journalctl -b --since -1min | grep -E "screencap: (attached|session)"
```
Pass:
- no `screencap:` line without the drop-in, and the phone works normally;
- `screencap: enabled` after the restore, and `back` attaches and detaches.

## 16. Camera recording

Record 5 s of video in the Camera app.

Pass: it plays in Gallery.

## 17. B2 spike: a second process renders a `VIRTUAL` session

Gate 5.4. Build `b2-spike` in the PlatformSDK first (`tools/b2-spike/README.md`). The spike animates for 5 s, pauses for 5 s and animates for 5 s, counting only the time it is attached.

`[phone]` Don't touch the screen:
```sh
. ~/sc/host; scp -q "$HOST:$MW/tools/b2-spike/b2-spike" ~/
sc-mp4 virtual 30 target=virtual width=1280 height=720 &
EGL_PLATFORM=hwcomposer ~/b2-spike 2>&1 | tee /tmp/b2.log
wait
ffprobe -v error -show_entries packet=pts_time -of csv=p=0 ~/Videos/sc-virtual.mp4
devel-su journalctl -b --since -1min | grep screencap:
sc-push ~/Videos/sc-virtual.mp4 /tmp/b2.log
```
`[host]`
```sh
ffplay -v error sc-virtual.mp4
```
Pass:
- the spike prints `eglBindWaylandDisplayWL: EGL_TRUE`, `attached to session N: 1280x720 …`, `pause`, `animate`, then `render: PASS` and `wayland bind: PASS`;
- the packet times are dense, then show a gap of about 5 s, then are dense again;
- exactly one `screencap: ignoring session N: target 1 is not the display`, and no `attached`;
- the video shows colour bars, a moving black bar and the frame counter at the top left, frozen for about 5 s in the middle.

Record the spike's `mapped composer/hwc libraries` list. The README compares it with a baseline.

## Not covered yet

- RTP (`scripts/sharing-rtp.sh`).
- Slow downstream and keyframe recovery (Gate 4.4).
- Pause and resume: PLAYING → PAUSED → PLAYING gives a stream that decodes without a break (host-tested with a stub, `gst-droid-simplify.md` §E.4).
- Whether the 100 ms detach grace keeps the last frame of a recording.
- Gate 5.3, the head-unit path.
- Gate 5.4's other checks (the HWC baseline, recorder restart, `FRAME_REQUESTED` during the pause): `tools/b2-spike/README.md`.

## Results

Each step's result, with the log lines that show it, goes in the exec log of the build under test, by step number.
