#!/usr/bin/env bash
#
# squash-hwenc-review.sh [options] [repo[:rev] ...]
#
# Publishes the work on branch 'hwenc' of the submodules droidmedia, gst-droid and
# qt5-qpa-hwcomposer-plugin on their branch 'hwenc-review'.
#
# Default: everything new on hwenc (or <rev>) since the last sync becomes one commit on top of
# hwenc-review, so the published branch only ever fast-forwards and is pushed without force.
# --squash: rebuild hwenc-review as one commit on master (rewrites published history).
#
# The hwenc history is never touched. Nothing is pushed.
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MW_DIR="${MW_DIR:-$(cd "${SCRIPT_DIR}/.." && pwd)}"

SUBMODULES=("droidmedia" "gst-droid" "qt5-qpa-hwcomposer-plugin")
DEFAULT_REV="refs/heads/hwenc"
REVIEW_REF="refs/heads/hwenc-review"
REMOTE="b100dian"

ALLOW_DIRTY=false
DRY_RUN=false
SQUASH=false
MSG=""
SELECTED=()
REVS=()

usage() {
  cat <<EOF
Usage: $(basename "$0") [options] [repo[:rev] ...]

  (no repos)        all three submodules, rev = hwenc
  repo[:rev]        only this submodule, optionally up to <rev> (e.g. gst-droid:hwenc~1)
  -m MSG | -F FILE  message for every selected repo (skips the editor)
  -n, --dry-run     show the pending hwenc commits and diffstat per repo; change nothing
  --squash          rebuild hwenc-review as one commit on master (rewrites published history)
  --allow-dirty     proceed although tracked files have uncommitted modifications
  -h, --help        show this help message

Repos: ${SUBMODULES[*]}
EOF
  exit "${1:-0}"
}

die() {
  echo "$*" >&2
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -m)
      [[ $# -ge 2 ]] || die "-m needs a message"
      MSG="$2"
      shift 2
      ;;
    -F)
      [[ $# -ge 2 ]] || die "-F needs a file"
      MSG="$(cat "$2")"
      shift 2
      ;;
    -n|--dry-run)
      DRY_RUN=true
      shift
      ;;
    --squash)
      SQUASH=true
      shift
      ;;
    --allow-dirty)
      ALLOW_DIRTY=true
      shift
      ;;
    -h|--help)
      usage 0
      ;;
    -*)
      echo "Unknown option: $1" >&2
      usage 1 >&2
      ;;
    *)
      name="${1%%:*}"
      rev="${DEFAULT_REV}"
      [[ "$1" == *:* ]] && rev="${1#*:}"
      known=false
      for sub in "${SUBMODULES[@]}"; do
        [[ "${sub}" == "${name}" ]] && known=true
      done
      "${known}" || die "Unknown repo: ${name} (expected one of: ${SUBMODULES[*]})"
      SELECTED+=("${name}")
      REVS+=("${rev}")
      shift
      ;;
  esac
done

