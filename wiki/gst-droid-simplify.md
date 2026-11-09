# Simplify `droidscreencapsrc` (gst-droid `hwenc`)

**Date:** 2026-11-09
**Basis:** the squashed review commit of gst-droid (`hwenc-review` `752627a`, same tree as `hwenc` `5233a05`)
**Status:**
- Part 1 is the plan. Part 2 (§E) is its execution: all steps are done in the working trees, unstaged. Nothing is committed.
- Host checks pass (§E.4). The device run has not run yet (§E.5).

---

# Part 1: Plan

## Context

The gst-droid change under review is one squashed commit on `hwenc-review` (`752627a`, same tree
as `hwenc` `5233a05`): 5 files, +1166/−2, almost all of it
`gst/droidscreencapsrc/gstdroidscreencapsrc.{c,h}`.

The element works, but it carries state and code from earlier gates that the current design no
longer needs: 8 boolean flags, 5 counters used only in log lines, a second SPS/PPS mechanism,
and 25 lines of prototypes. A reviewer has to work out which of these still matter. The review
also found one bug in the pause path (step 3).

Goal: the same element, with the same properties and output, in about 150 fewer lines
(estimate) and with 16 state fields instead of 24.

Work in the `gst-droid` working tree on `hwenc`, unstaged. The user commits and re-runs
`scripts/squash-hwenc-review.sh` to rebuild `hwenc-review`.

## Files

- `gst-droid/gst/droidscreencapsrc/gstdroidscreencapsrc.c` (all steps)
- `gst-droid/gst/droidscreencapsrc/gstdroidscreencapsrc.h` (remove the dropped fields)
- `droidmedia/droidmediascreencapture.h` (one comment line, step 2)
- `README.md`, `wiki/checklist.md`, `wiki/init.md`, new `wiki/gst-droid-simplify.md`

`meson.build`, `plugin.c` and the squash script's commit message stay as they are.

## Step 1: remove what is redundant (no behaviour change)

1. **Order the file like `gstdroidvenc.c`:** helpers first, `init` and `class_init` last. The
   prototype block (lines 159–183) goes. `stop()` sits above `start()` (see 1.6).
2. **`signal_eos` callback:** remove the function and leave `cb.signal_eos` NULL (droidmedia
   checks it). It sets `eos` while `create()` is blocked inside
   `droid_media_screen_capture_finish()`, and `create()` sets `eos` itself when that returns.
3. **`finish_started`:** remove. After the finish, `eos` is always TRUE and is tested first.
4. **`running`:** remove. In `data_available()` it is always paired with `flushing` (step 3
   removes that test too). In `send_event()` use `src->capture != NULL`: `send_event()`,
   `start()` and `stop()` all run under the element's state lock.
5. **`start()`:** remove the `target_bitrate <= 0 || fps <= 0` check; both properties have a
   minimum of 1. The width/height check stays (default 0).
6. **`start()` failure path:** after a failed `droid_media_screen_capture_start()`, call
   `gst_droidscreencapsrc_stop (bsrc)` instead of repeating its three lock blocks.
7. **`do_finish()`:** fold into `create()`. Drop its `if (src->capture)` test: `create()` only
   runs between `start()` and `stop()`. Resulting loop order: flushing, pop, error, `eos`,
   `eos_requested` (unlock, finish, lock, `eos = TRUE`, continue), wait.
8. **`get_caps()`:** start from the pad template caps and add `width`, `height` and
   `framerate` with `gst_caps_make_writable()` + `gst_caps_set_simple()` when the size is set.
   The format strings then exist once, in the template.
9. **Counters:** keep `frames_out` and `dropped_frames` for the one summary line in `stop()`.
   Remove `dropped_bytes`, `overload_episodes` and `duplicate_pts_frames`, and shorten the
   overflow and resume warnings to match. Keep the `requested a key unit` and `pushing` lines
   unchanged: checklist step 4 greps them.
