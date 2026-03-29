#!/usr/bin/env bash
# import.sh — Apply consolidated brain state to local machine
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

INPUT="${1:-${BRAIN_REPO}/consolidated/brain.json}"
QUIET="${BRAIN_QUIET:-false}"
SKIP_VALIDATION=false
NO_BACKUP=false

# Parse extra flags
shift || true
while [ $# -gt 0 ]; do
  case "$1" in
    --skip-validation) SKIP_VALIDATION=true; shift ;;
    --no-backup) NO_BACKUP=true; shift ;;
    --quiet) QUIET=true; BRAIN_QUIET=true; shift ;;
    *) shift ;;
  esac
done

if [ ! -f "$INPUT" ]; then
  log_error "Consolidated brain not found: ${INPUT}"
  exit 1
fi

# ── Helper: write file if content differs ──────────────────────────────────────
write_if_changed() {
  local target="$1" content="$2"
  if [ -z "$content" ] || [ "$content" = "null" ]; then
    return 0
  fi
  mkdir -p "$(dirname "$target")"
  if [ -f "$target" ]; then
    local existing_hash new_hash
    existing_hash=$(file_hash "$target")
    new_hash=$(echo "$content" | compute_hash)
    if [ "$existing_hash" = "$new_hash" ]; then
      return 0  # No change
    fi
  fi
  echo "$content" > "$target"
  chmod 600 "$target"
  log_info "Updated: $target"
}

# ── Helper: import directory entries ───────────────────────────────────────────
import_dir_entries() {
  local base_dir="$1" json_entries="$2"
  if [ "$json_entries" = "{}" ] || [ "$json_entries" = "null" ]; then
    return 0
  fi

  # Resolve base_dir to absolute path for traversal check
  local resolved_base
  resolved_base=$(python3 -c "import os; print(os.path.realpath('$base_dir'))" 2>/dev/null || realpath "$base_dir" 2>/dev/null || echo "$base_dir")

    echo "$json_entries" | jq -r 'keys[]' | while read -r key; do
      # PATH TRAVERSAL CHECK: ensure key doesn't escape base_dir
      local resolved_target
      resolved_target=$(python3 -c "import os; print(os.path.realpath('${resolved_base}/${key}'))" 2>/dev/null || realpath "${resolved_base}/${key}" 2>/dev/null || echo "${resolved_base}/${key}")
      if [[ "$resolved_target" != "${resolved_base}/"* ]]; then
        log_warn "BLOCKED path traversal attempt: ${key} (would write outside ${base_dir})"
        continue
      fi

      local content
      content=$(echo "$json_entries" | jq -r --arg k "$key" '.[$k].content // empty')
      if [ -n "$content" ]; then
        write_if_changed "${resolved_base}/${key}" "$content"
      fi
    done
}

# ── Validate imported content ─────────────────────────────────────────────────
# Detect new or changed skills/agents/rules and log them
validate_imports() {
  local brain="$1"
  local new_items=()
  local changed_items=()


  # Check for new/changed skills
  echo "$brain" | jq -r '.procedural.skills // {} | keys[]' 2>/dev/null | while read -r skill_path; do
    local target="${CLAUDE_DIR}/skills/${skill_path}"
    if [ ! -f "$target" ]; then
      log_warn "NEW skill will be imported: ${skill_path}"
    else
      local new_content
      new_content=$(echo "$brain" | jq -r --arg k "$skill_path" '.procedural.skills[$k].content // empty')
      local new_hash existing_hash
      new_hash=$(echo "$new_content" | compute_hash)
      existing_hash=$(file_hash "$target")
      if [ "$new_hash" != "$existing_hash" ]; then
        log_warn "CHANGED skill will be updated: ${skill_path}"
      fi
    fi
  done

  # Check for new/changed agents
  echo "$brain" | jq -r '.procedural.agents // {} | keys[]' 2>/dev/null | while read -r agent_path; do
    local target="${CLAUDE_DIR}/agents/${agent_path}"
    if [ ! -f "$target" ]; then
      log_warn "NEW agent will be imported: ${agent_path}"
    else
      local new_content
      new_content=$(echo "$brain" | jq -r --arg k "$agent_path" '.procedural.agents[$k].content // empty')
      local new_hash existing_hash
      new_hash=$(echo "$new_content" | compute_hash)
      existing_hash=$(file_hash "$target")
      if [ "$new_hash" != "$existing_hash" ]; then
        log_warn "CHANGED agent will be updated: ${agent_path}"
      fi
    fi
  done

  # Check for new/changed rules
  echo "$brain" | jq -r '.declarative.rules // {} | keys[]' 2>/dev/null | while read -r rule_path; do
    local target="${CLAUDE_DIR}/rules/${rule_path}"
    if [ ! -f "$target" ]; then
      log_warn "NEW rule will be imported: ${rule_path}"
    fi
  done
}

