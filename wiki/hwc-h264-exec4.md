# HWC → H.264 Encoding — Execution 4

**Date:** 2026-09-27  
**Basis:** `wiki/hwc-h264-encoding-revision4.md`  
**Current gate:** Gate 4.2 — MP4 timestamp proof passed; streaming run pending (Section 13)  
**Status:** Gates 4.0 and 4.1 passed on-device (2026-09-27). Gate 4.2 MP4 via `qtmux` is valid with idle gaps preserved (Section 11); the final-sample duration is provably lost in `h264parse`, not in the element. Gallery playback is broken for every video on the device (Section 12), so Gate 4.5 is blocked independently of this work. Conclusions so far in Section 15.

## 1. Plan review

Revision 4 was reviewed against the current `hwenc` heads (`droidmedia aa15e72`, `gst-droid c348b32`, `qt5-qpa-hwcomposer-plugin 48e882e`). All nine blockers listed in its Section 1 were confirmed present in the tree. Two points in the plan required a source check rather than acceptance by inference:

1. **EOS delivery to a live push source (§6.2).** In GStreamer `1.26.11` (`gstbasesrc.c`, `gst_base_src_send_event`, `GST_EVENT_EOS`), a downstream EOS sent to a push-mode `GstBaseSrc` sets flushing, marks `has_pending_eos`, and restarts the task. `gst_base_src_get_range()` then returns EOS *before* entering `create()`. That means the default path can never let the element drain the codec's final access units. The element therefore overrides `GstElement::send_event`, consumes EOS itself while `running`, and performs the graceful finish on the streaming thread inside `create()`. Other events fall through to the base class. `send_event()` runs with the element `STATE_LOCK` held; the override only sets flags and broadcasts a condition variable.

2. **H.264 parser duration handling (§4.4).** `gsth264parse.c` (`gst_h264_parse_pre_push_frame`) keeps an upstream `GST_BUFFER_DURATION` when it is valid and only derives its own when it is not. Upstream-provided lookahead durations are therefore preserved through `h264parse` on this target.

Everything else in Revision 4 was implemented as written.

## 2. droidmedia changes

`screen_capture_surface_encoder.h` / `.cpp`:

- `ScreenCaptureSurfaceEncodedFrame` gained `bool sync` and `bool codec_config`, derived in droidmedia from `BUFFER_FLAG_SYNCFRAME` / `BUFFER_FLAG_CODECCONFIG`. `flags` is retained for diagnostics only. EOS is still delivered only through the `eos` callback.
- New `screen_capture_surface_encoder_finish(encoder, timeout_ms)`: atomically moves the state to `FINISHING`, unregisters the service generation, keeps the 500 ms QPA detach grace, calls `MediaCodec::signalEndOfInputStream()` while the drain thread is running, waits on a monotonic-clock condvar until the drain thread reports codec EOS (or timeout / drain-thread exit / concurrent `stop()`), then stops and joins. Returns `true` only if codec EOS was delivered. The `eos` callback is invoked by the drain thread after the last access unit and before the thread exits.
- `stop()` is idempotent and bounded. If `finish()` is in progress on another thread, `stop()` cuts the drain wait short via `mStopRequested` and waits for `STATE_STOPPED`. `destroy()` calls `stop()`.
- Encoder state (`IDLE/STARTED/FINISHING/STOPPING/STOPPED`) replaced the `mStarted` boolean. Callbacks are never invoked while `mLock` is held.
- A single-use object contract is documented: create, start, finish or stop, destroy.

`hybris.c`: wrappers for `screen_capture_surface_encoder_new/start/finish/stop/destroy`. `meson.build`: installs `screen_capture_surface_encoder.h`.

`tools/screencap_surface_capture_test.cpp`: uses the semantic fields (no MediaCodec header), exercises `finish()` by default, and `SCREENCAP_SURFACE_FORCE_STOP=1` selects the immediate `stop()` path. This lets the droidmedia EOS change be verified on-device independently of GStreamer.

No QPA, libminisf, or service Binder contract change.

## 3. `droidscreencapsrc` refactor

`gst-droid/gst/droidscreencapsrc/gstdroidscreencapsrc.[ch]` were rewritten. The legacy `droid_media_screen_capture_consumer_new()` retries, `queue`, `screen_capture_encoder_new()`, `color-format`, and `metadata-mode` are gone; the element no longer includes `screen_capture_encoder.h`.

