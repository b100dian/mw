# How Android encodes the screen

Background for `droidscreencapsrc`: the three ways the Android 14 tree in the
HADK puts the screen into a hardware H.264 encoder, and how each compares
with ours. Paths are relative to the HADK root. Line numbers are from that
tree.

## Overview

| | Stagefright recorder | `screenrecord` | Miracast (WFD) source | `droidscreencapsrc` |
|---|---|---|---|---|
| Who renders | the app's virtual display (MediaProjection) | SurfaceFlinger, a virtual display | SurfaceFlinger, a virtual display | lipstick, one quad per frame |
| Encoder wrapper | `MediaCodecSource`, `FLAG_USE_SURFACE_INPUT` | plain `MediaCodec` | `Converter` around `MediaCodec` | plain `MediaCodec` |
| Encoder input | input Surface | input Surface | buffer handles (ANWBuffer metadata) | input Surface |
| Idle screen | no frames | no frames | the last frame repeated at the session fps | no frames |
| IDR on request | `requestIDRFrame()` | none | wake the repeater, then `requestIDRFrame()` | `request-sync` and `requestFrame` to lipstick |
| Stop | `setStopTimeUs(now)`, then end of input with a stall timer | stops the codec without draining | session teardown | unregister, 100 ms grace, end of input, drain |
| Output | `MediaWriter` (MP4, ...) | `MediaMuxer` (MP4, WebM) or raw | MPEG-TS over RTP | GStreamer buffers |

## The input Surface

Each Surface-input path goes through the same code. `MediaCodec::createInputSurface()`
reaches `CCodec`, which gets a Codec2 input surface. The input surface wraps
`GraphicBufferSource` (`frameworks/av/media/module/bqhelper/GraphicBufferSource.cpp`),
the BufferQueue consumer that hands queued buffers to the encoder. Our
encoder uses it too.

It acts on format keys at configure time and on `setParameters()` later.
`CCodec` translates both into the input surface's config
(`frameworks/av/media/codec2/sfplugin/CCodec.cpp`, around lines 360-410,
983 and 2236):

- **Frame repeat:** `repeat-previous-frame-after` (µs) becomes a minimum fps.
  After each new buffer, `GraphicBufferSource` re-submits it at that
  interval, at most `kRepeatLastFrameCount` (10) times, so a static scene
  loses its encoder ghosting (`repeatLatestBuffer_l()`).
- **Max fps:** `max-fps-to-encoder` drops buffers above a rate.
- **Suspend:** `drop-input-frames` (`PARAMETER_KEY_SUSPEND`), optionally from
  a time (`PARAMETER_KEY_SUSPEND_TIME`). Buffers are consumed and dropped.
- **Start:** `skip-frames-before` drops buffers timestamped before it and
  makes later timestamps relative to it.
- **Stop:** `stop-time-us` queues a STOP action. The first buffer at or after
  that time triggers end of stream. While a stop time is set,
  `signalEndOfInputStream()` doesn't send end of stream on its own
  (`GraphicBufferSource.cpp:1438`). `android._stop-time-offset-us` in the
  input format reports how far the last buffer lies before the stop time.
- **Time offset:** `time-offset-us` (`PARAMETER_KEY_OFFSET_TIME`) is added to
  every timestamp.

Timestamps are what the producer set: for us,
`eglPresentationTimeANDROID(CLOCK_MONOTONIC)` in lipstick. `stop-time-us` and
`skip-frames-before` compare against them, so they are in the same clock as
`systemTime()`.

## Stagefright recorder

`MediaRecorder.setVideoSource(VideoSource.SURFACE)` runs `StagefrightRecorder`
in the media server. Screen recorder apps use this together with a
MediaProjection virtual display.

