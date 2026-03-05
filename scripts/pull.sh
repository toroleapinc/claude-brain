#!/usr/bin/env bash
# pull.sh — Pull latest from remote, merge, and apply locally
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

QUIET=false
AUTO_MERGE=false
DRY_RUN=false

while [ $# -gt 0 ]; do
  case "$1" in
    --quiet) QUIET=true; BRAIN_QUIET=true; shift ;;
    --auto-merge) AUTO_MERGE=true; shift ;;
    --dry-run) DRY_RUN=true; shift ;;
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

# Collect all machine snapshots (decrypt if needed)
snapshot_count=0
snapshots=()
decrypted_snapshots=()

for snapshot_file in "${BRAIN_REPO}"/machines/*/brain-snapshot.json; do
  if [ -f "$snapshot_file" ]; then
    # Check if snapshot is encrypted
    if is_encrypted_content "$(cat "$snapshot_file")"; then
      if encryption_enabled && command -v age &>/dev/null; then
        # Decrypt to temp file
        local decrypted_tmp
        decrypted_tmp=$(brain_mktemp)
        if decrypt_file "$snapshot_file" "$decrypted_tmp"; then
          snapshots+=("$decrypted_tmp")
          decrypted_snapshots+=("$decrypted_tmp")
          snapshot_count=$((snapshot_count + 1))
        else
          log_warn "Failed to decrypt snapshot: $snapshot_file"
        fi
      else
        log_warn "Encrypted snapshot found but encryption not configured: $snapshot_file"
      fi
    else
      # Unencrypted snapshot
      snapshots+=("$snapshot_file")
      snapshot_count=$((snapshot_count + 1))
    fi
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
  # Multiple machines — N-way merge 
  log_info "Merging snapshots from ${snapshot_count} machines..."

  # Use merge-structured.sh for pairwise structured merge
  cp "${snapshots[0]}" "${BRAIN_REPO}/consolidated/brain.json.merging"
  
  for ((i=1; i<${#snapshots[@]}; i++)); do
    "${SCRIPT_DIR}/merge-structured.sh" \
      "${BRAIN_REPO}/consolidated/brain.json.merging" \
      "${snapshots[i]}" \
      "${BRAIN_REPO}/consolidated/brain.json.merging"
  done

  # Now run N-way semantic merge on all snapshots at once
  "${SCRIPT_DIR}/merge-semantic.sh" \
    "${BRAIN_REPO}/consolidated/brain.json" \
    "${snapshots[@]}" || {
    log_warn "Semantic merge failed. Using structured merge only."
  }
  
  # Use the structurally merged version if semantic merge failed
  if [ -f "${BRAIN_REPO}/consolidated/brain.json.merging" ]; then
    mv "${BRAIN_REPO}/consolidated/brain.json.merging" "${BRAIN_REPO}/consolidated/brain.json"
  fi
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
  local_tmp=$(brain_mktemp)
  jq --arg ts "$(now_iso)" '.last_pull = $ts' "$BRAIN_CONFIG" > "$local_tmp"
  mv "$local_tmp" "$BRAIN_CONFIG"

# Check if auto-evolve is due
if [ -f "$DEFAULTS_FILE" ]; then
  evolve_interval_days="" last_evolved="" days_since_evolve=""
  evolve_interval_days=$(jq -r '.evolve_interval_days // 7' "$DEFAULTS_FILE")
  last_evolved=$(jq -r '.last_evolved // null' "$BRAIN_CONFIG")
  
  if [ "$last_evolved" = "null" ] || [ -z "$last_evolved" ]; then
    # Never evolved, set to now to start the timer
    local_tmp=$(brain_mktemp)
    jq --arg ts "$(now_iso)" '.last_evolved = $ts' "$BRAIN_CONFIG" > "$local_tmp"
    mv "$local_tmp" "$BRAIN_CONFIG"
  else
    # Calculate days since last evolution
    if command -v date &>/dev/null; then
      local last_evolved_ts current_ts
      last_evolved_ts=$(date -d "$last_evolved" +%s 2>/dev/null || date -j -f "%Y-%m-%dT%H:%M:%SZ" "$last_evolved" +%s 2>/dev/null || echo "0")
      current_ts=$(date +%s)
      days_since_evolve=$(( (current_ts - last_evolved_ts) / 86400 ))
      
      if [ "$days_since_evolve" -ge "$evolve_interval_days" ]; then
        log_info "Auto-evolve due (${days_since_evolve} days since last evolution)..."
        "${SCRIPT_DIR}/evolve.sh" --auto 2>/dev/null || {
          log_warn "Auto-evolve failed. Run /brain-evolve manually."
        }
      fi
    fi
  fi
fi

# Log the merge
new_consolidated_hash=$(file_hash "${BRAIN_REPO}/consolidated/brain.json")
if [ "$local_consolidated_hash" != "$new_consolidated_hash" ]; then
  append_merge_log "pull+merge" "Merged ${snapshot_count} machine snapshots"
  log_info "Brain synced: merged ${snapshot_count} machine(s)."
else
  log_info "Brain synced: no changes."
fi