10. **`error_posted`:** remove. GstBaseSrc posts its own error on every `GST_FLOW_ERROR`, so
    a repeat of ours after a restarted task adds nothing.
11. **Allocation check:** remove the `buf == NULL` / `-ENOMEM` branch.
    `gst_droid_codec_prepare_encoded_data()` (`gst-libs/gst/droid/gstdroidcodec.c:374`) does
    the same allocation without one.
12. **`finalize()`:** only free the queue and clear the locks. `stop()` leaves the run state
    reset.

## Step 2: one SPS/PPS mechanism

droidmedia configures the encoder with `prepend-sps-pps-to-idr-frames`. On this Android base
`configure()` fails when the encoder can't do that (`CCodec.cpp:1361–1368`,
`ACodec.cpp:1877`), and then `droid_media_screen_capture_new()` returns NULL. So every IDR
already starts with the SPS/PPS, and the element's own copy is never used.

- Remove `config_data`, `config_size`, the `memcmp()` test and the prefix in `wrap_locked()`.
- `data_available()` returns early for `codec_config`, with the existing reason as the comment
  (alone, the header becomes an access unit without PTS in `h264parse`, which `qtmux` rejects).
- Inline what is left of `wrap_locked()`: allocate, fill, set `DELTA_UNIT` unless `sync`.
- `droidmediascreencapture.h`, at `data_available`: add that every sync frame starts with the
  SPS/PPS. The element now relies on it.

## Step 3: fix pause, and one queue bound

- **Pause bug.** GstBaseSrc 1.26 calls `unlock()` on PLAYING→PAUSED and `unlock_stop()` only at
  the next `create()` (`gstbasesrc.c`, `gst_base_src_set_playing()` and `retry_create`). So
  `flushing` stays TRUE for the whole pause, `data_available()` drops every frame, and after
  resume the stream continues with delta frames whose reference was dropped, until the next
  periodic IDR.
  - Fix: `data_available()` no longer tests `flushing`; only `error`. Frames are queued during
    a pause, and the existing overflow handling (drop, wait for IDR, request one) keeps the
    queue decodable. `stop()` clears the queue after the encoder has stopped, as today.
  - Cost: while paused with a busy screen, one overflow warning and one forced IDR per 30
    frames.
- **Queue bound:** 30 frames only. Remove `OUTPUT_QUEUE_MAX_BYTES` and `queue_bytes`. 30 frames
  is half a second of stream at 60 fps, about 0.5 MB at the default bitrate.

## Left out on purpose

- **`level` property and its table** (about 55 lines): tested in Gate 5.2 and part of the
  Android Auto goal. Removing it is possible (the encoder computes 3.1 for 720p30 and 3.2 for
  720p60 by itself) but it removes a feature, not complexity.
- **`GstForceKeyUnit` through `send_event()`** (about 15 lines): documented in the README. The
  checklist only uses the downstream path.
- **`gst_video_event_is_force_key_unit()`:** `gate-5.md` §1.2 decided against linking
  libgstvideo for it.
- **`G_DECLARE_FINAL_TYPE`, `GstDataQueue`:** the other gst-droid elements use the old macros
  and a plain `GQueue`; the gain is small.
- **PTS from 0 instead of pipeline running time:** a reviewer may ask, but it is the documented
  contract and changing it is not a simplification.

## Docs

- `README.md`, "Overload": `a bound of 30 frames`.
- `wiki/checklist.md`, "Not covered yet": add pause and resume (PLAYING → PAUSED → PLAYING
  gives a stream that decodes without a break).
- New `wiki/gst-droid-simplify.md`: this plan, then the execution notes and host results. Add
  it to `wiki/init.md` and the README wiki map.
- Comments in the code describe the result only (no "no longer", no gate numbers).

## Verification

