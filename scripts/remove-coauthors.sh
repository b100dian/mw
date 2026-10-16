#!/usr/bin/env bash
#
# remove-coauthors.sh
#
# Strips "Co-Authored-By:" lines from commits on the hwenc branch in:
#  - mw/droidmedia
#  - mw/gst-droid
#  - mw/qt5-qpa-hwcomposer-plugin
#  - mw (superproject)
#
# Addresses:
# 1. Idempotency & Backup Safety:
#    - Preserves primary baseline refs/heads/hwenc-before-strip if already present.
#    - Creates immutable timestamped backups (refs/backup/hwenc-<timestamp>).
#    - Only creates backups if rewriting is actually needed.
# 2. Superproject Gitlink Synchronization:
#    - Maps all rewritten submodule commits into a global transition table.
#    - Rewrites mw superproject commit trees via git mktree to update gitlink
#      entries (mode 160000) from old submodule SHAs to new clean SHAs.
#    - Ensures mw:hwenc tip points to the clean tips of the submodules.
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MW_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

SUBMODULES=("droidmedia" "gst-droid" "qt5-qpa-hwcomposer-plugin")

INCLUDE_MW=true
BACKUP_REF=true

usage() {
  cat <<EOF
Usage: $(basename "$0") [options]

Options:
  --no-mw        Skip rewriting commits in the mw superproject
  --no-backup    Skip creating backup refs
  -h, --help     Show this help message
EOF
  exit 0
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --no-mw)
      INCLUDE_MW=false
      shift
      ;;
    --no-backup)
      BACKUP_REF=false
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

# Global mapping of old_submodule_sha -> new_submodule_sha
declare -A GLOBAL_SUBMODULE_MAP
global_map_count=0
# Mapping of submodule_name -> new_hwenc_tip
declare -A SUBMODULE_TIPS

find_base() {
  local repo_path="$1"
  local base=""
  for candidate in master origin/master github/master remotes/origin/master remotes/github/master; do
    if git -C "${repo_path}" rev-parse --verify --quiet "${candidate}" >/dev/null; then
      base="$(git -C "${repo_path}" merge-base refs/heads/hwenc "${candidate}" 2>/dev/null || true)"
      if [[ -n "${base}" ]]; then
        echo "${base}"
        return 0
      fi
    fi
  done
  return 1
}

save_backup() {
  local repo_path="$1"
  local tip="$2"

  if [[ "${BACKUP_REF}" != "true" ]]; then
    return 0
  fi

  local ts
  ts="$(date +%Y%m%d-%H%M%S)"

  # 1. Never overwrite the primary initial baseline
  if ! git -C "${repo_path}" rev-parse --verify --quiet refs/heads/hwenc-before-strip >/dev/null; then
    git -C "${repo_path}" update-ref refs/heads/hwenc-before-strip "${tip}"
    echo "  Saved initial baseline: hwenc-before-strip (${tip})"
  else
    local existing_baseline
    existing_baseline="$(git -C "${repo_path}" rev-parse refs/heads/hwenc-before-strip)"
    echo "  Preserved initial baseline: hwenc-before-strip (${existing_baseline})"
  fi

  # 2. Save immutable timestamped backup
  git -C "${repo_path}" update-ref "refs/backup/hwenc-${ts}" "${tip}"
  echo "  Saved timestamped backup: refs/backup/hwenc-${ts} (${tip})"
}