if [[ ${#SELECTED[@]} -eq 0 ]]; then
  SELECTED=("${SUBMODULES[@]}")
  for _ in "${SUBMODULES[@]}"; do REVS+=("${DEFAULT_REV}"); done
fi

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
      echo "These uncommitted changes would be SILENTLY EXCLUDED from the review commit"
      echo "because 'hwenc-review' only includes commits committed to branch 'hwenc'."
      echo ""
      echo "To resolve this:"
      echo "  1. Commit your changes to 'hwenc' first, OR"
      echo "  2. Stash your changes with: git -C \"${repo_path}\" stash, OR"
      echo "  3. Re-run with '--allow-dirty' if you intentionally want only committed history."
      echo ""
      return 1
    fi
  fi
  return 0
}

# Merge-base of <rev> with master, origin/master or github/master.
find_base() {
  local repo_path="$1"
  local rev="$2"
  local candidate base

  for candidate in master origin/master github/master remotes/origin/master remotes/github/master; do
    if git -C "${repo_path}" rev-parse --verify --quiet "${candidate}" >/dev/null; then
      base="$(git -C "${repo_path}" merge-base "${rev}" "${candidate}" 2>/dev/null || true)"
      if [[ -n "${base}" ]]; then
        echo "${base}"
        return 0
      fi
    fi
  done
  return 1
}

# ==============================================================================
# Curated Commit Messages (--squash)
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
- Take the H.264 profile and level from DroidMediaCodecEncoderMetaData (public
  DroidMediaCodecH264Profile/Level enums), sharing
  droid_media_codec_set_h264_profile_level() with the camera encoder.
- Add sailfish.IScreenCaptureService hosted in minisfservice with generation
  tracking to coordinate display frame producers and the encoder consumer.
- Give each session a target (DISPLAY or VIRTUAL) and a content rect
  (DroidMediaRect), set with droid_media_screen_capture_set_target().
- Add droid_media_screen_capture_request_sync_frame(): the next frame is an IDR,
  and the renderer is asked for it, also on an idle screen.
- Export droid_media_screen_capture_* through hybris.c.
- Add the screencap_surface_capture_test tool, an optional module that the
  RPM doesn't package.
MSG
      ;;
    gst-droid)
      cat <<'MSG'
Add droidscreencapsrc element for hardware screen capture

Implement GStreamer element droidscreencapsrc using droidmediascreencapture:
- Capture screen frames directly into GstBuffers with monotonic PTS.
- Push access units immediately as they are encoded, preserving idle gaps.
- Expose properties for width, height, target-bitrate, nominal fps, H.264
  profile and level, target, and content-rect (<x, y, width, height>).
- Answer an upstream GstForceKeyUnit with an IDR of the current screen.
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
- Fit the display into any even session size and content rect (captureFit()):
  aspect ratio kept, black bars, turned by 90 or 270 degrees for the other
  orientation.
- Render DISPLAY sessions only; repaint on session changes and frame requests.
- Enable conditionally via QPA_HWC_SCREENCAP environment variable.
MSG
      ;;
    *)
      echo "Squashed hwenc changes for ${repo_name}"
      ;;
  esac
}

# ==============================================================================
# Helper: Rebuild hwenc-review safely (--squash; backs up the old tip)
# ==============================================================================
safely_update_review_branch() {
  local repo_name="$1"
  local repo_path="$2"
  local new_commit="$3"
  local base_commit="$4"

  local ts
  ts="$(date +%Y%m%d-%H%M%S)"

  # 1. If hwenc-review already exists, backup and detect any un-backported commits
  if git -C "${repo_path}" rev-parse --verify --quiet "${REVIEW_REF}" >/dev/null; then
    local old_review_tip
    old_review_tip="$(git -C "${repo_path}" rev-parse "${REVIEW_REF}")"

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

  if [[ "${current_head}" == "${REVIEW_REF}" ]]; then
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
    git -C "${repo_path}" update-ref "${REVIEW_REF}" "${new_commit}"
  fi
}