Host, from `mw/` (`wiki/building.md`):
```sh
gcc -fsyntax-only -Wall -W $(pkg-config --cflags gstreamer-1.0 gstreamer-base-1.0) -Idroidmedia gst-droid/gst/droidscreencapsrc/gstdroidscreencapsrc.c
git -C gst-droid diff --stat master
grep -n "running\|finish_started\|error_posted\|config_data\|queue_bytes\|signal_eos" gst-droid/gst/droidscreencapsrc/*
```
- Syntax check clean; the grep prints nothing; diff stat compared with +1166/−2.
- Indent: GNU indent with the gst-indent options, as in `gate-5-tweaks-exec.md` §4.
- Host smoke test with droidmedia stubbed (as for `content-rect` in `gate-5-tweaks-exec.md`
  §4): a stub that feeds access units from a thread. Check start, EOS drain (`gst-launch -e`),
  an injected error, overflow behind a slow sink, and PAUSED → PLAYING.

Device (the user builds and runs):
```sh
# PlatformSDK
rpm/dhd/helpers/build_packages.sh -b hybris/mw/gst-droid
```
Install per `wiki/building.md` "On the device", then `wiki/checklist.md` steps 3 (inspect),
4 (key units), 7–9 (recordings, `ffprobe`, Gallery: these prove the SPS/PPS on every IDR),
10 (levels, content rect), 11 (join a running stream) and 14 (recorder killed). droidmedia
needs no rebuild for its comment line.

---

# Part 2: Execution (2026-11-09)

## E.1 What changed

| | Before | After |
|---|---|---|
| gst-droid, `git diff --stat master` | 5 files, +1166/−2 | 5 files, +940/−2 |
| `gstdroidscreencapsrc.c` | 1028 lines | 811 lines |
| `gstdroidscreencapsrc.h` | 104 lines | 95 lines |
| State fields (from `capture_lock` down) | 24 | 15 |
| Helper functions (not vfuncs or callbacks) | 11 | 6 |
| droidmedia callbacks | 3 | 2 |

- The 15 fields: `capture_lock`, `capture`, `output_lock`, `output_cond`, `output_queue`, `have_first_pts`, `first_ts`, `last_ts`, `waiting_for_keyframe`, `dropped_frames`, `flushing`, `eos_requested`, `eos`, `error`, `frames_out`. The plan's 16 was a miscount: it removes 9 of the 24.
- The 6 helpers: the profile and target enum types, the level table, `set_error_locked()`, and `is_force_key_unit()` and `force_key_unit()`, which the two event handlers share.
- `gst-inspect-1.0 droidscreencapsrc` prints the same text for the old and the new element (host builds, §E.4).
- droidmedia: the one comment at `data_available` in `droidmediascreencapture.h`.
- Docs: `README.md` (overload bound, a "Pause" line, the EOS line of the sequence diagram, the "not yet run" list, the wiki map), `wiki/checklist.md` ("Not covered yet"), `wiki/init.md`.

All of steps 1, 2 and 3 are done as planned, except for the points in §E.2.

**Log lines.** Unchanged: `requested a key unit`, `pushing`, `timestamp origin`, `EOS requested`, `finishing encoder`, `EOS after`, the error lines. Changed:

| Before | After |
|---|---|
| `output queue bound reached (… limits 30/8388608): episode N, dropping …` | `output queue full: dropping N frames and discarding until the next keyframe` |
| `overload episode N ended: dropped N frames / N bytes; resuming at keyframe PTS …` | `resuming at keyframe PTS …, N frames dropped in this run` |
| `run summary: N frames pushed, N overload episodes, N frames dropped, N duplicate-PTS frames discarded` | `run summary: N frames pushed, N dropped` |
| `stopping during overload episode N: …` | removed |
| `retained codec config (N bytes)` | removed |
| `started: … queue bound 30 frames / 8388608 bytes` | `started: … queue bound 30 frames` |

## E.2 Deviations from the plan

All of them remove more, for reasons found while reading `gstbasesrc.c` (1.26.11, `mw/gstreamer`).