Properties: `width`, `height` (0 = query `droid_media_screen_capture_get_dimensions()`, fail clearly if unknown), `target-bitrate`, `fps`.

Caps: template `video/x-h264,stream-format=byte-stream,alignment=au` with no profile. `get_caps()` returns fixed `width/height/framerate=fps/1` once dimensions are resolved.

Timestamps: origin is the first ordinary access unit; codec-config buffers do not participate. `PTS = (pts_us - first_pts_us) * 1000` with checked arithmetic. A regressing ordinary PTS terminates the run with an error rather than clamping. DTS is left unset.

Duration: one-access-unit lookahead (`pending`). On EOS the final frame's duration extends to the monotonic time at which EOS was requested; if that is not later than the final PTS, one nominal frame period is used and logged.

Codec config: latest SPS/PPS is retained outside the queue and emitted as a `GST_BUFFER_FLAG_HEADER` buffer immediately before the next sync frame (initially and after every overload episode), carrying that sync frame's PTS.

Bounded queue: 30 ordinary frames or 8 MiB. On hitting a bound, all queued ordinary frames plus the arriving frame are dropped, the element enters `waiting_for_keyframe`, non-sync frames are discarded, and one warning is logged when the episode starts and one when it ends with frame/byte totals. Header buffers do not count against the bound.

Lifecycle:

- `start()`: reset run state, resolve dimensions, create encoder, mark `running` (callbacks may fire as soon as the codec starts), start encoder; on failure destroy and reset.
- EOS (`send_event`): set `eos_requested`/`stop_time_us`, wake `create()`. `create()` calls `screen_capture_surface_encoder_finish()` without `output_lock`, then drains the queue and returns `GST_FLOW_EOS`.
- `unlock()/unlock_stop()`: set/clear `flushing`; `create()` returns `GST_FLOW_FLUSHING`.
- `stop()`: `running=false, flushing=true`, wake, call bounded encoder stop/destroy without the lock, then free queue/pending/config/timestamp state.
- Error callback: store first error, wake `create()`, which posts one `GST_ELEMENT_ERROR` and returns `GST_FLOW_ERROR`.

The tradeoff of one-frame output latency is intentional for a recording source.

## 4. Build status

| Step | Result |
|---|---|
| `gst-droid` package build (PlatformSDK) against updated `droidmedia-devel` | passed, no warnings in `gstdroidscreencapsrc.c` |
| `droidmedia-devel` (installs the new header and `hybris.c`) | rebuilt with `rpm/dhd/helpers/build_packages.sh -b hybris/mw/droidmedia -s rpm/droidmedia-devel.spec` |
| Android `libdroidmedia.so` + `screencap_surface_capture_test` (`make droidmedia` in croot) | **pending** — required before any device run; the new wrapper symbols abort at first call against an old `libdroidmedia.so` |

Deploy `libdroidmedia.so`, `screencap_surface_capture_test`, and the `gstreamer1.0-droid` RPM as a matched set.

## 5. Gate 4.0 device checks

```sh
gst-inspect-1.0 droidscreencapsrc
```

Expect properties `width`, `height`, `target-bitrate`, `fps`; caps `video/x-h264, stream-format=byte-stream, alignment=au` without a profile field; and no `color-format` / `metadata-mode`.

Optionally verify the droidmedia side first with the same QPA configuration as Gate 3 (`QPA_HWC_SCREENCAP=1 QPA_HWC_SCREENCAP_SOURCE=1 QPA_HWC_SCREENCAP_FLIP_Y=1 QPA_HWC_SCREENCAP_FRAME_LIMIT=0`):

```sh
SCREENCAP_SURFACE_DEBUG=1 LD_LIBRARY_PATH=/usr/libexec/droid-hybris/system/lib64 \
/usr/libexec/droid-hybris/system/bin/screencap_surface_capture_test \
    1080 2520 8000000 30 5 /tmp/screencap-gate4.0.h264
```

Expect `sync=`/`config=` in the per-frame debug lines, `Surface encoder input EOS signalled`, `Surface encoder output EOS reached`, `encoder EOS`, and `graceful finish: reached codec EOS (eos callback=1)`.

## 6. Gate 4.1 / 4.2 device procedure

Gate 4.1 (byte-stream, no muxer):

