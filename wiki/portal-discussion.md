# XDG ScreenCast/RemoteDesktop portal for Sailfish: discussion

**Date:** 2026-11-08
**Status:** Discussion only. Nothing is implemented, and the work comes **after B2**. It is written down
now because one decision (§8) shapes B2's session contract.
**Basis:** `auto-goal1.md`, `lipstick-recorder-comparison.md`, `../README.md`

Sailfish has no screen-capture door for ordinary apps. A browser's `getDisplayMedia`, a video call
or a Flatpak app expects the XDG ScreenCast portal and PipeWire, and both are packaged for Sailfish.
Two goals:
- a **generic app API**: any app can capture, with the user's consent;
- a **front door for B2**: the car compositor as a portal `VIRTUAL` source, and RemoteDesktop input
  into `remotetouch`.

The portal comes in addition to B2. It does not replace B2.

## 1. Portals in brief

- **Frontend and backend:** `xdg-desktop-portal` (the frontend) owns the public D-Bus API
  (`org.freedesktop.portal.*`) and the permission store. A desktop-specific backend implements
  `org.freedesktop.impl.portal.*`. The piece to write is a **Sailfish backend** for
  `impl.portal.ScreenCast` and `impl.portal.RemoteDesktop`.
- **ScreenCast flow:** `CreateSession` → `SelectSources` (types `MONITOR`, `WINDOW`, `VIRTUAL`;
  cursor mode) → `Start`, where the backend shows its picker and returns the PipeWire node IDs
  → `OpenPipeWireRemote`, which gives the app a PipeWire fd that can only see those nodes.
- **PipeWire frames** are raw: `SPA_DATA_MemFd` (shared memory) or `SPA_DATA_DmaBuf` with a DRM
  modifier. The format, size and framerate are negotiated between the node and the consumer.
- **RemoteDesktop** shares the ScreenCast session and adds input: `NotifyPointer*`, `NotifyKeyboard*`
  and `NotifyTouchDown`/`Motion`/`Up` in stream coordinates. Newer frontends also offer an EIS
  socket (`ConnectToEIS`, libei) in place of the `Notify*` calls.

## 2. Why in addition to B2

B2 produces a **separate UI** as zero-copy **hardware H.264** for an Android Auto head unit. A portal
consumer wants **raw frames** and encodes them itself (WebRTC picks its own codec, bitrate and
keyframes). The two paths share the session machinery and the renderers, not the output.

## 3. Mapping

| Portal source | `sailfish.screencap` session | Renderer | Stream |
|---|---|---|---|
| `MONITOR` | `DISPLAY` | lipstick (the QPA blitter) | raw RGBA |
| `VIRTUAL` | `VIRTUAL` | B2 car compositor (QPA encoder backend) | raw RGBA or hardware H.264 |
| `WINDOW` | — | out of scope: lipstick has no per-window capture | — |

## 4. Frame path

The backend is **one more `sailfish.screencap` client**, as a recorder is today: it registers a
producer with a session (`registerProducer`, `droidmedia/screen_capture_service.h:84–87`), and the
renderer attaches to it.
- **Raw:** the producer is a `DroidMediaBufferQueue` (`droidmedia/droidmedia.h:99–124`, as the camera
  and the decoder use it), not the encoder's input Surface. Lipstick's blitter and B2 render into
  it unchanged. droidmedia has no public constructor for a standalone queue yet; the class has one
  and exposes its window (`droidmedia/private.h:66–76`), so this needs one new entry point.
- **Size:** the session has the negotiated size, so the renderer downscales on the GPU, as Option A
  already does (auto-goal1 §3.2).
- **MemFd copy:** one locked copy per frame (`droid_media_buffer_lock` → the PipeWire buffer) in the
  backend process, never in lipstick. At 720p30 RGBA that is about 110 MB/s. lipstick2vnc instead
  does a full-panel `glReadPixels` on lipstick's render thread (`lipstick-recorder-comparison.md`).
- **DMA-BUF:** only `DRM_FORMAT_MOD_LINEAR`, and only for consumers that mmap it. There is no Mesa
  EGL/GBM import on hybris, so a GPU import on the consumer side is not available.