rewrite_submodule() {
  local sub="$1"
  local repo_path="${MW_DIR}/${sub}"

  echo "=================================================="
  echo "Processing submodule: ${sub}"
  echo "=================================================="

  if ! git -C "${repo_path}" rev-parse --verify --quiet refs/heads/hwenc >/dev/null; then
    echo "  [WARN] Branch 'hwenc' not found in ${sub}. Skipping."
    return 0
  fi

  local orig_tip
  orig_tip="$(git -C "${repo_path}" rev-parse refs/heads/hwenc)"

  local base
  if ! base="$(find_base "${repo_path}")"; then
    echo "  [ERROR] Could not determine merge-base with master in ${sub}." >&2
    return 1
  fi

  local commits
  commits="$(git -C "${repo_path}" rev-list --reverse --topo-order "${base}..refs/heads/hwenc")"

  if [[ -z "${commits}" ]]; then
    echo "  No commits found between base and hwenc."
    SUBMODULE_TIPS["${sub}"]="${orig_tip}"
    return 0
  fi

  # Check if any commit actually has Co-Authored-By
  local needs_rewrite=false
  for c in ${commits}; do
    if git -C "${repo_path}" log -1 --format="%B" "${c}" | grep -qiE "^[[:space:]]*[Cc]o-[Aa]uthored-[Bb]y:"; then
      needs_rewrite=true
      break
    fi
  done

  if [[ "${needs_rewrite}" == "false" ]]; then
    echo "  Already clean: no Co-Authored-By trailers found in ${sub}."
    echo "  hwenc tip unchanged: ${orig_tip}"
    SUBMODULE_TIPS["${sub}"]="${orig_tip}"
    echo ""
    return 0
  fi

  # Perform backup only when rewriting
  save_backup "${repo_path}" "${orig_tip}"

  declare -A local_map
  local count_rewritten=0

  for c in ${commits}; do
    local parents
    parents="$(git -C "${repo_path}" log -1 --format="%P" "${c}")"

    local parent_args=()
    local parent_was_rewritten=false

    for p in ${parents}; do
      if [[ -n "${local_map[${p}]:-}" ]]; then
        parent_args+=(-p "${local_map[${p}]}")
        parent_was_rewritten=true
      else
        parent_args+=(-p "${p}")
      fi
    done

    local msg
    msg="$(git -C "${repo_path}" log -1 --format="%B" "${c}")"

    local has_coauthor=false
    if echo "${msg}" | grep -qiE "^[[:space:]]*[Cc]o-[Aa]uthored-[Bb]y:"; then
      has_coauthor=true
    fi

    if [[ "${has_coauthor}" == "false" && "${parent_was_rewritten}" == "false" ]]; then
      continue
    fi

    local filtered_msg
    filtered_msg="$(echo "${msg}" | awk '
      !/^[[:space:]]*[Cc]o-[Aa]uthored-[Bb]y:/ {
        lines[++n] = $0
      }
      END {
        while (n > 0 && lines[n] ~ /^[[:space:]]*$/) n--
        for (i = 1; i <= n; i++) print lines[i]
      }
    ')"

    local tree an ae ad cn ce cd
    tree="$(git -C "${repo_path}" rev-parse "${c}^{tree}")"
    an="$(git -C "${repo_path}" log -1 --format="%an" "${c}")"
    ae="$(git -C "${repo_path}" log -1 --format="%ae" "${c}")"
    ad="$(git -C "${repo_path}" log -1 --format="%ad" --date=raw "${c}")"
    cn="$(git -C "${repo_path}" log -1 --format="%cn" "${c}")"
    ce="$(git -C "${repo_path}" log -1 --format="%ce" "${c}")"
    cd="$(git -C "${repo_path}" log -1 --format="%cd" --date=raw "${c}")"

    local new_sha
    new_sha="$(
      GIT_AUTHOR_NAME="${an}" \
      GIT_AUTHOR_EMAIL="${ae}" \
      GIT_AUTHOR_DATE="${ad}" \
      GIT_COMMITTER_NAME="${cn}" \
      GIT_COMMITTER_EMAIL="${ce}" \
      GIT_COMMITTER_DATE="${cd}" \
      git -C "${repo_path}" commit-tree "${tree}" "${parent_args[@]}" <<< "${filtered_msg}"
    )"

    local_map["${c}"]="${new_sha}"
    GLOBAL_SUBMODULE_MAP["${c}"]="${new_sha}"
    global_map_count=$((global_map_count + 1))
    count_rewritten=$((count_rewritten + 1))
  done

  local new_tip="${local_map[${orig_tip}]:-${orig_tip}}"

  git -C "${repo_path}" update-ref refs/heads/hwenc "${new_tip}"

  local current_head
  current_head="$(git -C "${repo_path}" symbolic-ref --quiet HEAD 2>/dev/null || true)"
  if [[ "${current_head}" == "refs/heads/hwenc" ]]; then
    git -C "${repo_path}" update-ref HEAD "${new_tip}"
  fi

  SUBMODULE_TIPS["${sub}"]="${new_tip}"

  echo "  [SUCCESS] Rewrote ${count_rewritten} commit(s)."
  echo "  Original tip: ${orig_tip}"
  echo "  New hwenc tip: ${new_tip}"
  echo ""
}