```sh
GST_DEBUG=droidscreencapsrc:5,h264parse:4 gst-launch-1.0 -e -v \
  droidscreencapsrc width=1080 height=2520 target-bitrate=8000000 fps=30 ! \
  h264parse ! filesink location=/tmp/screen-gate4.1.h264
```

Gate 4.2 (Matroska):

```sh
GST_DEBUG=droidscreencapsrc:5,h264parse:4,matroskamux:4 gst-launch-1.0 -e -v \
  droidscreencapsrc width=1080 height=2520 target-bitrate=8000000 fps=30 ! \
  h264parse ! matroskamux ! filesink location=/tmp/screen-gate4.2.mkv
```

Timeline for 4.2: ~3 s motion, ~5 s idle, ~3 s motion, ~2 s idle, then Ctrl-C (with `-e`, `gst-launch` sends EOS). Note wall-clock start/stop.

Validate:

```sh
ffprobe -v error -show_streams -show_format /tmp/screen-gate4.2.mkv
ffprobe -v error -select_streams v:0 -show_packets \
    -show_entries packet=pts_time,duration_time,flags,size \
    -of csv /tmp/screen-gate4.2.mkv
```

Pass criteria are those of Revision 4 §7: `format.duration` close to wall clock, monotonic `pts_time` with the ~5 s gap intact, the final packet's `duration_time` reaching close to stop, and the container recognized after repeated playback.

Expected element log lines to retain: `timestamp origin: codec pts …`, `retained codec config`, `EOS requested; finishing encoder gracefully`, `finishing encoder (timeout 3000 ms)`, `encoder reached EOS`, `final frame PTS … duration … (to recording stop)`, `EOS after N frames`, and `run summary`.

## 7. Gate 4.0 device result — passed (2026-09-27)

Matched `libdroidmedia.so`, `screencap_surface_capture_test`, and `gstreamer1.0-droid` were deployed. `screencap_surface_capture_test 1080 2520 8000000 30 5` produced 49 ordinary access units (1 327 145 bytes), High profile 1080x2520:

- semantic fields correct: `flags=0x2 → config=1`, `flags=0x1 → sync=1`, `flags=0x0 → delta`;
- idle gaps preserved in codec PTS (e.g. a 412 ms gap at `…432113090 → …432525222`);
- graceful path: `encoder EOS` then `graceful finish: reached codec EOS (eos callback=1)`, no timeout. This settles the open question: the device's Codec2 AVC encoder honours `signalEndOfInputStream()` after the producer is unregistered.

The raw `.h264` did not play in Gallery. This is the known raw-Annex-B limitation recorded at Gate 3 and is not a Gate 4 criterion.

Observation: the first two ordinary frames were both IDR with identical size 10 ms apart, i.e. the encoder emits its first picture twice. The element handles it (monotonic, both `sync`). It did not recur in the Gate 4.1 run.

## 8. Gate 4.1 device result — passed (2026-09-27)

Log: `logs/gstlog1.txt`. Pipeline as in Section 6, ~6.6 s wall clock, 80 access units.

- fixed caps negotiated: `width=1080, height=2520, framerate=30/1, byte-stream, au`; `h264parse` derived `profile=high, level=5` from the stream;
- `retained codec config (41 bytes)` then `timestamp origin: codec pts 337172678697us`; codec config pushed as a `HEADER` buffer at PTS 0 ahead of the first IDR;
- normalized PTS monotonic from 0; idle gaps preserved as durations (second AU `duration 0.131510`, others ~0.033);
- EOS: `EOS requested; finishing encoder gracefully` → `finishing encoder (timeout 3000 ms)` → `encoder reached EOS` after 518 ms → `final frame PTS 4.515656 duration 1.234606 (to recording stop)` → `EOS after 80 frames` → `Got EOS from element "pipeline0"`;
- `run summary: 80 frames pushed, 0 overload episodes, 0 frames dropped`; no warnings, no hang.

## 9. Gate 4.2 — container choice revisited

The first `matroskamux` output did not play in Gallery. Gallery is not a valid Matroska judge (tracker indexing, weak `.mkv` support), so the file must first be classified with `ffprobe -show_format -show_streams`, `-show_packets`, and a full `ffmpeg -f null` decode. A malformed container (missing duration/cues, truncated last cluster) would indicate EOS not reaching the muxer and needs the `matroskamux:4` log of that run.

Because the product goal is H.264 *streaming*, Gate 4.2 uses the following containers. None requires an element change; all consume the same `byte-stream, au` + PTS + duration contract.

