#!/usr/bin/env bash
#
# squash-hwenc-review.sh
#
# Squashes the full diff of the hwenc branch into a single review commit
# on branch 'hwenc-review' for each of the three submodules:
#   - mw/droidmedia
#   - mw/gst-droid
#   - mw/qt5-qpa-hwcomposer-plugin
#
# Preserves the full history of the hwenc branches untouched.
# Idempotent: can be executed repeatedly as hwenc evolves.
# Also updates the mw superproject's hwenc-review branch with the new tips.
#
# Safety features:
# 1. Working tree cleanliness pre-flight check (prevents silent omission of uncommitted work).
# 2. Safe synchronization if 'hwenc-review' is currently checked out.
# 3. Automatic timestamped backups of existing 'hwenc-review' branches before overwriting.
# 4. Detection of un-backported review commits.
# 5. Safe push instructions using --force-with-lease.
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MW_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

SUBMODULES=("droidmedia" "gst-droid" "qt5-qpa-hwcomposer-plugin")
UPDATE_MW=true
ALLOW_DIRTY=false

usage() {
  cat <<EOF
Usage: $(basename "$0") [options]

Options:
  --allow-dirty  Allow squashing even if tracked files have uncommitted modifications
  --no-mw        Skip creating/updating hwenc-review branch in the mw superproject
  -h, --help     Show this help message
EOF
  exit 0
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --allow-dirty)
      ALLOW_DIRTY=true
      shift
      ;;
    --no-mw)
      UPDATE_MW=false
      shift
      ;;
    -h|--help)
      usage
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage
      ;;
  esac
done

# ==============================================================================
# Pre-flight Check: Detect Tracked Uncommitted Changes
# ==============================================================================
check_cleanliness() {
  local repo_name="$1"
  local repo_path="$2"

  local dirty_files
  dirty_files="$(git -C "${repo_path}" status --porcelain -uno)"

  if [[ -n "${dirty_files}" ]]; then
    if [[ "${ALLOW_DIRTY}" == "true" ]]; then
      echo "[WARNING] Tracked uncommitted changes detected in ${repo_name} (proceeding due to --allow-dirty):"
      echo "${dirty_files}" | sed 's/^/  /'
      echo ""
    else
      echo "=================================================="
      echo "[ERROR] Tracked uncommitted changes in: ${repo_name}"
      echo "=================================================="
      echo "${dirty_files}" | sed 's/^/  /'
      echo ""
      echo "These uncommitted changes would be SILENTLY EXCLUDED from the squashed review commit"
      echo "because 'hwenc-review' only includes commits committed to branch 'hwenc'."
      echo ""
      echo "To resolve this:"
      echo "  1. Commit your changes to 'hwenc' first, OR"
      echo "  2. Stash your changes with: git -C \"${repo_path}\" stash, OR"
      echo "  3. Re-run with '--allow-dirty' if you intentionally want to squash only committed history."
      echo ""
      return 1
    fi
  fi
  return 0
}

echo "=================================================="
echo "Pre-flight cleanliness check..."
echo "=================================================="
for sub in "${SUBMODULES[@]}"; do
  if ! check_cleanliness "${sub}" "${MW_DIR}/${sub}"; then
    exit 1
  fi
done

if [[ "${UPDATE_MW}" == "true" ]]; then
  if ! check_cleanliness "mw (superproject)" "${MW_DIR}"; then
    exit 1
  fi
fi
echo "Pre-flight checks passed."
echo ""

# ==============================================================================
# Curated Commit Messages
# ==============================================================================
get_curated_msg() {
  local repo_name="$1"
  case "${repo_name}" in
    droidmedia)
      cat <<'MSG'
Add hardware screen capture API and minisf capture service

Implement hardware-accelerated H.264 screen capture via MediaCodec surface input:
- Add DroidMediaScreenCapture API with asynchronous callbacks (data_available,
  error, signal_eos) and CLOCK_MONOTONIC nanosecond timestamps.
- Add sailfish.IScreenCaptureService hosted in minisfservice with generation
  tracking to coordinate display frame producers and the encoder consumer.
- Export droid_media_screen_capture_* through hybris.c.
- Include screencap_surface_capture_test standalone test utility.
MSG
      ;;
    gst-droid)
      cat <<'MSG'
Add droidscreencapsrc element for hardware screen capture

Implement GStreamer element droidscreencapsrc using droidmediascreencapture:
- Capture screen frames directly into GstBuffers with monotonic PTS.
- Push access units immediately as they are encoded, preserving idle gaps.
- Expose properties for width, height, target-bitrate, and nominal fps.
- Register with GST_RANK_NONE to avoid auto-selection over camera sources.
MSG
      ;;
    qt5-qpa-hwcomposer-plugin)
      cat <<'MSG'