remap_mw_tree() {
  local tree_sha="$1"
  local is_tip="$2"

  local tree_entries
  tree_entries="$(git -C "${MW_DIR}" ls-tree "${tree_sha}")"

  local modified=false
  local new_entries=""

  while IFS=$'\t' read -r meta path; do
    [[ -z "${meta}" ]] && continue
    local mode type sha
    read -r mode type sha <<< "${meta}"

    if [[ "${type}" == "commit" ]]; then
      # Check if this submodule commit was rewritten
      if [[ -n "${GLOBAL_SUBMODULE_MAP[${sha}]:-}" ]]; then
        sha="${GLOBAL_SUBMODULE_MAP[${sha}]}"
        modified=true
      fi

      # At the hwenc tip of mw, synchronize submodule gitlink to latest clean tip
      if [[ "${is_tip}" == "true" && -n "${SUBMODULE_TIPS[${path}]:-}" ]]; then
        if [[ "${sha}" != "${SUBMODULE_TIPS[${path}]}" ]]; then
          sha="${SUBMODULE_TIPS[${path}]}"
          modified=true
        fi
      fi
    fi

    new_entries+="${mode} ${type} ${sha}"$'\t'"${path}"$'\n'
  done <<< "${tree_entries}"

  if [[ "${modified}" == "true" ]]; then
    printf "%b" "${new_entries}" | git -C "${MW_DIR}" mktree
  else
    echo "${tree_sha}"
  fi
}