| Container | Role in Gate 4 | Proves idle gaps | Proves final-sample duration (§4.4) |
|---|---|---|---|
| MP4 (`qtmux`) | file proof and Gallery compatibility; fragmented MP4 is the HLS/DASH streaming form | yes | **yes** (`stts`) — the only container here that stores per-sample durations |
| MPEG-TS (`avmux_mpegts`; `mpegtsmux` is not installed) | streaming proxy: no finalization step, survives a killed pipeline, `udpsink`-able | yes | no (PTS only) |
| RTP (`rtph264pay`) | the live path, later gate | yes | no |
| Matroska | original plan; keep only if `ffprobe` shows it valid | yes | no (last BlockDuration not written) |

MP4:

```sh
GST_DEBUG=droidscreencapsrc:4,qtmux:4 gst-launch-1.0 -e -v \
  droidscreencapsrc width=1080 height=2520 target-bitrate=8000000 fps=30 ! \
  h264parse config-interval=-1 ! video/x-h264,stream-format=avc,alignment=au ! \
  qtmux ! filesink location=/tmp/screen-gate4.2.mp4
```

MPEG-TS to file, then over UDP to a host receiver (`ffplay udp://@:5000`):

```sh
gst-launch-1.0 -e -v droidscreencapsrc width=1080 height=2520 target-bitrate=8000000 fps=30 ! \
  h264parse ! mpegtsmux ! filesink location=/tmp/screen-gate4.2.ts

gst-launch-1.0 -v droidscreencapsrc width=1080 height=2520 target-bitrate=8000000 fps=30 ! \
  h264parse ! mpegtsmux ! udpsink host=0.0.0.0 port=5000
```

Check plugin availability first; Sailfish splits GStreamer plugin packages:

```sh
gst-inspect-1.0 2>/dev/null | grep -E 'matroskamux|qtmux|mp4mux|mpegtsmux|rtph264pay'
```

Gate 4.2 passes when at least MP4 shows: `format.duration` ≈ wall clock, monotonic packet `pts_time` with the deliberate idle gap, a final packet `duration_time` extending to stop, clean repeated playback, and Gallery recognition. MPEG-TS passes when the file/stream decodes with the gap preserved; its lack of a final duration is a container limitation, not an element defect.

## 10. Gate 4.2 first MP4 attempt — failed, root cause and correction (2026-09-27)

```text
ERROR: from element /GstPipeline:pipeline0/GstQTMux:qtmux0: Could not multiplex stream.
../gst/isomp4/gstqtmux.c(5507): gst_qt_mux_add_buffer (): Buffer has no PTS.
```

`qtmux` rejects the stream on its *first* stored buffer (`gst_qt_mux_add_buffer`, `last_buf` PTS check). That buffer is the separate codec-configuration buffer this element pushed at PTS 0 with `GST_BUFFER_FLAG_HEADER`. Source review of GStreamer 1.26.11 shows why it loses its timestamp on the way:

- `gstbaseparse.c` `gst_base_parse_handle_and_push_frame()`: for a time-format upstream, base parse clears the frame's PTS/DTS and reinstates them from its own tracking (`next_pts`), which it only updates when the incoming PTS *changes* (`prev_pts != pts`, `gst_base_parse_chain`).
- `gsth264parse.c` `gst_h264_parse_get_timestamp()`: for a header-only frame (`frame_start == FALSE`, i.e. no slice) it sets duration 0 and provides no timestamp.
- With `pts_interpolate` disabled by `h264parse`, a frame whose PTS was not re-derived stays `GST_CLOCK_TIME_NONE`.

In byte-stream output (Gate 4.1) the header buffer went to `filesink`, which does not care. In AVC output for `qtmux` it becomes a slice-less "access unit" with no PTS and the muxer errors out. The design in Revision 4 §4.5 ("preserve codec config as a `HEADER` buffer") is therefore only valid for byte-stream sinks and was revised:

1. **Codec configuration is never pushed as its own buffer.** The retained SPS/PPS is prepended in-band to every sync frame that does not already begin with it (byte-wise compare against the retained blob). Each IDR is self-describing; `h264parse` extracts `codec_data` for AVC caps from the in-band parameter sets, and after an overload episode the resume keyframe carries its own SPS/PPS with no separate emission step. The queue now contains only ordinary access units, which also simplifies the bound accounting.
2. **Duplicate-PTS access units are discarded.** The Gate 4.0 observation (first IDR emitted twice, identical size, same PTS) would produce a zero-duration sample; `qtmux`/`mp4mux` and RTP timing both misbehave on that. The element keeps the first AU for a given codec PTS, drops a repeat with a warning, and counts it in the `run summary` (`duplicate-PTS frames discarded`).

