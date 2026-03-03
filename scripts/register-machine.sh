#!/usr/bin/env bash
# register-machine.sh — Create/update machine identity
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

register_machine() {
  local remote="${1:-}"
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

  # Discover tracked projects
  local projects="[]"
  if [ -d "${CLAUDE_DIR}/projects" ]; then
    if $_has_jq; then
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
  fi

  # Create/update brain-config.json
  if $_has_jq; then
    jq -n \
      --arg ver "1.0.0" \
      --arg remote "$remote" \
      --arg mid "$machine_id" \
      --arg mn "$machine_name" \
      --arg os "$os_type" \
      --arg repo "$BRAIN_REPO" \
      --argjson sync true \
      --arg ts "$timestamp" \
      '{
        version: $ver,
        remote: $remote,
        machine_id: $mid,
        machine_name: $mn,
        os: $os,
        brain_repo_path: $repo,
        auto_sync: $sync,
        registered_at: $ts,
        last_push: null,
        last_pull: null,
        dirty: false
      }' > "$BRAIN_CONFIG"
  elif $_has_python3; then
    # Pass all data via argv to avoid injection
    python3 -c "
import json, sys
config = {
    'version': '1.0.0',
    'remote': sys.argv[1],
    'machine_id': sys.argv[2],
    'machine_name': sys.argv[3],
    'os': sys.argv[4],
    'brain_repo_path': sys.argv[5],
    'auto_sync': True,
    'registered_at': sys.argv[6],
    'last_push': None,
    'last_pull': None,
    'dirty': False
}
with open(sys.argv[7], 'w') as f:
    json.dump(config, f, indent=2)
" "$remote" "$machine_id" "$machine_name" "$os_type" "$BRAIN_REPO" "$timestamp" "$BRAIN_CONFIG"
  fi

  # Update machines.json in brain repo if it exists
  local machines_file="${BRAIN_REPO}/meta/machines.json"
  if [ -d "${BRAIN_REPO}/meta" ]; then
    if [ ! -f "$machines_file" ]; then
      echo '{"machines":{}}' > "$machines_file"
    fi

    if $_has_jq; then
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
    elif $_has_python3; then
      # Pass all data via argv to avoid injection
      python3 -c "
import json, sys
machines_file = sys.argv[1]
machine_id = sys.argv[2]
machine_name = sys.argv[3]
os_type = sys.argv[4]
timestamp = sys.argv[5]
projects_json = sys.argv[6]
with open(machines_file) as f:
    data = json.load(f)
data.setdefault('machines', {})
data['machines'][machine_id] = {
    'name': machine_name,
    'os': os_type,
    'registered_at': timestamp,
    'last_sync': timestamp,
    'projects': json.loads(projects_json)
}
with open(machines_file, 'w') as f:
    json.dump(data, f, indent=2)
" "$machines_file" "$machine_id" "$machine_name" "$os_type" "$timestamp" "$projects"
    fi
  fi

  log_info "Machine registered: ${machine_name} (${machine_id})"
}

# Main
if [ "${1:-}" = "--help" ]; then
  echo "Usage: register-machine.sh <git-remote-url>"
  exit 0
fi

register_machine "${1:-}"
