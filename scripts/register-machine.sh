#!/usr/bin/env bash
# register-machine.sh — Create/update machine identity
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

register_machine() {
  local remote="${1:-}"
  local enable_encryption=false
  
  # Parse flags
  shift || true
  while [ $# -gt 0 ]; do
    case "$1" in
      --encrypt) enable_encryption=true; shift ;;
      *) shift ;;
    esac
  done
  
  local machine_id machine_name os_type timestamp

  # Generate or load machine ID
  if [ -f "$BRAIN_CONFIG" ]; then
    machine_id=$(get_config "machine_id")
  else
    machine_id=$(generate_machine_id)
  fi

  machine_name=$(get_machine_name)
  os_type=$(detect_os)
  timestamp=$(now_iso)

  # Preserve sync timestamps from existing config so re-registration doesn't wipe them
  local last_push="null" last_pull="null" last_evolved="null"
  if [ -f "$BRAIN_CONFIG" ]; then
    local _lp _lpull _le
    _lp=$(jq -r '.last_push // "null"' "$BRAIN_CONFIG")
    _lpull=$(jq -r '.last_pull // "null"' "$BRAIN_CONFIG")
    _le=$(jq -r '.last_evolved // "null"' "$BRAIN_CONFIG")
    [ "$_lp" != "null" ] && last_push="\"${_lp}\""
    [ "$_lpull" != "null" ] && last_pull="\"${_lpull}\""
    [ "$_le" != "null" ] && last_evolved="\"${_le}\""
  fi

  # Discover tracked projects
  local projects="[]"
  if [ -d "${CLAUDE_DIR}/projects" ]; then
      projects=$(find "${CLAUDE_DIR}/projects" -maxdepth 1 -mindepth 1 -type d 2>/dev/null | while read -r dir; do
        local encoded
        encoded=$(basename "$dir")
        local name
        name=$(project_name_from_encoded "$encoded")
        jq -n --arg encoded "$encoded" --arg name "$name" '{"encoded": $encoded, "name": $name}'
      done | jq -s '.' 2>/dev/null || echo "[]")
    else
      projects="[]"
    fi

  # Create/update brain-config.json
    if [ "$enable_encryption" = "true" ]; then
      jq -n \
        --arg ver "1.0.0" \
        --arg remote "$remote" \
        --arg mid "$machine_id" \
        --arg mn "$machine_name" \
        --arg os "$os_type" \
        --arg repo "$BRAIN_REPO" \
        --argjson sync true \
        --arg ts "$timestamp" \
        --argjson lp "$last_push" \
        --argjson lpull "$last_pull" \
        --argjson le "$last_evolved" \
        --arg identity "${HOME}/.claude/brain-age-key.txt" \
        --arg recipients "${BRAIN_REPO}/meta/recipients.txt" \
        '{
          version: $ver,
          remote: $remote,
          machine_id: $mid,
          machine_name: $mn,
          os: $os,
          brain_repo_path: $repo,
          auto_sync: $sync,
          registered_at: $ts,
          last_push: $lp,
          last_pull: $lpull,
          last_evolved: $le,
          dirty: false,
          encryption: {
            enabled: true,
            identity: $identity,
            recipients: $recipients
          }
        }' > "$BRAIN_CONFIG"
    else
      jq -n \
        --arg ver "1.0.0" \
        --arg remote "$remote" \
        --arg mid "$machine_id" \
        --arg mn "$machine_name" \
        --arg os "$os_type" \
        --arg repo "$BRAIN_REPO" \
        --argjson sync true \
        --arg ts "$timestamp" \
        --argjson lp "$last_push" \
        --argjson lpull "$last_pull" \
        --argjson le "$last_evolved" \
        '{
          version: $ver,
          remote: $remote,
          machine_id: $mid,
          machine_name: $mn,
          os: $os,
          brain_repo_path: $repo,
          auto_sync: $sync,
          registered_at: $ts,
          last_push: $lp,
          last_pull: $lpull,
          last_evolved: $le,
          dirty: false,
          encryption: {
            enabled: false
          }
        }' > "$BRAIN_CONFIG"
    fi

  # Update machines.json in brain repo if it exists
  local machines_file="${BRAIN_REPO}/meta/machines.json"
  if [ -d "${BRAIN_REPO}/meta" ]; then
    if [ ! -f "$machines_file" ]; then
      echo '{"machines":{}}' > "$machines_file"
    fi

      local tmp
      tmp=$(brain_mktemp)
      jq --arg mid "$machine_id" \
         --arg mn "$machine_name" \
         --arg os "$os_type" \
         --arg ts "$timestamp" \
         --argjson projects "$projects" \
         '.machines[$mid] = {
           "name": $mn,
           "os": $os,
           "registered_at": ($ts),
           "last_sync": $ts,
           "projects": $projects
         }' "$machines_file" > "$tmp" && mv "$tmp" "$machines_file"
    fi

  log_info "Machine registered: ${machine_name} (${machine_id})"
}

# Main
if [ "${1:-}" = "--help" ]; then
  echo "Usage: register-machine.sh <git-remote-url> [--encrypt]"
  exit 0
fi

register_machine "$@"