This requires a `gst-droid` rebuild only; droidmedia is unchanged.

### Streaming end-state

The product target is Android Auto projection. That protocol carries the H.264 **elementary stream** (Annex-B NAL units with a presentation timestamp per access unit, IDR frames self-contained with SPS/PPS) to the head unit's `MediaCodec`; there is no container. The `droidscreencapsrc` output contract — `video/x-h264, stream-format=byte-stream, alignment=au`, one AU per buffer, normalized PTS, SPS/PPS in-band on every IDR — is therefore already the delivery format. Containers in Gate 4.2 serve only to *prove* the timestamp behaviour with tools that can display it (`ffprobe`); MP4 additionally proves the final-sample duration, MPEG-TS proves the stream survives without finalization. Neither muxer will be in the product pipeline.

## 11. Gate 4.2 second MP4 attempt — container valid, Gallery still unexplained (2026-09-27)

Log: `logs/gstlog2.txt`. Pipeline from Section 9 with the in-band SPS/PPS build.

Element side: 187 AUs, `EOS requested → finishing encoder → encoder reached EOS` in 510 ms, `final frame PTS 10.997 duration 0.966 (to recording stop)`, `run summary: 187 frames pushed, 0 overload episodes, 0 frames dropped, 0 duplicate-PTS frames discarded`. `qtmux` no longer errors; `gst-launch` exits on `Got EOS`.

`ffprobe`: valid `mov,mp4` (brand `qt`), `avc1`, High@5.0, 1080x2520, `nb_frames=187`, `duration=11.030667`. Packet list: PTS monotonic from 0; idle gaps preserved exactly as `pts_time` deltas (0.960 s, 1.017 s, 1.749 s, 0.609 s); keyframes roughly every second.

### Final-sample duration does not survive `h264parse` (source-verified)

The last packet shows `duration_time=0.033333`, not the 0.966 s the element set, so `format.duration` is ~0.93 s short of wall clock. Cause in GStreamer 1.26.11:

- `gstbaseparse.c` chain path: for a time-format upstream, `GST_BUFFER_DURATION (tmpbuf) = GST_CLOCK_TIME_NONE` before the subclass sees the data.
- `gsth264parse.c` `gst_h264_parse_parse_frame()`: with `do_ts` (default) it recomputes the duration from SPS VUI timing (`num_units_in_tick/time_scale` → 1/30 s).
- `gstqtmux.c` `gst_qt_mux_add_buffer()`: intermediate sample durations are PTS deltas (which is why the gaps survive); only the *last* sample uses `GST_BUFFER_DURATION`, which is now h264parse's 1/30 s.

Consequence: an MP4 written through `h264parse` proves gap preservation but cannot prove the Revision 4 §4.4 tail extension. The element's own output is proven with `identity silent=false ! fakesink` before any parser (last `chain` line shows the extended duration). For Android Auto there is no parser or container, so the element contract is what matters. Section 9's pass criterion is amended: "final packet `duration_time` extending to stop" is checked at the element boundary, not in the MP4.

### Gallery

Still does not play; nothing in `ffprobe` explains it. Classified in Section 12.

## 12. Gallery classified: device playback is broken for every video (2026-09-27)

The MP4 copied to `~/Videos` is indexed and gets a correct thumbnail (so `qtdemux`/tracker accept the container). Pressing play does nothing; pause/play toggles in the UI but no frame is ever shown, and `jolla-gallery` run from a shell with `GST_DEBUG=2` and `=4` produces no further output until Ctrl-C — the decode thread is stuck. An `mp4mux` (brand `isom`) recording behaves identically, so the `qt` brand is not the cause.

**No video at all plays in Gallery on this device**, including files not produced by this work. The playback stall is therefore in the device's `droidvdec`/`libdroidmedia` pairing, not in our container or stream. The `hwenc` branches were started from `droidmedia 0.20260522.0` and `gst-droid 0.20260508.1`; the deployed `libdroidmedia.so` is built from the `hwenc` head and is newer than the `gstreamer1.0-droid`/`droidmedia` pair this Sailfish OS 5.1 image shipped with. A similar decode stall has been reported on other ports with mismatched pairs. Two possibilities, in order of likelihood:

1. Version mismatch between the deployed `libdroidmedia.so` (hwenc head) and the rest of the device's media stack — fix by upgrading `gst-droid` to match, or by rebasing `hwenc` on the droidmedia tag the image uses.
2. The `hwenc` droidmedia changes themselves — unlikely, since they add a new encoder object and hybris wrappers without touching the decoder or `DroidMediaCodec` paths, but not excluded until (1) is tested.

Set aside for now. **Gate 4.5 (Gallery compatibility) is blocked on this and is not a judgement on the recording path.** Remaining playback proof for Gate 4.2 uses `ffprobe`/`ffmpeg` on device or any player on a host.

Still useful for the record: `ffmpeg -v error -i /tmp/screen-gate4.2.mp4 -f null -` (software decode of the whole file; `libx264` is absent on device but the decoder is present).

## 13. Streaming proof to a host

None of these need element changes; all consume the element's `byte-stream, au` + PTS output. Check element availability first: `gst-inspect-1.0 tcpserversink | head -2; gst-inspect-1.0 udpsink | head -2`.

**A. Raw elementary stream over TCP** — the Android Auto payload shape. No timing on the wire, so idle gaps collapse in the player; that is expected and not a defect. A client may connect at any time; decoding starts at the next IDR because every IDR carries SPS/PPS in-band.

```sh
# phone
GST_DEBUG=droidscreencapsrc:4 gst-launch-1.0 -v \
  droidscreencapsrc width=1080 height=2520 target-bitrate=8000000 fps=30 ! \
  tcpserversink host=0.0.0.0 port=5000 sync=false
# host
ffplay -fflags nobuffer -flags low_delay -f h264 -framerate 30 tcp://PHONE_IP:5000
```

**B. RTP over UDP** — preserves timing. `rtph264pay` derives RTP timestamps from buffer PTS, so the receiver holds the last picture through an idle gap. This is the streaming form of the Gate 4.2 timestamp proof.

```sh
# phone
GST_DEBUG=droidscreencapsrc:4 gst-launch-1.0 -v \
  droidscreencapsrc width=1080 height=2520 target-bitrate=8000000 fps=30 ! \
  rtph264pay config-interval=-1 pt=96 ! udpsink host=HOST_IP port=5000 sync=false
# host (GStreamer)
gst-launch-1.0 -v udpsrc port=5000 \
  caps="application/x-rtp,media=video,clock-rate=90000,encoding-name=H264,payload=96" ! \
  rtpjitterbuffer latency=100 ! rtph264depay ! h264parse ! avdec_h264 ! videoconvert ! autovideosink
# host (ffplay) with screen.sdp:
#   v=0
#   o=- 0 0 IN IP4 127.0.0.1
#   s=screen
#   c=IN IP4 0.0.0.0
#   t=0 0
#   m=video 5000 RTP/AVP 96
#   a=rtpmap:96 H264/90000
ffplay -protocol_whitelist file,rtp,udp -fflags nobuffer screen.sdp
```

**C. MPEG-TS over UDP via `avmux_mpegts`** — `mpegtsmux` is not installed; the libav muxer is marked "not recommended" but VLC/ffplay open the stream without an SDP. Datagrams may exceed the MTU (libav writes in chunks); fine on a LAN.

```sh
gst-launch-1.0 -v droidscreencapsrc width=1080 height=2520 target-bitrate=8000000 fps=30 ! \
  h264parse ! avmux_mpegts ! udpsink host=HOST_IP port=5000 sync=false
ffplay -fflags nobuffer udp://@:5000
```

**VLC receivers.** A: VLC cannot sniff a raw elementary stream on a socket, force the demuxer — `vlc tcp://PHONE_IP:5000 --demux=h264 --h264-fps=30 --network-caching=100`. B: open the SDP file (`vlc screen.sdp --network-caching=100`); VLC uses live555 for this and wants the receiving host's own IP in the `c=` line rather than `0.0.0.0`, and an `a=fmtp:96 packetization-mode=1` line; no `sprop-parameter-sets` is needed because SPS/PPS are in-band. Plain `vlc rtp://@:5000` only works for MPEG-TS payloads. C: `vlc udp://@:5000` as-is.

`sync=false` on the network sinks: the element's PTS origin is the first access unit, which arrives ~1 s after the pipeline clock started, so every buffer is "late" relative to running time; sinks would render immediately anyway, but the explicit setting avoids depending on that.