# ==============================================================================
# Append: one new commit on top of hwenc-review
# ==============================================================================
append_review_commit() {
  local name="$1"
  local rev="$2"
  local path="${MW_DIR}/${name}"

  local src review
  src="$(git -C "${path}" rev-parse --verify --quiet "${rev}^{commit}")" || {
    echo "  [ERROR] '${rev}' not found in ${name}. Skipping." >&2
    return 1
  }
  review="$(git -C "${path}" rev-parse --verify --quiet "${REVIEW_REF}^{commit}")" || {
    echo "  [ERROR] Branch 'hwenc-review' not found in ${name}. Create it with --squash. Skipping." >&2
    return 1
  }

  # A different base means hwenc was rebased: its tree would carry upstream changes.
  local src_base review_base
  src_base="$(find_base "${path}" "${src}")" || {
    echo "  [ERROR] Could not determine merge-base with master in ${name}." >&2
    return 1
  }
  review_base="$(find_base "${path}" "${review}")" || {
    echo "  [ERROR] Could not determine merge-base of hwenc-review with master in ${name}." >&2
    return 1
  }
  if [[ "${src_base}" != "${review_base}" ]]; then
    echo "  [ERROR] ${rev} and hwenc-review have different merge-bases with master in ${name}:" >&2
    echo "    ${rev}:        ${src_base}" >&2
    echo "    hwenc-review: ${review_base}" >&2
    echo "  A commit with the tree of ${rev} would mix upstream changes into the review." >&2
    echo "  Rebase hwenc-review onto the new master by hand, or rebuild it with --squash" >&2
    echo "  (rewrites published history). Skipping." >&2
    return 1
  fi

  local src_tree review_tree
  src_tree="$(git -C "${path}" rev-parse "${src}^{tree}")"
  review_tree="$(git -C "${path}" rev-parse "${review}^{tree}")"
  if [[ "${src_tree}" == "${review_tree}" ]]; then
    echo "  hwenc-review is up to date with ${rev}."
    echo ""
    return 0
  fi

  # Newest hwenc commit whose tree is what hwenc-review already holds.
  local sync pending=""
  sync="$(git -C "${path}" log --format='%H %T' "${src_base}..${src}" |
    awk -v t="${review_tree}" '$2 == t && !f { print $1; f = 1 }')"
  if [[ -n "${sync}" ]]; then
    pending="$(git -C "${path}" log --oneline --reverse "${sync}..${src}")"
    echo "  Last sync:     ${sync}"
    echo "  New commits on ${rev}:"
    echo "${pending}" | sed 's/^/    /'
  else
    echo "  [WARNING] No commit of ${rev} has the tree of hwenc-review. It was edited directly or"
    echo "  hwenc was rewritten: the new commit sets the tree to ${rev} and undoes anything"
    echo "  that exists only on hwenc-review."
  fi
  echo ""
  git -C "${path}" diff --stat "${review}" "${src}" | sed 's/^/  /'
  echo ""

  if [[ "${DRY_RUN}" == "true" ]]; then
    return 0
  fi

  local msg="${MSG}"
  if [[ -z "${msg}" ]]; then
    local editor msgfile
    editor="$(git -C "${path}" var GIT_EDITOR)"
    msgfile="$(git -C "${path}" rev-parse --absolute-git-dir)/HWENC_REVIEW_EDITMSG"
    {
      echo ""
      echo "# Review commit for ${name}: tree of ${rev} on top of hwenc-review."
      echo "# Lines starting with '#' are removed; an empty message skips this repo."
      if [[ -n "${pending}" ]]; then
        echo "#"
        echo "# New commits:"
        echo "${pending}" | sed 's/^/#   /'
      fi
      echo "#"
      echo "# Changes against hwenc-review:"
      git -C "${path}" diff --stat "${review}" "${src}" | sed 's/^/#   /'
    } > "${msgfile}"
    bash -c "${editor} \"\$1\"" _ "${msgfile}" || {
      echo "  [ERROR] Editor failed. Skipping ${name}." >&2
      return 1
    }
    msg="$(git stripspace --strip-comments < "${msgfile}")"
    rm -f "${msgfile}"
    if [[ -z "${msg}" ]]; then
      echo "  Empty commit message. Skipping ${name}."
      echo ""
      return 0
    fi
  fi

  local new_commit
  new_commit="$(git -C "${path}" commit-tree "${src_tree}" -p "${review}" <<< "${msg}")"

  local current_head
  current_head="$(git -C "${path}" symbolic-ref --quiet HEAD 2>/dev/null || true)"
  if [[ "${current_head}" == "${REVIEW_REF}" ]]; then
    if [[ -n "$(git -C "${path}" status --porcelain -uno)" ]]; then
      echo "  [ERROR] Cannot update hwenc-review while it is checked out with uncommitted changes in ${name}." >&2
      echo "  Please commit, stash, or checkout hwenc before running." >&2
      return 1
    fi
    git -C "${path}" update-ref "${REVIEW_REF}" "${new_commit}" "${review}"
    git -C "${path}" reset --hard "${new_commit}" >/dev/null
    echo "  Synchronized checked-out working tree and index on hwenc-review."
  else
    git -C "${path}" update-ref "${REVIEW_REF}" "${new_commit}" "${review}"
  fi

  echo "  hwenc-review:  ${new_commit} (parent ${review})"
  echo ""
  UPDATED+=("${name}")
}