# ── Import brain ───────────────────────────────────────────────────────────────
import_brain() {
  local brain
  brain=$(cat "$INPUT")

  log_info "Importing consolidated brain..."

  # Validate schema version
  local schema_ver
  schema_ver=$(echo "$brain" | jq -r '.schema_version // "unknown"')
  if [ "$schema_ver" != "1.0.0" ]; then
    log_error "Unsupported brain schema version: ${schema_ver}. Expected 1.0.0."
    log_error "You may need to update the claude-brain plugin."
    exit 1
  fi

  # Create backup before importing (unless disabled)
  if ! $NO_BACKUP; then
    backup_before_import || true
  fi

  # Validate imports (log new/changed items)
  if ! $SKIP_VALIDATION; then
    validate_imports "$brain"
  fi

  # Declarative: CLAUDE.md
    local claude_md_content
    claude_md_content=$(echo "$brain" | jq -r '.declarative.claude_md.content // empty')
    if [ -n "$claude_md_content" ]; then
      write_if_changed "${CLAUDE_DIR}/CLAUDE.md" "$claude_md_content"
    fi

  # Declarative: rules
    local rules
    rules=$(echo "$brain" | jq '.declarative.rules // {}')
    import_dir_entries "${CLAUDE_DIR}/rules" "$rules"

  # Procedural: skills
    local skills
    skills=$(echo "$brain" | jq '.procedural.skills // {}')
    import_dir_entries "${CLAUDE_DIR}/skills" "$skills"

  # Procedural: agents
    local agents
    agents=$(echo "$brain" | jq '.procedural.agents // {}')
    import_dir_entries "${CLAUDE_DIR}/agents" "$agents"

  # Procedural: output styles
    local output_styles
    output_styles=$(echo "$brain" | jq '.procedural.output_styles // {}')
    import_dir_entries "${CLAUDE_DIR}/output-styles" "$output_styles"

  # Experiential: auto memory
    echo "$brain" | jq -r '.experiential.auto_memory // {} | keys[]' 2>/dev/null | while read -r project; do
      local entries
      entries=$(echo "$brain" | jq --arg p "$project" '.experiential.auto_memory[$p] // {}')
      # Find matching project dir
      local target_dir=""
      if [ -d "${CLAUDE_DIR}/projects" ]; then
        for proj_dir in "${CLAUDE_DIR}"/projects/*/; do
          local name
          name=$(project_name_from_encoded "$(basename "$proj_dir")")
          if [ "$name" = "$project" ]; then
            target_dir="${proj_dir}memory"
            break
          fi
        done
      fi
      if [ -n "$target_dir" ]; then
        import_dir_entries "$target_dir" "$entries"
      fi
    done

  # Experiential: agent memory
    echo "$brain" | jq -r '.experiential.agent_memory // {} | keys[]' 2>/dev/null | while read -r agent; do
      # Sanitize agent name: block path traversal
      if echo "$agent" | grep -qE '(\.\.|/)'; then
        log_warn "BLOCKED suspicious agent name: ${agent}"
        continue
      fi
      local entries
      entries=$(echo "$brain" | jq --arg a "$agent" '.experiential.agent_memory[$a] // {}')
      import_dir_entries "${CLAUDE_DIR}/agent-memory/${agent}" "$entries"
    done

  # Environmental: settings (deep merge, preserve local env AND local mcpServers)
    local new_settings
    new_settings=$(echo "$brain" | jq '.environmental.settings.content // null')
    if [ "$new_settings" != "null" ] && [ -f "${CLAUDE_DIR}/settings.json" ]; then
      local tmp tmp_remote
      tmp=$(brain_mktemp)
      tmp_remote=$(brain_mktemp)
      printf '%s\n' "$new_settings" > "$tmp_remote"
      # Merge: keep local env and mcpServers, merge everything else from consolidated
      jq -s '.[0] as $local | .[1] as $remote |
        ($local.env // {}) as $local_env |
        ($local.mcpServers // {}) as $local_mcp |
        ($remote // {}) * $local | .env = $local_env | .mcpServers = $local_mcp' \
        "${CLAUDE_DIR}/settings.json" "$tmp_remote" > "$tmp"
      mv "$tmp" "${CLAUDE_DIR}/settings.json"
      chmod 600 "${CLAUDE_DIR}/settings.json"
      log_info "Updated: settings.json (merged, local env and mcpServers preserved)"
    elif [ "$new_settings" != "null" ] && [ ! -f "${CLAUDE_DIR}/settings.json" ]; then
      echo "$new_settings" > "${CLAUDE_DIR}/settings.json"
      chmod 600 "${CLAUDE_DIR}/settings.json"
      log_info "Created: settings.json"
    fi

  # Environmental: keybindings (union)
    local new_keybindings
    new_keybindings=$(echo "$brain" | jq '.environmental.keybindings.content // null')
    if [ "$new_keybindings" != "null" ]; then
      if [ -f "${CLAUDE_DIR}/keybindings.json" ]; then
        local tmp tmp_remote_kb
        tmp=$(brain_mktemp)
        tmp_remote_kb=$(brain_mktemp)
        printf '%s\n' "$new_keybindings" > "$tmp_remote_kb"
        # Union keybindings arrays (deduplicate by key+command)
        jq -s '.[0] + .[1] | unique_by(.key, .command)' "${CLAUDE_DIR}/keybindings.json" "$tmp_remote_kb" > "$tmp"
        mv "$tmp" "${CLAUDE_DIR}/keybindings.json"
        log_info "Updated: keybindings.json (merged)"
      else
        echo "$new_keybindings" > "${CLAUDE_DIR}/keybindings.json"
        log_info "Created: keybindings.json"
      fi
    fi

  # Shared namespace: import to local directories (skills, agents, rules)
    # Shared skills
    local shared_skills
    shared_skills=$(echo "$brain" | jq '.shared.skills // {}')
    import_dir_entries "${CLAUDE_DIR}/skills" "$shared_skills"

    # Shared agents
    local shared_agents
    shared_agents=$(echo "$brain" | jq '.shared.agents // {}')
    import_dir_entries "${CLAUDE_DIR}/agents" "$shared_agents"

    # Shared rules
    local shared_rules
    shared_rules=$(echo "$brain" | jq '.shared.rules // {}')
    import_dir_entries "${CLAUDE_DIR}/rules" "$shared_rules"

  log_info "Brain import complete."
}

import_brain
