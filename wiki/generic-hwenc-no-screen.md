# Hardware encoding without the screen: discussion

**Date:** 2026-11-09
**Status:** Discussion only. Nothing is implemented; the work comes **after the `master..hwenc`
review** and does not grow that diff.
**Basis:** `../droidmedia/droidmediacodec.cpp`, `../droidmedia/AsyncCodecSource.cpp`,
`../gecko-camera/plugins/droid/droid-codec.cpp`, `../gst-droid/gst/droidcodec/gstdroidvenc.c`

Question: can the `hwenc` work encode generic frames (bitmaps, textures, decoded video), not
only the screen? Short answer: for CPU frames the Surface path is the wrong tool and upstream
`droidmedia` already has what is needed; the gap is in `gst-droid`. For GPU textures the
`hwenc` Surface encoder is the right tool, after a split from the screencap service.

## 1. What `DroidMediaScreenCapture` is tied to

The encoder core in `droidmediascreencapture.cpp` is a plain hardware AVC `MediaCodec` with an
input Surface. The screen-specific parts are:
- `start()` requires the `sailfish.screencap` service and hands the Surface producer to it over
  Binder; there is no in-process access to the Surface;
- the service holds one session;
- settings are fixed: H.264, 1 s keyframe interval, SPS/PPS prepended to IDR frames;
- `request_sync_frame()` also asks the compositor for a repaint.

So the current object cannot be reused for other sources as is. For GPU textures, an in-process
encoder that owns the Surface, with the Binder publication as a separate step, would be the
refactor. For CPU frames none of this is needed, see below.

## 2. Upstream `droidmedia` already encodes raw CPU frames

`DroidMediaCodecEncoderMetaData` (`droidmediacodec.h`) has `color_format`, `stride`,
`slice_height` and a `meta_data` flag. With `meta_data = false`:
- on Android ≥ 7 the builder does not set `android._input-metadata-buffer-type`
  (`droidmediacodec.cpp:479-485`), so MediaCodec runs in byte-buffer input mode;
- `AsyncCodecSource::queueInputBuffer()` (`AsyncCodecSource.cpp:348-392`) `memcpy`s each queued
  `MediaBuffer` into the codec's input buffer and queues it with its timestamp;
- `droid_media_codec_queue()` (`droidmediacodec.cpp:956`) is the entry point: contiguous YUV
  data, a timestamp, an unref callback;
- `droid_media_codec_get_supported_color_formats()` lists the encoder's input formats, in the
  codec's order of preference.

One copy per frame, no Surface, no gralloc, no GL. All of this is in the glibc-side wrapper
(`hybris.c:237-253`), so any Sailfish process can use it.

### An existing user: `gecko-camera`

`gecko-camera/plugins/droid/droid-codec.cpp:310-469` (`DroidVideoEncoder`, the WebRTC encoder
of the Sailfish browser) runs exactly this path: `meta_data = false`, `DROID_MEDIA_CODEC_HW_ONLY`,
CBR, `prepend_header_to_sync_frames`, colour format = first of `YUV420Planar` /
`YUV420SemiPlanar` the encoder lists. `encode()` packs an I420 frame into one `malloc` buffer,
interleaves chroma if the codec wants NV12, and calls `droid_media_codec_queue()`.

Despite the project name, the encoder has no camera in it. Its input is `YCbCrFrame`
(`geckocamera.h:55-65`): three CPU plane pointers, strides, size, timestamp. In the browser it
receives whatever WebRTC produces, camera, screen share or canvas. It ships on Sailfish
Qualcomm devices, so those encoders do list a plain planar or semi-planar input format next to
the vendor `YUV420PackedSemiPlanar32m`.

### Gaps found in upstream `droidmedia`

- **Per-frame sync request is a no-op.** `droid_media_codec_queue()` stores `kKeyIsSyncFrame`
  on the input buffer, but `queueInputBuffer()` passes `flags = 0` and never reads it.
  The screencap code requests IDRs with the `request-sync` parameter through
  `setParameters()` instead (`droidmediascreencapture.cpp:435`). `DroidMediaCodec` reaches
  `setParameters()` already (`droid_media_codec_set_video_encoder_bitrate()`,
  `droidmediacodec.cpp:1199`), so a `droid_media_codec_request_sync_frame()` is a few lines.
  GStreamer's force-key-unit event would map onto it.
- **Keyframe interval is hardcoded to 2 s** in `buildMetaData()` (`droidmediacodec.cpp:621`,
  marked TODO). A metadata field with default 2 keeps existing users unchanged.
- **H.264-only extras.** Profile/level, prepended headers and bitrate mode are set only for
  AVC (`droidmediacodec.cpp:487-505`), and `codec_specific` has only an `h264` member. HEVC
  (`video/hevc`) would still create and run if the device has a hardware encoder, with the
  codec's defaults, until an `hevc` entry is added next to it.

## 3. Bitmaps, textures, decoded video

- **Bitmaps.** RGB → I420/NV12 on the CPU, then `droid_media_codec_queue()`. In GStreamer this
  is `videoconvert` in front of the encoder. 1080p30 fits the CPU budget.
- **Textures.** Byte-buffer MediaCodec cannot take a GL texture; `glReadPixels` plus
  conversion is slow and stalls the GPU. The right tool is the `hwenc` design:
  `eglCreateWindowSurface()` on the encoder's input Surface and draw into it, as the QPA plugin
  does (`hwcomposer_screencapture.cpp:458`). This is the case for the in-process encoder split
  of §1.