- `StagefrightRecorder::setupVideoEncoder()` sets
  `MediaCodecSource::FLAG_USE_SURFACE_INPUT` when there is no camera source
  (`frameworks/av/media/libmediaplayerservice/StagefrightRecorder.cpp:2142`)
  and keeps `encoder->getGraphicBufferProducer()` (`:2162`).
  `querySurfaceMediaSource()` hands that producer to the app.
- `stop()` calls `setStopTimeUs(systemTime())` on the audio and video
  sources before stopping the writer (`:2408`).

`MediaCodecSource` (`frameworks/av/media/libstagefright/MediaCodecSource.cpp`)
turns a `MediaCodec` into a pull-style `MediaSource`:

- **Input.** Without the flag, a `Puller` reads from an upstream
  `MediaSource` and copies into the encoder's input buffers. With the flag,
  `initEncoder()` creates the input Surface after configure. It configures
  the Surface suspended (`KEY_CREATE_INPUT_SURFACE_SUSPENDED`, `:510`), and
  `start()` resumes it, with `skip-frames-before` if a start time is given.
- **Codec choice.** `findMatchingCodecs()` with no flags, or
  `kPreferSoftwareCodecs` with `FLAG_PREFER_SOFTWARE_CODEC`. Hardware-only
  selection isn't possible.
- **Output.** The codec runs in async mode (`kWhatEncoderActivity`). Each
  output buffer is copied into a `MediaBuffer` on a queue. `read()` blocks on
  that queue. A Surface-input frame gets its PTS as DTS.
- **Stop.** `kWhatStop` calls `signalEndOfInputStream()` and arms
  `kWhatStopStalled`. The timer is 300 ms plus the input surface's stop-time
  offset, or 1 s (`kMaxStopTimeOffsetUs`) when there is none. On end of
  stream or the timer, `signalEOS()` releases the encoder. It also releases
  every output buffer the reader hasn't taken yet (`:655`), and `read()`
  then reports the end at once.
- **Errors.** `CB_ERROR` becomes end of stream; `read()` returns the error.
- **Other:** pause/resume through suspend, `setEncodingBitrate()`,
  `requestIDRFrame()`, `setInputBufferTimeOffset()`.

libhybris wraps it as `media_codec_source_create()` with
`MEDIA_CODEC_SOURCE_FLAG_USE_SURFACE_INPUT`
(`libhybris/hybris/include/hybris/media/media_codec_source_layer.h`).
droidmedia reaches `MediaCodecSource` only for camera recording
(`droidmedia/AsyncCodecSource.cpp:130`).

## `screenrecord`

`adb shell screenrecord` (`frameworks/av/cmds/screenrecord/screenrecord.cpp`)
is the closest stock equivalent of `DroidMediaScreenCapture`:

- `prepareEncoder()`: plain `MediaCodec::CreateByType()`, configure with
  `OMX_COLOR_FormatAndroidOpaque`, then `createInputSurface()` (`:246`) or a
  persistent input surface.
- `prepareVirtualDisplay()` (`:360`): a SurfaceFlinger virtual display whose
  surface is the encoder's producer, with a mirror of the physical display
  on its layer stack. SurfaceFlinger composites into the encoder.
- `runEncoder()`: its own `dequeueOutputBuffer()` loop (`:599`) into
  `MediaMuxer` or raw output.
- Stop: Ctrl-C or the time limit (180 s) ends the loop; `encoder->stop()`
  follows with no end of input and no drain.
- No frame repeat: an idle screen gives no frames.

The choices are the same as ours: plain `MediaCodec`, our own output loop.
The difference is the renderer. SurfaceFlinger does it there; on Sailfish
lipstick does it.

## Miracast (WFD) source

Disabled by default: `config_enableWifiDisplay` is `false` in
`frameworks/base/core/res/res/values/config.xml`, and a device overlay turns
it on.

