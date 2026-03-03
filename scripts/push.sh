#!/usr/bin/env bash
# push.sh — Export brain snapshot and push to Git remote
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

QUIET=false
FORCE=false
SKIP_SECRET_SCAN=false

while [ $# -gt 0 ]; do
  case "$1" in
    --quiet) QUIET=true; BRAIN_QUIET=true; shift ;;
    --force) FORCE=true; shift ;;
    --skip-secret-scan) SKIP_SECRET_SCAN=true; shift ;;
    *) shift ;;
  esac
done

check_dependencies
load_config

machine_id=$(get_config "machine_id")
snapshot_dir="${BRAIN_REPO}/machines/${machine_id}"

# Export fresh snapshot
mkdir -p "$snapshot_dir"
export_args=(--output "${snapshot_dir}/brain-snapshot.json")
$QUIET && export_args+=(--quiet)
$SKIP_SECRET_SCAN && export_args+=(--skip-secret-scan)
"${SCRIPT_DIR}/export.sh" "${export_args[@]}"

# Check if anything actually changed
if ! $FORCE; then
  if brain_git diff --quiet -- "machines/${machine_id}/" 2>/dev/null; then
    log_info "No changes to push."
    exit 0
  fi
fi

# Update machines.json with last sync time
"${SCRIPT_DIR}/register-machine.sh" "$(get_config remote)"

# Commit and push
brain_git add "machines/${machine_id}/" "meta/machines.json"
brain_git commit -m "Sync: $(get_machine_name) (${machine_id}) at $(now_iso)" 2>/dev/null || {
  log_info "Nothing to commit."
  exit 0
}

# Push with retry (handles concurrent pushes)
if brain_push_with_retry 3 2; then
  # Update local config
  if $_has_jq; then
    local_tmp=$(brain_mktemp)
    jq --arg ts "$(now_iso)" '.last_push = $ts | .dirty = false' "$BRAIN_CONFIG" > "$local_tmp"
    mv "$local_tmp" "$BRAIN_CONFIG"
  fi
  log_info "Brain snapshot pushed."
else
  # Mark dirty for retry on next session start
  if $_has_jq; then
    local_tmp=$(brain_mktemp)
    jq '.dirty = true' "$BRAIN_CONFIG" > "$local_tmp"
    mv "$local_tmp" "$BRAIN_CONFIG"
  fi
  log_warn "Push failed. Marked dirty for retry."
fi
