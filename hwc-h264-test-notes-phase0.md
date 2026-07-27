# HWC H.264 Encoding — Phase-0 On-Device Test Notes

**Date:** 2026-07-26
**Test binary:** `screencap_enc_test` (`droidmedia/tools/screencap_enc_test.cpp`)
**Build:** `mm -j$(nproc) screencap_enc_test` inside Android tree
**Run:** `LD_LIBRARY_PATH=/usr/libexec/droid-hybris/system/lib64 /usr/libexec/droid-hybris/system/bin/screencap_enc_test`

---

## Key Finding: Metadata-Input Mode Rejected on Codec2

| Attempt | Config | Result |
|---------|--------|--------|
| A | `AndroidOpaque` (0x7F000789) + `meta_data=1` (zero-copy, Gralloc handle passthrough) | **FAILED** — `droid_media_codec_create_encoder_raw()` → NULL |
| B | `AndroidOpaque` (0x7F000789) + `meta_data=0` (copy RGBA→encoder input, encoder does RGB→YUV) | **SUCCESS** — encoder created, format negotiated |

The HW encoder advertises `0x7F000789` as a supported color format (confirmed by `droid_media_codec_get_supported_color_formats()`), but the Codec2 `AsyncCodecSource` / `MediaCodecSource` rejects it specifically when `android._input-metadata-buffer-type` is set.

Supported color formats (6 entries):
```
0x7F000789  (AndroidOpaque)
0x7F420888  (unknown, possibly vendor-specific)
0x00000013  (YV12 / YUV420Planar)
0x00000015  (NV12 / YUV420SemiPlanar)
0x00000014  (I420 or vendor)
0x00000027  (vendor-specific)
```

---

## Architecture Implications

The original zero-copy plan (pass `GraphicBuffer` handles through metadata mode) is **not viable** on this device's Codec2 stack. The revised architecture must use:

```
HWC plugin (producer process)           GStreamer process
─────────────────────────────           ─────────────────
GraphicBuffer(RGBA)                     ScreenCaptureMediaSource
    │                                         │
    ├── queueBuffer ──── BufferQueue ──→ acquireBuffer
    │                                         │
    │                                   lock(GraphicBuffer) → memcpy RGBA
    │                                         │
    │                                   encoder input buffer (RGBA)
    │                                   codec does RGB→YUV internally
    │                                         │
    │                                   encoded H.264 output
```

**Changed:** `ScreenCaptureMediaSource::read()` copies real RGBA pixel data from the `GraphicBuffer` into the encoder's input buffer (one `memcpy` of ~8MB per frame at 1080p). The encoder still gets `OMX_COLOR_FormatAndroidOpaque` and handles the RGB→YUV conversion internally.

**Unchanged:** HWC plugin stays zero-copy (GPU blits into dequeued GraphicBuffer), producer remains in UI thread, consumer shared via `sailfish.screencap` Binder service.

---

## Remaining Crash: MediaBuffer Refcount Assertion

The test harness has a known crash after the poll loop:

```
frameworks/av/media/module/foundation/MediaBuffer.cpp:97
CHECK_EQ(mRefCount, 0) failed: 1 vs. 0
```

This is a **test-harness-specific bug** — the `TestMediaSource` creates ad-hoc `MediaBuffer` objects with `new MediaBuffer(size)` instead of using the encoder's allocator pool. The `ScreenCaptureMediaSource` in production code (`screen_capture_mediasource.cpp`) uses the `CaptureInputBuffer` subclass and proper refcount handling, which avoids this issue.

To fix the test harness (for future work):
- Use the encoder's pixel format to determine frame size
- Have the `TestMediaSource` extract the format from the codec's `getFormat()` at `start()` time
- Alternatively, use `setBuffers()` / `requestBuffer()` pattern if the encoder provides it

This is **not blocking** — the production `ScreenCaptureMediaSource` has correct buffer lifecycle management.

---

## Updated DroidMediaCodecEncoderMetaData for non-metadata path

The correct encoder meta for the RGBA-copy path:

```c
DroidMediaCodecEncoderMetaData md = {};
md.parent.type         = "video/avc";
md.parent.width        = width;
md.parent.height       = height;
md.parent.fps          = 30;
md.parent.flags        = DROID_MEDIA_CODEC_HW_ONLY;
md.color_format        = 0x7F000789;   // AndroidOpaque
md.bitrate             = 8000000;      // target bitrate
md.stride              = width;
md.slice_height        = height;
md.max_input_size      = width * height * 4;  // RGBA frame size
md.meta_data           = 0;            // NOT metadata-input mode
```

Key differences from the metadata-mode attempt:
- `meta_data = 0` (was `1`)
- `max_input_size = width * height * 4` added (RGBA frame size)
- No change to `color_format` — still `AndroidOpaque`

---

## Production Changes Needed

1. **`screen_capture_mediasource.cpp`** — update `getFormat()` to report `max-input-size` and stride/slice-height; update `read()` to copy pixel data when metadata mode is unavailable
2. **`screen_capture_mediasource.h`** — add `mMetadataMode` bool + `mGB` (keep `sp<GraphicBuffer>` alive during read)
3. **`screen_capture_encoder.cpp`** — set `meta_data = 0` and `max_input_size`; handle both modes based on what the encoder accepts
4. **Architecture decision** — document that zero-copy metadata mode is device-dependent and not available on this A14/Codec2 target; the RGBA-copy fallback is the default path

---

## On-Device Debug Commands

```sh
# Runtime library path
export LD_LIBRARY_PATH=/usr/libexec/droid-hybris/system/lib64

# Run test (default: 1920x1080x30 → /tmp/screencap_test.h264)
/usr/libexec/droid-hybris/system/bin/screencap_enc_test

# Custom params
/usr/libexec/droid-hybris/system/bin/screencap_enc_test 1280 720 60 /tmp/small.h264

# Check logcat (Android log messages go here, not stderr)
logcat -s ScreencapTest:* DroidMediaCodec:* ScreenCaptureEnc:* &
```

## Next Steps (next session)

1. Fix `ScreenCaptureMediaSource` to be metadata-mode-agnostic (support both paths)
2. Add `max_input_size` and `meta_data=0` to `screen_capture_encoder.cpp`
3. Rebuild `libdroidmedia.so` and `libgstdroid.so`
4. End-to-end test with `QPA_HWC_SCREENCAP=1` and real HWC frames
5. Validate the RGBA-copy path produces playable H.264