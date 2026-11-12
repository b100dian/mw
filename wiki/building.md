# In SDK
```text
$ sfossdk
```

To build qt5-qpa-hwcomposer-plugin you need to build hybris and have hybris-devel installed on the target (sb2 -t).
You can maintain that with:
```
sb2 -t $VENDOR-$DEVICE-$PORT_ARCH -m sdk-install -R
```
and then (or continue after -R)
```
zypper --plus-repo $ANDROID_ROOT/droid-local-repo/$DEVICE in libhybris-devel libhybris-libEGL-devel
```

> The following 2 packages are going to be REMOVED:
  mesa-llvmpipe-libEGL mesa-llvmpipe-libEGL-devel

Yes, replace the packages.

Sometimes, droidmedia headers change, and droid-media devel also needs to be built and depolyed in the sb2 target (e.g before gst-droid build)

```
rpm/dhd/helpers/build_packages.sh -b hybris/mw/droidmedia -s rpm/droidmedia-devel.spec
```

The devel spec runs `meson rewrite kwargs set project / version`, which writes a `version :` line
into the `project()` call of `droidmedia/meson.build` in the source tree on every devel build.
Before committing, check that `git -C droidmedia diff master -- meson.build` shows only the
`'droidmediascreencapture.h',` line.

# In HADK

From the Android `croot`, the targets `droidmedia/detect_build_targets.sh` gives the RPM build,
and the test tool, which the RPM doesn't ship (`checklist.md` step 12 copies it to the phone):
```
make libdroidmedia minimediaservice minisfservice libminisf screencap_surface_capture_test
```

# On the device

The four packages are a matched set: an old QPA with a new libminisf, or the reverse, disagrees
on the session struct. Copy them with their companions: `droidmedia*` also brings
`droidmedia-devel` and `droidmedia-flashlight`, `gstreamer1.0-droid*` its `-devel` and `-tools`,
all from the same builds. After each rebuild, copy `droidmedia*.rpm`, `gstreamer1.0-droid*.rpm`
and `qt5-qpa*.rpm` from `droid-local-repo/xqcq54` to an empty `/tmp/rpms` on the phone.
Install them with zypper, never `rpm`, then restart the service and lipstick:
```
devel-su
zypper in -f /tmp/rpms/*.rpm
kill $(pgrep minisfservice)    # init restarts it
systemctl-user restart lipstick.service
```
`-f` is needed because the droidmedia RPM is versioned from `git describe` of the submodule, with
no dirty marker: a rebuild of uncommitted changes keeps the version of the last commit, and a
plain `zypper in` keeps the installed package.

To check which droidmedia build the libraries and the running service are, run `sc-build` as
root. It greps a log format string
(the Binder descriptors can't be grepped: they are UTF-16 literals). `tweaks` non-zero is the
build after the gate-5 tweaks, `step2` non-zero is Gate 5 step 2, and both 0 is older. Grepping
`/proc/<pid>/exe` checks the running service, also after its file was replaced.

The device run after each deploy is [`checklist.md`](checklist.md).

# On the host

The capture fit test, from `mw/`. It includes the plugin's `hwcomposer_screencapture.h`;
`tools/screencap-fit-test/cutils/` stubs the one Android header it needs.
```
g++ -std=c++17 -Wall -W -fPIC -I/usr/include/qt -Itools/screencap-fit-test tools/screencap-fit-test/screencap_fit_test.cpp -lQt5Core -o /tmp/screencap_fit_test && /tmp/screencap_fit_test
```
Pass: `PASS: 0 failed` (34 cases).

Syntax checks of the element and the hybris shim, from `mw/`:
```
gcc -fsyntax-only $(pkg-config --cflags gstreamer-1.0 gstreamer-base-1.0) -Idroidmedia gst-droid/gst/droidscreencapsrc/gstdroidscreencapsrc.c
gcc -fsyntax-only -Idroidmedia droidmedia/hybris.c
```