# ==============================================================================
# Squash: rebuild hwenc-review as one commit on master
# ==============================================================================
squash_review_branch() {
  local name="$1"
  local rev="$2"
  local path="${MW_DIR}/${name}"

  local src
  src="$(git -C "${path}" rev-parse --verify --quiet "${rev}^{commit}")" || {
    echo "  [ERROR] '${rev}' not found in ${name}. Skipping." >&2
    return 1
  }

  local base
  base="$(find_base "${path}" "${src}")" || {
    echo "  [ERROR] Could not determine merge-base with master in ${name}." >&2
    return 1
  }

  echo "  [WARNING] --squash rewrites the published hwenc-review of ${name}."
  echo "  Base:          ${base}"
  echo "  ${rev}:  ${src}"
  if [[ "${DRY_RUN}" == "true" ]]; then
    echo ""
    return 0
  fi

  local tree an ae ad commit_msg review_commit
  tree="$(git -C "${path}" rev-parse "${src}^{tree}")"
  an="$(git -C "${path}" log -1 --format="%an" "${src}")"
  ae="$(git -C "${path}" log -1 --format="%ae" "${src}")"
  ad="$(git -C "${path}" log -1 --format="%ad" --date=raw "${src}")"

  commit_msg="${MSG:-$(get_curated_msg "${name}")}"

  review_commit="$(
    GIT_AUTHOR_NAME="${an}" \
    GIT_AUTHOR_EMAIL="${ae}" \
    GIT_AUTHOR_DATE="${ad}" \
    GIT_COMMITTER_NAME="${an}" \
    GIT_COMMITTER_EMAIL="${ae}" \
    GIT_COMMITTER_DATE="${ad}" \
    git -C "${path}" commit-tree "${tree}" -p "${base}" <<< "${commit_msg}"
  )"

  safely_update_review_branch "${name}" "${path}" "${review_commit}" "${base}" || return 1

  echo "  hwenc-review:  ${review_commit} (single commit on top of base)"
  echo ""
  UPDATED+=("${name}")
}

# ==============================================================================
# Main
# ==============================================================================
if [[ "${DRY_RUN}" == "false" ]]; then
  echo "=================================================="
  echo "Pre-flight cleanliness check..."
  echo "=================================================="
  for name in "${SELECTED[@]}"; do
    check_cleanliness "${name}" "${MW_DIR}/${name}" || exit 1
  done
  echo "Pre-flight checks passed."
  echo ""
fi

UPDATED=()
failed=0

for i in "${!SELECTED[@]}"; do
  name="${SELECTED[$i]}"
  rev="${REVS[$i]}"

  echo "=================================================="
  if [[ "${SQUASH}" == "true" ]]; then
    echo "Squashing submodule: ${name}"
  else
    echo "Appending to hwenc-review: ${name}"
  fi
  echo "=================================================="

  if [[ "${SQUASH}" == "true" ]]; then
    squash_review_branch "${name}" "${rev}" || failed=1
  else
    append_review_commit "${name}" "${rev}" || failed=1
  fi
done

if [[ ${#UPDATED[@]} -gt 0 ]]; then
  echo "=================================================="
  echo "Review branches ready! Push to your remote forks:"
  for name in "${UPDATED[@]}"; do
    if [[ "${SQUASH}" == "true" ]]; then
      echo "  git -C ${name} push --force-with-lease ${REMOTE} hwenc-review"
    else
      echo "  git -C ${name} push ${REMOTE} hwenc-review"
    fi
  done
  echo "=================================================="
fi

exit "${failed}"
