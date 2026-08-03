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

# In HADK

make droidmedia
make screencap_enc_test