**Control path.** `WifiDisplayController` (system server) calls
`RemoteDisplay.listen()`. Through JNI and `IMediaPlayerService` this reaches
`MediaPlayerService::listenForRemoteDisplay()`, which creates a
`RemoteDisplay` running a `WifiDisplaySource`
(`frameworks/av/media/libstagefright/wifi-display/source/`). The source
speaks RTSP with the sink and negotiates resolution, fps, profile and level,
and HDCP. Once the session is up, it hands
`PlaybackSession::getSurfaceTexture()` to the client
(`WifiDisplaySource.cpp:430`). `WifiDisplayAdapter` then creates a display
with that Surface (`DisplayControl.createDisplay()`), and SurfaceFlinger
composites into it as into any virtual display.

**Media path** (`PlaybackSession::addVideoSource()` and `addSource()`):

```
SurfaceMediaSource -> RepeaterSource -> MediaPuller -> Converter -> MediaSender -> TSPacketizer -> RTPSender
(BufferQueue        (last frame at     (read loop)    (MediaCodec    (tracks)      (MPEG-TS)       (UDP or TCP)
 consumer)           the session fps)                  encoder)
```

- `SurfaceMediaSource` is the BufferQueue consumer. Its producer is the
  Surface handed to the display.
- `RepeaterSource` reads the newest buffer in the background and returns it
  at a fixed rate (`bufferTimeUs = start + frameCount / rate`). The encoder
  gets a steady frame rate even on an idle screen. Going dormant after 1 s
  idle is compiled out (`SUSPEND_VIDEO_IF_IDLE 0`).
- `Converter` (`Converter.cpp`) configures the encoder with
  `android._input-metadata-buffer-type` = `kMetadataBufferTypeANWBuffer` and
  `OMX_COLOR_FormatAndroidOpaque`. Input buffers carry handles to the
  graphic buffers, not pixels, so nothing is copied. Constant bitrate
  (`media.wfd.video-bitrate`, default 5 Mbit/s), an IDR every 15 s, and
  cyclic intra refresh over about 10 frames, so a lost packet is repaired
  without waiting for an IDR.
- `Converter` has its own `FLAG_USE_SURFACE_INPUT`, but `PlaybackSession`
  never sets it: Miracast uses buffer input.
- **IDR on request** (`Track::requestIDRFrame()`, `PlaybackSession.cpp:285`):
  wakes the `RepeaterSource` so a frame is there to encode, then asks the
  `Converter` for an IDR.
- **Suspend:** `Converter::suspendEncoding()`. In buffer mode it skips
  input; in Surface mode it would set `drop-input-frames`.
- **Transport:** `MediaSender` in transport-stream mode packetizes into
  MPEG-TS (`TSPacketizer`, with SPS/PPS prepended to IDRs) and sends it over
  RTP (`RTPSender`), with HDCP encryption if negotiated.

## What it means for us

- **Steady rate vs idle gaps.** Miracast sends a steady stream through
  `RepeaterSource`. We send only changes and keep the gaps in the PTS. A
  receiver that expects a steady rate (Android Auto, some RTP players) could
  get one from `repeat-previous-frame-after` without a repeater of our own.
  See "Repeat the last frame on an idle screen" in
  [`improvement-ideas.md`](improvement-ideas.md).
- **IDR on an idle screen.** Miracast wakes its repeater; we ask lipstick for
  a frame with `requestFrame`. It's the same idea: an IDR needs an input
  frame.
- **Transport.** MPEG-TS over RTP with intra refresh and SPS/PPS on every IDR
  is a tested model for `scripts/sharing-rtp.sh` and Android Auto.
- **Encoder wrapper.** `screenrecord` uses plain `MediaCodec`, as we do.
  `MediaCodecSource` with `FLAG_USE_SURFACE_INPUT` would replace our output
  loop, but loses trailing output at end of stream and stalls when stopped
  on an idle screen. See "`MediaCodecSource` with `FLAG_USE_SURFACE_INPUT`"
  in [`improvement-ideas.md`](improvement-ideas.md).