Capture display frames for hardware screen encoding

Implement display frame capture in the HWC2 compositor backend:
- Add HwComposerScreenCapture to capture presented frames via libminisf.
- Render the current display buffer into the encoder Surface using a private
  EGL context and EGLImage texture target.
- Support display orientation and 90/270 degree rotation.
- Enable conditionally via QPA_HWC_SCREENCAP environment variable.
MSG
      ;;
    *)
      echo "Squashed hwenc changes for ${repo_name}"
      ;;
  esac
}

# ==============================================================================
# Helper: Update hwenc-review branch safely (no desynchronization or clobbering)
# ==============================================================================
safely_update_review_branch() {
  local repo_name="$1"
  local repo_path="$2"
  local new_commit="$3"
  local base_commit="$4"

  local ts
  ts="$(date +%Y%m%d-%H%M%S)"

  # 1. If hwenc-review already exists, backup and detect any un-backported commits
  if git -C "${repo_path}" rev-parse --verify --quiet refs/heads/hwenc-review >/dev/null; then
    local old_review_tip
    old_review_tip="$(git -C "${repo_path}" rev-parse refs/heads/hwenc-review)"

    # Save timestamped backup ref
    git -C "${repo_path}" update-ref "refs/backup/hwenc-review-${ts}" "${old_review_tip}"
    echo "  Backed up previous hwenc-review (${old_review_tip}) to: refs/backup/hwenc-review-${ts}"

    # Check for commits that were committed directly on hwenc-review
    local unbackported_commits
    unbackported_commits="$(git -C "${repo_path}" rev-list "${old_review_tip}" --not refs/heads/hwenc "${base_commit}" 2>/dev/null || true)"
    if [[ -n "${unbackported_commits}" ]]; then
      echo "  [NOTICE] Previous hwenc-review contained commits not in hwenc. They remain saved in refs/backup/hwenc-review-${ts}."
    fi
  fi

  # 2. Check which branch is currently checked out
  local current_head
  current_head="$(git -C "${repo_path}" symbolic-ref --quiet HEAD 2>/dev/null || true)"

  if [[ "${current_head}" == "refs/heads/hwenc-review" ]]; then
    # hwenc-review is actively checked out: update ref AND index/working-tree cleanly
    local dirty_check
    dirty_check="$(git -C "${repo_path}" status --porcelain -uno)"
    if [[ -n "${dirty_check}" ]]; then
      echo "  [ERROR] Cannot update hwenc-review while it is checked out with uncommitted changes in ${repo_name}." >&2
      echo "  Please commit, stash, or checkout hwenc before running." >&2
      return 1
    fi
    git -C "${repo_path}" reset --hard "${new_commit}"
    echo "  Synchronized checked-out working tree and index on hwenc-review."
  else
    # Any other branch is checked out (e.g. hwenc): update ref pointer only, leaves worktree untouched
    git -C "${repo_path}" update-ref refs/heads/hwenc-review "${new_commit}"
  fi
}

# ==============================================================================
# Process Submodules
# ==============================================================================
declare -A review_tips
review_count=0

for sub in "${SUBMODULES[@]}"; do
  sub_path="${MW_DIR}/${sub}"

  echo "=================================================="
  echo "Squashing submodule: ${sub}"
  echo "=================================================="

  if ! git -C "${sub_path}" rev-parse --verify --quiet refs/heads/hwenc >/dev/null; then
    echo "  [ERROR] Branch 'hwenc' not found in ${sub}. Skipping." >&2
    continue
  fi

  # Find base against master, origin/master, or github/master
  base=""
  for candidate in master origin/master github/master remotes/origin/master remotes/github/master; do
    if git -C "${sub_path}" rev-parse --verify --quiet "${candidate}" >/dev/null; then
      base="$(git -C "${sub_path}" merge-base refs/heads/hwenc "${candidate}" 2>/dev/null || true)"
      if [[ -n "${base}" ]]; then
        break
      fi
    fi
  done

  if [[ -z "${base}" ]]; then
    echo "  [ERROR] Could not determine merge-base with master in ${sub}." >&2
    continue
  fi

  tree="$(git -C "${sub_path}" rev-parse refs/heads/hwenc^{tree})"
  hwenc_tip="$(git -C "${sub_path}" rev-parse refs/heads/hwenc)"

  an="$(git -C "${sub_path}" log -1 --format="%an" "${hwenc_tip}")"
  ae="$(git -C "${sub_path}" log -1 --format="%ae" "${hwenc_tip}")"
  ad="$(git -C "${sub_path}" log -1 --format="%ad" --date=raw "${hwenc_tip}")"

  commit_msg="$(get_curated_msg "${sub}")"

  review_commit="$(
    GIT_AUTHOR_NAME="${an}" \
    GIT_AUTHOR_EMAIL="${ae}" \
    GIT_AUTHOR_DATE="${ad}" \
    GIT_COMMITTER_NAME="${an}" \
    GIT_COMMITTER_EMAIL="${ae}" \
    GIT_COMMITTER_DATE="${ad}" \
    git -C "${sub_path}" commit-tree "${tree}" -p "${base}" <<< "${commit_msg}"
  )"

  # Safely update hwenc-review
  safely_update_review_branch "${sub}" "${sub_path}" "${review_commit}" "${base}"

  review_tips["${sub}"]="${review_commit}"
  review_count=$((review_count + 1))

  echo "  Base:          ${base}"
  echo "  hwenc tip:     ${hwenc_tip}"
  echo "  hwenc-review:  ${review_commit} (single commit on top of base)"
  echo ""
