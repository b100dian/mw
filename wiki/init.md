In this mw repo (parent folder) of 3 submodules, you find this subfolder wiki/ with a first discussion with an agent hwc-encoder-discussion.md followed by another one hwc-encoder-discussion1.md and then hwc-h264-encoding* are plans, (original, reision1, revision2 etc) and hwc-h264-exec* are executions (1, 2, 3) etc.

The three sumbodules currently are on a branch called `hwenc`. One can compare that branch with their master to see what has changed.

Building is done manually with me entering PlatformSDK or Android croot respetively (e.g for droidmedia) and testing is done manually on the device.

All commits in this repository and in all submodules are done by me.

Code comments describe the current state, not the timeline that led to it: reviewers read the squashed `master..hwenc` diff and never see the intermediate versions (e.g. no "no Binder call" or "instead of polling" once polling is gone). History goes in the wiki logs and commit messages.

The last document now is cleanup-plan.md: the cleanup of the `hwenc` branches into reviewable commits (pre-cleanup heads tagged `hwenc-gate4`), with the notes of that session, including the stale-last-frame fixes and the open items. Before it, hwc-h264-encoding-revision4.md was the plan and hwc-h264-exec4.md its execution log. The overview of the current state is ../README.md.

The next goal, Android Auto compatible resolutions (Option A mirror/letterbox for testing, Option B2 nested car compositor as the final solution, plus a removal list for the next refactor), is planned in auto-goal1.md. Its first step, everything the upstream repositories need (encoder profile and keyframes, the session contract, Option A, the B2 spike), is gate-5.md, and gate-5-exec.md is its execution log.

After gate-5-exec.md, gate-5-tweaks.md prepares the `master..hwenc` diff for review: comment cleanup, reuse of existing types, and a smaller diff. gate-5-tweaks-exec.md is its execution log, with the deviations from that plan and the host test results. Build notes for PlatformSDK, HADK and the host are in building.md.

portal-discussion.md is a discussion for after B2: an XDG ScreenCast/RemoteDesktop portal backend on the `sailfish.screencap` sessions.

android-screen-encoders.md is background: how Android's Stagefright recorder, `screenrecord` and the Miracast source encode the screen, compared with `droidscreencapsrc`. The ideas it leads to are in improvement-ideas.md.

generic-hwenc-no-screen.md is a discussion for after the review: hardware encoding of frames that are not the screen (raw CPU frames through upstream droidmedia, as gecko-camera does; a raw-input droidvenc; textures via the Surface; ffmpeg), with sample transcode pipelines.

The device run after every deploy is checklist.md. A change that adds or alters device behaviour updates its steps in the same change; the results go in the exec log of the build under test, by step number.