**Known latency caveat (A and B):** the one-AU duration lookahead holds each frame until its successor arrives, so the last frame before an idle period is delivered only when motion resumes; the viewer sees the frame before it during the pause. Acceptable for these proofs. For the live product path a `low-latency` property that disables the lookahead (durations are irrelevant without a container) is the follow-up.

## 14. libhybris `8ac75ab` — required or not

The only commit on `libhybris/libhybris` branch `hwenc` (not an `mw` submodule). It changes `hybris/egl/platforms/hwcomposer/eglplatform_hwcomposer.cpp`: `_nativewindows` becomes `std::vector<ANativeWindow *>` and the `static_cast<HWComposerNativeWindow *>` down-casts in `hwcomposerws_CreateWindow()`/`hwcomposerws_DestroyWindow()` are removed. The deployed `/usr/lib64/libhybris/eglplatform_hwcomposer.so` carries it.

- **Required for correctness:** yes. The stock code down-casts a MediaCodec input `android::Surface` to `HWComposerNativeWindow *`, which the object is not; undefined behaviour.
- **Required for behaviour on this device:** probably not (inference from the Itanium C++ ABI, not tested). `HWComposerNativeWindow → EGLBaseNativeWindow → BaseNativeWindow → ANativeWindow` is a single-inheritance chain; the down-cast subtracts the `ANativeWindow` sub-object offset, `window->common` adds it back, and the return up-cast re-adds it, so the arithmetic is an identity and `incRef/decRef` hit the right `common`. The null-callback crash that Revision 3 §4.5 attributes to "the first two fixes" was more likely the **libminisf** `Surface* → ANativeWindow*` conversion, where the offset is real (`RefBase` is the primary polymorphic base of `android::Surface`, so `ANativeWindow` is not at offset 0 and a `void*` cast lands on the wrong bytes).
- **Decision:** keep and deploy it; it is harmless for the normal lipstick HWC window and is the right upstream cleanup. To settle whether it is a hard dependency, reinstall the stock `eglplatform_hwcomposer.so` and rerun the Gate 4.1 command; a successful recording demotes it from prerequisite to cleanup.

## 15. Conclusions so far (2026-09-27)

**Proven on device (Xperia 5 IV, 1080x2520):**

1. The MediaCodec input-Surface hardware AVC path (droidmedia `ScreenCaptureSurfaceEncoder`) records lipstick's display via the QPA producer at 30 fps nominal, emitting only when the screen changes (sparse PTS).
2. `screen_capture_surface_encoder_finish()` drains the codec to a real EOS in ~0.5 s; `stop()` remains the bounded forced path. Sequential use of both is clean in the standalone tool.
3. `droidscreencapsrc` (gst-droid) delivers `video/x-h264, stream-format=byte-stream, alignment=au`, one AU per buffer, PTS normalized to the first AU, monotonic, idle gaps preserved to the microsecond, SPS/PPS in-band on every IDR, duplicate-PTS AUs dropped, EOS consumed at the element so no final AUs are lost, 0 drops at 8 Mbps with `filesink`/`qtmux` downstream.
4. Container proofs: raw `.h264` (Gate 4.1) and MP4 via `qtmux`/`mp4mux` (Gate 4.2) are valid per `ffprobe`; MP4 packet timing reproduces the recording timeline including four idle gaps between 0.6 s and 1.75 s.

**Limits identified, with cause:**

5. The final-sample duration extension (Revision 4 §4.4) cannot be observed through `h264parse`: `gstbaseparse` clears upstream durations and `h264parse` recomputes 1/30 s from the SPS VUI; `qtmux` uses `GST_BUFFER_DURATION` only for the last sample. Proven at the element boundary instead (`identity silent=false`). Irrelevant to the container-less product path.
6. A separate `HEADER` SPS/PPS buffer (Revision 4 §4.5 as written) is incompatible with `h264parse → qtmux` (PTS lost). Superseded by in-band prepending.
7. Gallery playback is broken for *all* videos on this device (decoder-side stall, likely `libdroidmedia`/`gst-droid` version mismatch). Gate 4.5 is blocked on that and says nothing about the recorder.
8. The `.mkv` from the first attempt remains unclassified; low priority.

