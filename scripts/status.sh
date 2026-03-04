#!/usr/bin/env bash
# status.sh — Show brain inventory and sync status
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

# ── Count helpers ──────────────────────────────────────────────────────────────
count_files() {
  local dir="$1" pattern="${2:-*.md}"
  if [ -d "$dir" ]; then
    find "$dir" -type f -name "$pattern" 2>/dev/null | wc -l | tr -d ' '
  else
    echo "0"
  fi
}

count_lines() {
  local file="$1"
  if [ -f "$file" ]; then
    wc -l < "$file" | tr -d ' '
  else
    echo "0"
  fi
}

count_memory_entries() {
  local total=0
  if [ -d "${CLAUDE_DIR}/projects" ]; then
    for proj_dir in "${CLAUDE_DIR}"/projects/*/memory; do
      if [ -d "$proj_dir" ]; then
        local count
        count=$(count_files "$proj_dir" "*")
        total=$((total + count))
      fi
    done
  fi
  echo "$total"
}

# ── Display ────────────────────────────────────────────────────────────────────
echo "=== Claude Brain Status ==="
echo ""

# Machine info
if is_initialized; then
  machine_id=$(get_config "machine_id")
  machine_name=$(get_config "machine_name")
  remote=$(get_config "remote")
  last_push=$(get_config "last_push")
  last_pull=$(get_config "last_pull")
  dirty=$(get_config "dirty" 2>/dev/null || echo "false")

  echo "Machine: ${machine_name} (${machine_id})"
  echo "Remote:  ${remote}"
  echo "Last push: ${last_push:-never}"
  echo "Last pull: ${last_pull:-never}"
  if [ "$dirty" = "true" ]; then
    echo "Status:  DIRTY (pending push from failed sync)"
  else
    echo "Status:  Clean"
  fi

  # Network info
  if [ -f "${BRAIN_REPO}/meta/machines.json" ]; then
    machine_count=$(jq '.machines | length' "${BRAIN_REPO}/meta/machines.json")
    echo "Network: ${machine_count} machine(s)"
    jq -r '.machines | to_entries[] | "  - \(.value.name) (\(.key)) last sync: \(.value.last_sync // "never")"' \
      "${BRAIN_REPO}/meta/machines.json"
  fi
else
  echo "Machine: $(get_machine_name)"
  echo "Status:  NOT INITIALIZED (run /brain-init)"
fi

echo ""
echo "=== Brain Inventory ==="
echo ""

# Declarative
echo "Declarative Knowledge:"
claude_md_lines=$(count_lines "${CLAUDE_DIR}/CLAUDE.md")
echo "  CLAUDE.md:      ${claude_md_lines} lines"
rules_count=$(count_files "${CLAUDE_DIR}/rules")
echo "  Rules:          ${rules_count} files"

echo ""

# Procedural
echo "Procedural Knowledge:"
skills_count=$(count_files "${CLAUDE_DIR}/skills" "SKILL.md")
echo "  Skills:         ${skills_count}"
agents_count=$(count_files "${CLAUDE_DIR}/agents")
echo "  Agents:         ${agents_count}"
styles_count=$(count_files "${CLAUDE_DIR}/output-styles")
echo "  Output styles:  ${styles_count}"

echo ""

# Experiential
echo "Experiential Knowledge:"
memory_files=$(count_memory_entries)
echo "  Memory files:   ${memory_files} (across all projects)"

# List projects with memory
if [ -d "${CLAUDE_DIR}/projects" ]; then
  for proj_dir in "${CLAUDE_DIR}"/projects/*/; do
    if [ -d "${proj_dir}memory" ] && [ "$(ls -A "${proj_dir}memory" 2>/dev/null)" ]; then
      local_name=$(project_name_from_encoded "$(basename "$proj_dir")")
      local_count=$(count_files "${proj_dir}memory" "*")
      echo "    ${local_name}: ${local_count} files"
    fi
  done
fi

agent_mem_count=0
if [ -d "${CLAUDE_DIR}/agent-memory" ]; then
  agent_mem_count=$(find "${CLAUDE_DIR}/agent-memory" -type f 2>/dev/null | wc -l | tr -d ' ')
fi
echo "  Agent memory:   ${agent_mem_count} files"

echo ""

# Environmental
echo "Environmental:"
if [ -f "${CLAUDE_DIR}/settings.json" ]; then
  echo "  settings.json:  present"
else
  echo "  settings.json:  not found"
fi
if [ -f "${CLAUDE_DIR}/keybindings.json" ]; then
  echo "  keybindings:    present"
else
  echo "  keybindings:    not found"
fi

echo ""

# Conflicts
conflicts_file="${HOME}/.claude/brain-conflicts.json"
if [ -f "$conflicts_file" ]; then
  unresolved=$(jq '[.conflicts[] | select(.resolved != true)] | length' "$conflicts_file")
  if [ "$unresolved" -gt 0 ]; then
    echo "=== Conflicts ==="
    echo "  ${unresolved} unresolved conflict(s). Run /brain-conflicts to resolve."
  fi
fi

# ── Sync Statistics ────────────────────────────────────────────────────────────
if [ -f "${BRAIN_REPO}/meta/machines.json" ]; then
  echo "=== Sync Statistics ==="
  echo ""
  
  # Count total syncs (entries in machines.json)
  total_syncs=$(jq '.machines | to_entries | map(.value.last_sync | select(. != null)) | length' "${BRAIN_REPO}/meta/machines.json")
  echo "Total syncs: ${total_syncs}"
  
  # Get machine count
  machine_count=$(jq '.machines | length' "${BRAIN_REPO}/meta/machines.json")
  echo "Machines synced: ${machine_count}"
  
  # Get first and last sync dates
  first_sync=$(jq -r '[.machines[] | .last_sync] | map(select(. != null)) | sort | first' "${BRAIN_REPO}/meta/machines.json")
  last_sync=$(jq -r '[.machines[] | .last_sync] | map(select(. != null)) | sort | last' "${BRAIN_REPO}/meta/machines.json")
  
  if [ "$first_sync" != "null" ] && [ -n "$first_sync" ]; then
    echo "First sync: ${first_sync%%T*}"
  else
    echo "First sync: N/A"
  fi
  
  if [ "$last_sync" != "null" ] && [ -n "$last_sync" ]; then
    echo "Last sync: ${last_sync%%T*}"
  else
    echo "Last sync: N/A"
  fi
  
  echo ""
fi
