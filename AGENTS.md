# AGENTS.md

Read [`wiki/init.md`](wiki/init.md) first: it describes this repository, its three submodules
(branch `hwenc`, compared against `master`), the wiki documents in order, and the house rules.
[`README.md`](README.md) is the overview of the current state; build commands are in
[`wiki/building.md`](wiki/building.md).

## Rules
- Never commit, in `mw` or in any submodule: the user makes all commits.
- Builds and device tests are manual. Don't run `sfossdk`, `sb2` or the HADK build; give the
  user the exact command for `sfossdk` or `croot`. Host-only checks are in `wiki/building.md`.
- The change under review is `master..hwenc` per submodule, squashed into one commit each.
  Keep that diff small and the submodule trees free of build artifacts.
- Comments describe the current code, never its history (no gate numbers, "instead of",
  "as before"). Keep them to 1–2 lines on non-obvious constraints. History goes in `wiki/`
  and commit messages.
- Reuse what exists before adding helpers or types. The untracked sibling checkouts in `mw/`
  (`gstreamer/`, `lipstick/`, `qtmultimedia/`, ...) are for reference only, not part of the change.
- Style: `droidmedia` 2-space indent; `gst-droid` `gst-indent`; `qt5-qpa-hwcomposer-plugin`
  4-space Qt style. New files: `Jolla Ltd.` copyright and the repository's license header.
- A change to device behaviour updates `wiki/checklist.md`.
