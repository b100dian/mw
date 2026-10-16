In this mw repo (parent folder) of 3 submodules, you find this subfolder wiki/ with a first discussion with an agent hwc-encoder-discussion.md followed by another one hwc-encoder-discussion1.md and then hwc-h264-encoding* are plans, (original, reision1, revision2 etc) and hwc-h264-exec* are executions (1, 2, 3) etc.

The three sumbodules currently are on a branch called `hwenc`. One can compare that branch with their master to see what has changed.

Building is done manually with me entering PlatformSDK or Android croot respetively (e.g for droidmedia) and testing is done manually on the device.

All commits in this repository and in all submodules are done by me.

The last document now is cleanup-plan.md: the cleanup of the `hwenc` branches into reviewable commits (pre-cleanup heads tagged `hwenc-gate4`), with the notes of that session, including the stale-last-frame fixes and the open items. Before it, hwc-h264-encoding-revision4.md was the plan and hwc-h264-exec4.md its execution log. The overview of the current state is ../README.md.

The next goal, Android Auto compatible resolutions (Option A mirror/letterbox for testing, Option B2 nested car compositor as the final solution, plus a removal list for the next refactor), is planned in auto-goal1.md.
