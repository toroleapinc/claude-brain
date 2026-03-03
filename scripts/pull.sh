#!/usr/bin/env bash
# pull.sh — Pull latest from remote, merge, and apply locally
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

QUIET=false
AUTO_MERGE=false

while [ $# -gt 0 ]; do
  case "$1" in
    --quiet) QUIET=true; BRAIN_QUIET=true; shift ;;
    --auto-merge) AUTO_MERGE=true; shift ;;
    *) shift ;;
  esac
done

check_dependencies
load_config

machine_id=$(get_config "machine_id")

# Retry dirty push from previous session
dirty=$(get_config "dirty" 2>/dev/null || echo "false")
if [ "$dirty" = "true" ]; then
  log_info "Retrying dirty push from previous session..."
  "${SCRIPT_DIR}/push.sh" --quiet --skip-secret-scan || true
fi

# Fetch latest
brain_git fetch origin main 2>/dev/null || {
  log_warn "Could not fetch from remote. Working offline."
  exit 0
}
brain_git merge origin/main --no-edit 2>/dev/null || {
  # If merge conflicts in git, try rebase
  brain_git rebase origin/main 2>/dev/null || {
    brain_git rebase --abort 2>/dev/null || true
    log_warn "Git merge conflict. Run /brain-sync manually."
    exit 1
  }
}

# Check if consolidated brain has changed
local_consolidated_hash=""
if [ -f "${BRAIN_REPO}/consolidated/brain.json" ]; then
  local_consolidated_hash=$(file_hash "${BRAIN_REPO}/consolidated/brain.json")
fi

# Collect all machine snapshots
snapshot_count=0
snapshots=()
for snapshot_file in "${BRAIN_REPO}"/machines/*/brain-snapshot.json; do
  if [ -f "$snapshot_file" ]; then
    snapshots+=("$snapshot_file")
    snapshot_count=$((snapshot_count + 1))
  fi
done

if [ "$snapshot_count" -eq 0 ]; then
  log_info "No machine snapshots found."
  exit 0
fi

mkdir -p "${BRAIN_REPO}/consolidated"

if [ "$snapshot_count" -eq 1 ]; then
  # Only one machine — its snapshot IS the consolidated brain
  cp "${snapshots[0]}" "${BRAIN_REPO}/consolidated/brain.json"
else
  # Multiple machines — merge pairwise
  log_info "Merging snapshots from ${snapshot_count} machines..."

  # Start with the current consolidated brain, or first snapshot
  if [ -f "${BRAIN_REPO}/consolidated/brain.json" ]; then
    cp "${BRAIN_REPO}/consolidated/brain.json" "${BRAIN_REPO}/consolidated/brain.json.merging"
  else
    cp "${snapshots[0]}" "${BRAIN_REPO}/consolidated/brain.json.merging"
  fi

  for snapshot_file in "${snapshots[@]}"; do
    local snapshot_machine_id
    if $_has_jq; then
      snapshot_machine_id=$(jq -r '.machine.id' "$snapshot_file")
    else
      snapshot_machine_id="unknown"
    fi

    # Run structured merge (settings, keybindings, MCP)
    "${SCRIPT_DIR}/merge-structured.sh" \
      "${BRAIN_REPO}/consolidated/brain.json.merging" \
      "$snapshot_file" \
      "${BRAIN_REPO}/consolidated/brain.json.merging" || true

    # Run semantic merge for memory/CLAUDE.md (only if content differs)
    if $_has_jq; then
      local base_memory_hash new_memory_hash
      base_memory_hash=$(jq '.experiential' "${BRAIN_REPO}/consolidated/brain.json.merging" | compute_hash)
      new_memory_hash=$(jq '.experiential' "$snapshot_file" | compute_hash)

      if [ "$base_memory_hash" != "$new_memory_hash" ]; then
        "${SCRIPT_DIR}/merge-semantic.sh" \
          "${BRAIN_REPO}/consolidated/brain.json.merging" \
          "$snapshot_file" \
          "${BRAIN_REPO}/consolidated/brain.json.merging" || {
          log_warn "Semantic merge failed for ${snapshot_machine_id}. Using structured merge only."
        }
      fi
    fi
  done

  mv "${BRAIN_REPO}/consolidated/brain.json.merging" "${BRAIN_REPO}/consolidated/brain.json"
fi

# Apply consolidated brain locally (with validation and backup)
"${SCRIPT_DIR}/import.sh" "${BRAIN_REPO}/consolidated/brain.json"

# Commit and push consolidated
brain_git add consolidated/ meta/
if brain_git diff --cached --quiet 2>/dev/null; then
  log_info "Consolidated brain unchanged."
else
  brain_git commit -m "Consolidated: $(get_machine_name) merged at $(now_iso)" 2>/dev/null || true
  brain_push_with_retry 3 2 || log_warn "Failed to push consolidated brain."
fi

# Update local config
if $_has_jq; then
  local_tmp=$(brain_mktemp)
  jq --arg ts "$(now_iso)" '.last_pull = $ts' "$BRAIN_CONFIG" > "$local_tmp"
  mv "$local_tmp" "$BRAIN_CONFIG"
fi

# Log the merge
new_consolidated_hash=$(file_hash "${BRAIN_REPO}/consolidated/brain.json")
if [ "$local_consolidated_hash" != "$new_consolidated_hash" ]; then
  append_merge_log "pull+merge" "Merged ${snapshot_count} machine snapshots"
  log_info "Brain synced: merged ${snapshot_count} machine(s)."
else
  log_info "Brain synced: no changes."
fi