- **H.264 for `VIRTUAL`:** the encoder Surface as today (zero copy), with each AU as one PipeWire
  buffer (`video/x-h264` caps). PipeWire has no standard keyframe request, so the **Android Auto
  transport stays on the droidmedia API**, which has `request_sync_frame` (auto-goal1 §2.1).

## 5. Input

- **`VIRTUAL`:** RemoteDesktop touch on the stream maps 1:1 to `d`/`m`/`u` lines into the
  `remotetouch` FIFO (auto-goal1 §4.5): stream coordinates are codec coordinates.
- **`MONITOR`:** would need a uinput touchscreen that lipstick reads through evdev, as for Option A
  input (auto-goal1 §3.5). Not planned.

## 6. Spike idea

Before any backend code: a raw-screen GStreamer source → `pipewiresink mode=provide`. A PipeWire
node then exists, and `pw-dump`, `gst-launch-1.0 pipewiresrc` or a browser test page can show
whether the consumers on Sailfish accept MemFd RGBA at the expected rate.

## 7. Hardware encoding in consumers (VA-API)

- **None on hybris:** libva needs a driver for the GPU or VPU, and the Linux ones (Intel, Mesa) don't
  apply where Android blobs drive the hardware. No VA driver exists for it.
- **Writing one** over droidmedia is a model mismatch: VA encode is per picture (the app supplies
  parameters, references, headers), and MediaCodec is frames in, AUs out with its own GOP. That is
  enough for ffmpeg `h264_vaapi` or GStreamer `va`, but not for apps that manage references (WebRTC
  LTR, temporal layers). VA surfaces as DRM PRIME would also need gralloc → dma-buf plus a Linux
  modifier, and UBWC has none here.
- **Kernel V4L2:** the HADK tree's `kernel/sony/sm8450-modules/qcom/opensource/video-driver`
  (`msm_vidc`) is a V4L2 encoder with `V4L2_CID_MPEG_VIDEO_FORCE_KEY_FRAME`, NV12/RGBA input
  (`driver/vidc/src/msm_vidc_driver.c:561–615`) and dma-buf import. `v4l2h264enc` could use it
  directly, without VA. Unverified: a vendor driver, `/dev/video*` is `0660 system:camera`
  (`device/sony/sm8450-common/rootdir/ueventd.rc:146`), and Codec2 shares the hardware.
- **For the portal:** encoding is the consumer's side, so the backend design is unchanged. A consumer
  without hardware encode pays software encoding. A VA shim would not be zero copy for portal frames
  anyway (MemFd copy, then upload to a VA surface), unlike the encoder Surface in §4. Browser
  PipeWire capturers take raw frames only, so the H.264 portal format serves our own `pipewiresrc`
  pipelines, and the zero-copy hardware path stays droidmedia's.

## 8. Effects on B2 (decided)

- **One session per target** in `sailfish.screencap`: at most one `DISPLAY` and one `VIRTUAL`
  session at a time (today: one session in total, auto-goal1 §2.3). Each listener follows only its
  own target, and the generation is per target. So a portal `MONITOR` capture and an Android Auto
  `VIRTUAL` session can run together. This goes into the B2 session contract.
- **Resize:** a portal virtual monitor at another size restarts the compositor unit (auto-goal1
  §4.3), until the compositor can resize.

## 9. Open points

1. **Consent UI:** a Silica picker in the backend (which source, remember the choice), and how it is
   shown over lipstick.
2. **Access:** restrict `sailfish.screencap` to privileged clients (recorder, AA transport, the
   portal backend), so the portal is the only door for apps.
3. **Sailfish Browser:** is Gecko embedlite built with the libwebrtc PipeWire desktop capturer, and
   does it call the portal for `getDisplayMedia`?
4. **Versions:** which `xdg-desktop-portal` (ScreenCast/RemoteDesktop interface versions, EIS) and
   which PipeWire version the Sailfish packages ship.
5. **Consumer-side hardware encoder:** the `msm_vidc` V4L2 encoder from userspace (`v4l2h264enc`),
   a separate spike (§7).