1. **`enqueue_locked()` is inlined as well** (the plan only inlines `wrap_locked()`). With `queue_bytes` gone it took a buffer only to unref it on overflow, and `data_available()` read `waiting_for_keyframe` back to learn that it had happened. Now `data_available()` tests the queue length first, and allocates the buffer only if it is queued.
2. **`clear_queue_locked()` and `reset_run_state_locked()` are gone.** The queue is cleared with `g_queue_clear_full()` (GLib 2.60; GStreamer 1.26 needs 2.64). The reset is 7 assignments at the end of `stop()` and nowhere else: a new object is zero-filled and `stop()` leaves the state reset, so `start()` and `finalize()` need none. `first_ts` and `last_ts` are not reset: `have_first_pts` guards them.
3. **`flushing` is written by `unlock()` and `unlock_stop()` only.** `start()` and `stop()` set it before. `gst_base_src_stop()` calls `unlock_stop()` before the `stop()` vfunc ("this will balance unlock/unlock_stop calls"), also after a pause, so it is FALSE whenever `stop()` and `start()` run.
4. **`stop()` has no `if (src->capture)` and no lock block before it stops the encoder.**
   - GstBaseSrc calls the `stop()` vfunc only with `STARTED` or `STARTING` set, and a failed `start()` clears `STARTING` without a `stop()` (`could_not_start`: "We don't have to call _stop"). So `stop()` only follows a `start()` that set `capture`. The failure path inside `start()` (plan 1.6) calls it after setting `capture` too.
   - The streaming task is joined before `stop()`, so nothing waits on `output_cond` then, and the first lock block (`running = FALSE`, `flushing = TRUE`, broadcast) had no reader left.
   - The summary line is logged after the encoder has stopped, so it includes what was dropped while stopping.
5. **The `stopping during overload episode` warning is removed** with the episode counter. The summary line has the dropped count.
6. **`EOS requested` is logged for every EOS event**, not only the first: the `if (!src->eos_requested)` around it only served the log.
7. **README:** two additions outside the plan's list, because they describe changed behaviour: the "Pause" line in the element notes, and `signal_eos` replaced in the sequence diagram (droidmedia still offers the callback; the element doesn't set it).

After a failed `droid_media_screen_capture_start()`, the log now has a `run summary: 0 frames pushed, 0 dropped` line from the shared `stop()`.

## E.3 Findings, not changed

Three behaviours showed up in the host tests. All are the same in the old element; none is part of this plan.

1. **EOS while PAUSED takes GstBaseSrc's path.** `flushing` is TRUE during a pause, so `send_event()` passes the EOS to GstBaseSrc. The EOS message then comes after the resume, without `finish()`: the encoder is not drained and the frames queued during the pause are not pushed. Removing the `!src->flushing` test in `send_event()` would let `create()` drain after the resume.
2. **A pause can lose one access unit in GstBaseSrc.** If the pause arrives between `create()`'s `flushing` test and its return, GstBaseSrc drops the returned buffer (`gst_base_src_get_range()`: "no need keep old buffer while in pause"). The following delta frames then have no reference until the next IDR (1 s at most, `i-frame-interval` 1). The window is a few microseconds per frame, and the host tests never hit it. A fix would be to restart from an IDR at the first `create()` after a pause.
3. **A sink with `sync=true` after a pause.** The PTS stay on the capture clock while the pipeline's running time stops for the pause, so after the resume every buffer is early by the length of the pause and the sink waits for it.
   - If the pause was longer than the queue (0.5 s at 60 fps), the queue overflows for the rest of the run: one IDR is pushed about every 0.5 s and nothing else.
   - `create()` handles `eos_requested` only when the queue is empty, and here it never is, so the EOS does not complete (host: no EOS in 8 s). The same applies to any sink that stays slower than the screen.
   - The documented pipelines use `sync=false` sinks or files and are not affected. This belongs to "PTS from 0" in "Left out on purpose".

## E.4 Host checks

**Static:**
- `gcc -fsyntax-only -Wall -W` (GStreamer 1.28.7 and GLib 2.88 headers): clean.
- The plan's `grep` prints nothing.
- **Indent:** GNU indent with the classic gst-indent options changes 19 lines of the `.c` file, all of them the `Type * p` spacing in function headers (25 lines in the old file), and nothing in the `.h` file.