done

# ==============================================================================
# Update mw superproject if enabled
# ==============================================================================
if [[ "${UPDATE_MW}" == "true" && ${review_count} -eq 3 ]]; then
  echo "=================================================="
  echo "Updating mw superproject: hwenc-review branch"
  echo "=================================================="

  mw_base_ref="refs/heads/hwenc"
  if ! git -C "${MW_DIR}" rev-parse --verify --quiet "${mw_base_ref}" >/dev/null; then
    mw_base_ref="HEAD"
  fi
  mw_base_sha="$(git -C "${MW_DIR}" rev-parse "${mw_base_ref}")"

  # Build new tree in mw updating the submodule gitlink entries
  new_mw_tree="$(git -C "${MW_DIR}" ls-tree "${mw_base_sha}" | awk -F'\t' \
    -v dm="${review_tips[droidmedia]}" \
    -v gst="${review_tips[gst-droid]}" \
    -v qt="${review_tips[qt5-qpa-hwcomposer-plugin]}" '
    {
      split($1, meta, " ");
      mode = meta[1];
      type = meta[2];
      sha  = meta[3];
      path = $2;

      if (path == "droidmedia") sha = dm;
      else if (path == "gst-droid") sha = gst;
      else if (path == "qt5-qpa-hwcomposer-plugin") sha = qt;

      print mode " " type " " sha "\t" path;
    }
  ' | git -C "${MW_DIR}" mktree)"

  mw_an="$(git -C "${MW_DIR}" log -1 --format="%an" "${mw_base_sha}")"
  mw_ae="$(git -C "${MW_DIR}" log -1 --format="%ae" "${mw_base_sha}")"
  mw_ad="$(git -C "${MW_DIR}" log -1 --format="%ad" --date=raw "${mw_base_sha}")"

  mw_review_msg="$(cat <<MSG
Review: Update submodules to hwenc-review single-commit tips

Updates submodule gitlinks for:
- droidmedia: ${review_tips[droidmedia]}
- gst-droid: ${review_tips[gst-droid]}
- qt5-qpa-hwcomposer-plugin: ${review_tips[qt5-qpa-hwcomposer-plugin]}
MSG
)"

  mw_review_commit="$(
    GIT_AUTHOR_NAME="${mw_an}" \
    GIT_AUTHOR_EMAIL="${mw_ae}" \
    GIT_AUTHOR_DATE="${mw_ad}" \
    GIT_COMMITTER_NAME="${mw_an}" \
    GIT_COMMITTER_EMAIL="${mw_ae}" \
    GIT_COMMITTER_DATE="${mw_ad}" \
    git -C "${MW_DIR}" commit-tree "${new_mw_tree}" -p "${mw_base_sha}" <<< "${mw_review_msg}"
  )"

  mw_base_upstream="master"
  safely_update_review_branch "mw" "${MW_DIR}" "${mw_review_commit}" "${mw_base_upstream}"
  echo "  mw hwenc-review branch updated -> ${mw_review_commit}"
  echo ""
fi

echo "=================================================="
echo "Review branches ready!"
echo "To push the review branches safely to your remote forks:"
echo "  git -C droidmedia push --force-with-lease b100dian hwenc-review"
echo "  git -C gst-droid push --force-with-lease b100dian hwenc-review"
echo "  git -C qt5-qpa-hwcomposer-plugin push --force-with-lease b100dian hwenc-review"
echo "  git push --force-with-lease b100dian hwenc-review"
echo ""
echo "Note: Using --force-with-lease ensures you never inadvertently"
echo "overwrite changes pushed by collaborators or remote review comments."
echo "=================================================="