rewrite_mw() {
  echo "=================================================="
  echo "Processing superproject: mw"
  echo "=================================================="

  if ! git -C "${MW_DIR}" rev-parse --verify --quiet refs/heads/hwenc >/dev/null; then
    echo "  [WARN] Branch 'hwenc' not found in mw. Skipping."
    return 0
  fi

  local orig_tip
  orig_tip="$(git -C "${MW_DIR}" rev-parse refs/heads/hwenc)"

  local base
  if ! base="$(find_base "${MW_DIR}")"; then
    echo "  [ERROR] Could not determine merge-base with master in mw." >&2
    return 1
  fi

  local commits
  commits="$(git -C "${MW_DIR}" rev-list --reverse --topo-order "${base}..refs/heads/hwenc")"

  if [[ -z "${commits}" ]]; then
    echo "  No commits found between base and hwenc in mw."
    return 0
  fi

  # Check if rewrite is needed in mw (either co-author or gitlink update)
  local needs_rewrite=false
  for c in ${commits}; do
    if git -C "${MW_DIR}" log -1 --format="%B" "${c}" | grep -qiE "^[[:space:]]*[Cc]o-[Aa]uthored-[Bb]y:"; then
      needs_rewrite=true
      break
    fi
  done

  # Also check if any gitlink in mw commits points to a rewritten submodule SHA
  if [[ "${needs_rewrite}" == "false" && ${global_map_count} -gt 0 ]]; then
    for c in ${commits}; do
      local c_tree
      c_tree="$(git -C "${MW_DIR}" rev-parse "${c}^{tree}")"
      local c_sub_shas
      c_sub_shas="$(git -C "${MW_DIR}" ls-tree "${c_tree}" | awk '$2=="commit" {print $3}')"
      for s in ${c_sub_shas}; do
        if [[ -n "${GLOBAL_SUBMODULE_MAP[${s}]:-}" ]]; then
          needs_rewrite=true
          break 2
        fi
      done
    done
  fi

  if [[ "${needs_rewrite}" == "false" ]]; then
    echo "  Already clean: no Co-Authored-By trailers or stale gitlinks in mw."
    echo "  hwenc tip unchanged: ${orig_tip}"
    echo ""
    return 0
  fi

  save_backup "${MW_DIR}" "${orig_tip}"

  declare -A mw_map
  local count_rewritten=0

  for c in ${commits}; do
    local parents
    parents="$(git -C "${MW_DIR}" log -1 --format="%P" "${c}")"

    local parent_args=()
    local parent_was_rewritten=false

    for p in ${parents}; do
      if [[ -n "${mw_map[${p}]:-}" ]]; then
        parent_args+=(-p "${mw_map[${p}]}")
        parent_was_rewritten=true
      else
        parent_args+=(-p "${p}")
      fi
    done

    local msg
    msg="$(git -C "${MW_DIR}" log -1 --format="%B" "${c}")"

    local has_coauthor=false
    if echo "${msg}" | grep -qiE "^[[:space:]]*[Cc]o-[Aa]uthored-[Bb]y:"; then
      has_coauthor=true
    fi

    local orig_tree
    orig_tree="$(git -C "${MW_DIR}" rev-parse "${c}^{tree}")"

    local is_tip=false
    if [[ "${c}" == "${orig_tip}" ]]; then
      is_tip=true
    fi

    local new_tree
    new_tree="$(remap_mw_tree "${orig_tree}" "${is_tip}")"

    local tree_was_rewritten=false
    if [[ "${new_tree}" != "${orig_tree}" ]]; then
      tree_was_rewritten=true
    fi

    if [[ "${has_coauthor}" == "false" && "${parent_was_rewritten}" == "false" && "${tree_was_rewritten}" == "false" ]]; then
      continue
    fi

    local filtered_msg
    filtered_msg="$(echo "${msg}" | awk '
      !/^[[:space:]]*[Cc]o-[Aa]uthored-[Bb]y:/ {
        lines[++n] = $0
      }
      END {
        while (n > 0 && lines[n] ~ /^[[:space:]]*$/) n--
        for (i = 1; i <= n; i++) print lines[i]
      }
    ')"

    local an ae ad cn ce cd
    an="$(git -C "${MW_DIR}" log -1 --format="%an" "${c}")"
    ae="$(git -C "${MW_DIR}" log -1 --format="%ae" "${c}")"
    ad="$(git -C "${MW_DIR}" log -1 --format="%ad" --date=raw "${c}")"
    cn="$(git -C "${MW_DIR}" log -1 --format="%cn" "${c}")"
    ce="$(git -C "${MW_DIR}" log -1 --format="%ce" "${c}")"
    cd="$(git -C "${MW_DIR}" log -1 --format="%cd" --date=raw "${c}")"

    local new_sha
    new_sha="$(
      GIT_AUTHOR_NAME="${an}" \
      GIT_AUTHOR_EMAIL="${ae}" \
      GIT_AUTHOR_DATE="${ad}" \
      GIT_COMMITTER_NAME="${cn}" \
      GIT_COMMITTER_EMAIL="${ce}" \
      GIT_COMMITTER_DATE="${cd}" \
      git -C "${MW_DIR}" commit-tree "${new_tree}" "${parent_args[@]}" <<< "${filtered_msg}"
    )"

    mw_map["${c}"]="${new_sha}"
    count_rewritten=$((count_rewritten + 1))
  done

  local new_tip="${mw_map[${orig_tip}]:-${orig_tip}}"

  git -C "${MW_DIR}" update-ref refs/heads/hwenc "${new_tip}"

  local current_head
  current_head="$(git -C "${MW_DIR}" symbolic-ref --quiet HEAD 2>/dev/null || true)"
  if [[ "${current_head}" == "refs/heads/hwenc" ]]; then
    git -C "${MW_DIR}" update-ref HEAD "${new_tip}"
  fi

  echo "  [SUCCESS] Rewrote ${count_rewritten} commit(s) in mw."
  echo "  Original tip: ${orig_tip}"
  echo "  New hwenc tip: ${new_tip}"
  echo ""
}

# 1. Rewrite the 3 submodules
for sub in "${SUBMODULES[@]}"; do
  rewrite_submodule "${sub}"
done

# 2. Rewrite superproject mw if requested
if [[ "${INCLUDE_MW}" == "true" ]]; then
  rewrite_mw
fi

echo "=================================================="
echo "Summary of hwenc tips:"
for sub in "${SUBMODULES[@]}"; do
  echo "  ${sub}: ${SUBMODULE_TIPS[${sub}]:-(unchanged)}"
done
if [[ "${INCLUDE_MW}" == "true" ]]; then
  echo "  mw: $(git -C "${MW_DIR}" rev-parse refs/heads/hwenc)"
fi
echo "=================================================="