**Smoke test with droidmedia stubbed.** The harness is in `/tmp/dscs-host`, not in the repository:
- `stub/stub.c` implements the seven `droid_media_screen_capture_*` functions. A thread sends a `codec_config` buffer and then 60 fake access units per second: an IDR every 60 frames and after each `request_sync_frame()`, each IDR with SPS and PPS NALs in front, every frame with its sequence number. `finish()` delivers 3 more frames and joins the thread. Environment variables inject failures.
- `check.py` reads the sink's file: every delta frame must follow the frame with the previous number (otherwise a decoder has no reference: a "break"), and every IDR must start with SPS and PPS.
- The same stub is built into two plugins, with the old and the new element source. `run.sh` uses `gst-launch-1.0 -e`; `driver.py` (PyGObject) does the state changes and events.

| Scenario | New element | Old element |
|---|---|---|
| Start, 2 s, Ctrl-C (`gst-launch -e`) | 111 generated, 111 in the file, the 3 of `finish()` included; `EOS after 111 frames`; caps `video/x-h264, stream-format=byte-stream, alignment=au, width=64, height=64, framerate=60/1` | 110 generated, 110 in the file; the same caps |
| Encoder error after 50 frames | 50 frames in the file, then `Screen capture encoder failed` once and GstBaseSrc's `Internal data stream error` once; exit 1 | the same |
| Slow sink (`identity sleep-time=50000`), 4 s | 282 generated, 96 pushed, 186 dropped, 6 overflow/resume warning pairs, 6 sync requests, 0 breaks, EOS | the same numbers |
| **PLAYING 1 s → PAUSED 2 s → PLAYING 1 s → EOS** | 149 frames, **0 breaks**; during the pause 3 overflow/resume pairs, 0.5 s apart | 123 frames, **1 break**: `delta 179 after 59` |
| PLAYING → PAUSED → NULL → PLAYING → EOS | both runs start at PTS 0 and frame 0, 0 breaks | the same |
| `GstForceKeyUnit` to the element before start, to the element, from the sink pad | accepted and ignored; +1 IDR; +1 IDR; `requested a key unit` twice | the same |
| EOS while PAUSED | no EOS in the pause, EOS after the resume, without drain (§E.3.1) | the same |
| `start()` fails: encoder start, encoder create, content rect, no width, `level` without profile | state change fails with the element's message; NULL; the next start works | the same |
| First IDR sent twice; a regressing ts; `finish()` returns false | the repeat is dropped; error after 20 frames; EOS with a warning | the same |
| `fakesink sync=true`, PLAYING 1 s → PAUSED 1 s → PLAYING | §E.3.3 | the same |

- The slow-sink scenario and all `driver.py` scenarios also ran with the element and the stub built with `-fsanitize=address,undefined`, the slow-sink one with `GST_TRACERS=leaks` too: no ASan or UBSan error, no leak with a frame in the element or the stub, no GStreamer object alive at exit. (valgrind does not run on this host: its ld.so redirection fails.)

## E.5 Build and device run

Not done yet. The user builds and runs:
```sh
# PlatformSDK
rpm/dhd/helpers/build_packages.sh -b hybris/mw/gst-droid
```
- Install per `building.md` "On the device" (`zypper in -f`), then `checklist.md` steps 3, 4, 7–9, 10, 11 and 14.
- Steps 7–9 are the ones that matter for step 2 of the plan: `ffprobe` and Gallery need the SPS/PPS in every IDR, which now come from the encoder alone.
- droidmedia needs no rebuild for its comment. A later `droidmedia-devel` build picks up the header.
- Pause and resume is not a checklist step yet ("Not covered yet"). A device check would be a small program or `gst-launch` replacement that pauses a `tcpserversink` stream; `gst-launch-1.0` cannot pause.

Results go here, by checklist step number.