**Product direction:** the element's output contract already equals the Android Auto video payload (Annex-B AUs with PTS, self-contained IDRs). Containers and RTP are proofs and transports, not part of the element. Remaining element work for the live path is a low-latency mode (no duration lookahead) and, later, encoder parameter control (IDR request, bitrate change) if the head-unit protocol needs it.

## 16. QPA: capture initialisation scoped to recording processes (working tree, not yet built)

On `hwenc` as committed, `HwComposerBackend::create()` passes `initLegacyHwComposerQuirks()` at the three HWC2 sites where upstream deliberately passes `NULL`. That was done to resolve the libminisf capture symbols, but it also runs `eglGetDisplay(EGL_DEFAULT_DISPLAY)` and `startMiniSurfaceFlinger()` in **every** process that loads the plugin, and `startMiniSurfaceFlinger()` now always calls `ScreenCaptureService::instantiate()`. Any second process using the plugin therefore registers (and, `addService` being a replace, can take over) `sailfish.screencap`.

`startMiniSurfaceFlinger()` itself is required in the capture process: it is the only place `sailfish.screencap` is registered (`minisfservice` does not) and it starts the Binder thread pool that serves it. The QPA bridge finds the recorder's producer through that service.

**Change** (`hwcomposer/hwcomposer_backend.cpp`): symbol resolution is split into `resolveMinisfScreenCaptureApi(void *libminisf)`; the three HWC2 sites call a new `initScreenCaptureQuirks()`, which

- returns `NULL` unless `QPA_HWC_SCREENCAP` is `1`/`true` (same spelling as the mode check in `HwComposerBackend_v20`), so a non-recording process behaves exactly like upstream;
- otherwise `android_dlopen("libminisf.so")`, resolves the capture symbols and calls `startMiniSurfaceFlinger()`.

`initLegacyHwComposerQuirks()` keeps its original behaviour for the HWC v0/v1.x paths and now calls the shared resolver. No new requirement: `HwComposerBackend_v20` already reads `QPA_HWC_SCREENCAP` once at startup. The one behavioural difference from committed `hwenc` in the capture process is that `eglGetDisplay(EGL_DEFAULT_DISPLAY)` is no longer called early (upstream does not call it on HWC2 either).

The `QPA_HWC_SCREENCAP*` variables belong in lipstick's environment only, not in a system-wide environment file. `/var/lib/environment/compositor/*.conf` is also read by the encryption ask-password UI (it runs before lipstick), so use a lipstick drop-in instead:

```ini
# /etc/systemd/user/lipstick.service.d/51-screencap.conf
[Service]
Environment=QPA_HWC_SCREENCAP=1
Environment=QPA_HWC_SCREENCAP_SOURCE=1
Environment=QPA_HWC_SCREENCAP_FLIP_Y=1
# Environment=QPA_HWC_SCREENCAP_DEBUG=1   (per-frame logging; presence-checked, =0 also enables)
```

`FLIP_Y` and `DEBUG` are presence-checked; `FRAME_SKIP` (default 1), `FRAME_LIMIT` (default 0 = unlimited) and `FPS` (default: recorder session) are diagnostics.

**To validate:** rebuild and deploy `qt5-qpa-hwcomposer-plugin`, rerun the Gate 4.1 command, and confirm lipstick logs `screencap: post-swap HWC source enabled` and picks up the recorder session.

## 17. Open items before Gate 4 can close

- Streaming variant B (RTP, proves timing on a host player).
- Element tail-duration proof: `droidscreencapsrc … ! identity silent=false ! fakesink`, confirm the last buffer's duration ≈ time from final AU to Ctrl-C.
- Gates 4.3 (lifecycle/sequential sessions) and 4.4 (slow downstream, keyframe recovery).
- Deferred: device decoder stall (Section 12); `.mkv` classification; `low-latency` property.

## 18. Redeployed `hwenc` set — raw-over-TCP works (2026-09-28)

Deployed: droidmedia, droidmedia-devel, `gstreamer1.0-droid`, `qt5-qpa-hwcomposer-plugin` (hwenc builds); capture variables set through the lipstick drop-in (Section 16). **libhybris `8ac75ab` not deployed** — stock `eglplatform_hwcomposer.so`.

- Streaming variant A (raw Annex-B over `tcpserversink`, Section 13) plays on the host. The earlier stall is not reproduced.
- Section 14 settled: with stock libhybris capture works, so `8ac75ab` is a correctness cleanup, not a prerequisite. It stays in the review set.