- **Decoded video.** `droidvdec` (hardware decode) already outputs I420 in system memory as a
  fallback to its gralloc path (`gstdroidvdec.c:66-73`, CPU conversion from Qualcomm NV12 at
  `gstdroidvdec.c:258-280`). A raw-input `droidvenc` completes a hardware transcode.

## 4. What a raw-input `droidvenc` needs

All in `gst-droid/gst/droidcodec/gstdroidvenc.c`, modelled on gecko's `DroidVideoEncoder`:
- a second sink caps entry: system-memory `video/x-raw, format={NV12, I420}`, next to the
  existing `memory:DroidVideoMetaData` YV12 (`gstdroidvenc.c:40-45`);
- in `gst_droidvenc_create_codec()` (`gstdroidvenc.c:120-196`): `meta_data` from the caps
  feature, not the current constant `true`; for raw caps pick `color_format` from
  `droid_media_codec_get_supported_color_formats()` rather than the peer colour-format query
  (which only `droidcamsrc` answers, `gstdroidcamsrc.c:1678`); `stride` and `slice_height`
  from `GstVideoInfo`;
- `handle_frame`: pack the planes into one contiguous buffer when the `GstBuffer` is not already
  one plane layout the codec accepts, then the existing `droid_media_codec_queue()` path;
- force-key-unit → `droid_media_codec_request_sync_frame()` once that exists in `droidmedia`;
- `profile` and `level` properties as on `droidscreencapsrc`, via the shared
  `droid_media_codec_set_h264_profile_level()` the `hwenc` branch factored out.

The output side (codec_data construction, sync marking, `video/x-h264, stream-format=avc,
alignment=au` caps from `gstdroidcodec.c:168-169`) is unchanged.

The one device check before starting: which colour formats the phone's AVC encoder lists.
Gecko's logic (first of planar/semi-planar) is the expected answer; if only the vendor `32m`
layout came back, the element would need a padded copy.

## 5. Sample pipelines (once the raw `droidvenc` exists)

Smoke test, no decoder involved:

```sh
gst-launch-1.0 -e videotestsrc num-buffers=300 ! video/x-raw,format=NV12,width=1280,height=720,framerate=30/1 \
  ! droidvenc target-bitrate=4000000 ! h264parse ! video/x-h264,stream-format=byte-stream ! filesink location=/tmp/test.h264
ffprobe -v error -show_entries stream=profile,width,height -of csv=p=0 /tmp/test.h264
```

Hardware transcode, hardware decode and encode (`droidvdec` → `droidvenc`):

```sh
gst-launch-1.0 -e filesrc location=in.mp4 ! qtdemux ! h264parse ! droidvdec \
  ! videoconvert ! droidvenc target-bitrate=4000000 ! h264parse ! mp4mux ! filesink location=out.mp4
```

`videoconvert` is a pass-through if the encoder takes I420; it interleaves to NV12 otherwise.
Downscale on the way (CPU scale, fine for a test):

```sh
gst-launch-1.0 -e filesrc location=in.mp4 ! qtdemux ! h264parse ! droidvdec \
  ! videoscale ! video/x-raw,width=1280,height=720 ! videoconvert \
  ! droidvenc target-bitrate=2500000 ! h264parse ! mp4mux ! filesink location=out720.mp4
```

Any input container or codec, software decode (`decodebin`, `gst-libav` if installed):

```sh
gst-launch-1.0 -e filesrc location=in.webm ! decodebin ! videoconvert \
  ! droidvenc target-bitrate=4000000 ! h264parse ! mp4mux ! filesink location=out.mp4
```

ffmpeg as the decoder, if `ffmpeg` is on the phone (the checklist only needs `ffprobe` there):

```sh
ffmpeg -v error -i in.mp4 -f rawvideo -pix_fmt nv12 - \
  | gst-launch-1.0 -e fdsrc fd=0 ! rawvideoparse format=nv12 width=1920 height=1080 framerate=30/1 \
    ! droidvenc target-bitrate=4000000 ! h264parse ! mp4mux ! filesink location=out.mp4
```

Audio is dropped in all of these; add a `qtdemux` audio branch into `mp4mux` to keep it.

## 6. An ffmpeg encoder instead?

FFmpeg's `h264_mediacodec`/`hevc_mediacodec` encoders use the NDK's `libmediandk`, a Bionic
library with no hybris wrapper, so they cannot work in Sailfish's glibc ffmpeg. A
`h264_droidmedia` libavcodec encoder is feasible: a few hundred lines linking the same
`libdroidmedia` wrapper `gst-droid` uses (`init` → metadata + `create_encoder`/`start`;
`send_frame` → pack planes + `queue`; `receive_packet` ← `data_available` through a
mutex/condvar queue, `codec_config` → `extradata`; `flush` → `drain` + `signal_eos`). The cost
is in packaging: ffmpeg has no plugin mechanism, so it means patching `configure`,
`allcodecs.c` and the Makefile and rebuilding the Sailfish ffmpeg package against
`droidmedia-devel` in PlatformSDK. The raw `droidvenc` comes first: one file in a repository we
already build, and it also serves the ffmpeg-pipe pipeline above.

## 7. Relation to `hwenc`

- Shared: the profile/level enums and `droid_media_codec_set_h264_profile_level()`; the
  `droidscreencapsrc` lessons on caps, key units and the overload bound.
- Not shared: the Surface encoder and the `sailfish.screencap` service. CPU frames never go
  through them.
- Later, optional: once `droid_media_codec_request_sync_frame()` exists, the screencap code
  could call it instead of its own `setParameters()` block. Not part of the review.
