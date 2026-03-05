#!/usr/bin/env bash
# export.sh — Serialize local brain state to a JSON snapshot
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

MEMORY_ONLY=false
OUTPUT=""
QUIET=false
SKIP_SECRET_SCAN=false

while [ $# -gt 0 ]; do
  case "$1" in
    --memory-only) MEMORY_ONLY=true; shift ;;
    --output) OUTPUT="$2"; shift 2 ;;
    --quiet) QUIET=true; BRAIN_QUIET=true; shift ;;
    --skip-secret-scan) SKIP_SECRET_SCAN=true; shift ;;
    *) shift ;;
  esac
done

# ── Helper: read file content and hash ─────────────────────────────────────────
file_entry() {
  local filepath="$1"
  if [ ! -f "$filepath" ]; then
    echo "null"
    return
  fi

  # Size guard
  if ! check_file_size "$filepath"; then
    log_warn "Skipping oversized file: $filepath"
    echo "null"
    return
  fi

  local hash
  hash=$(file_hash "$filepath")

  jq -Rs --arg hash "sha256:${hash}" \
    '{"content": ., "hash": $hash}' < "$filepath"
}

# ── Helper: scan directory for files ───────────────────────────────────────────
scan_dir_entries() {
  local dir="$1"
  local result="{}"

  if [ ! -d "$dir" ]; then
    echo "{}"
    return
  fi

    result=$(find "$dir" -type f -name "*.md" 2>/dev/null | sort | while read -r f; do
      # Size guard per file
      if ! check_file_size "$f" 2>/dev/null; then
        continue
      fi
      local relpath
      relpath=$(realpath --relative-to="$dir" "$f" 2>/dev/null || echo "$(basename "$f")")
      local hash
      hash=$(file_hash "$f")
      # Use jq -Rs to safely read file content (handles all special chars)
      jq -Rs --arg key "$relpath" --arg hash "sha256:${hash}" \
        '{($key): {"content": ., "hash": $hash}}' < "$f"
    done | jq -s 'add // {}')
  echo "$result"
}

# ── Build snapshot ─────────────────────────────────────────────────────────────
build_snapshot() {
  local machine_id machine_name os_type timestamp
  machine_id=$(get_machine_id)
  [ -z "$machine_id" ] && machine_id="unregistered"
  machine_name=$(get_machine_name)
  os_type=$(detect_os)
  timestamp=$(now_iso)

  # Declarative
  local claude_md="null"
  if [ -f "${CLAUDE_DIR}/CLAUDE.md" ]; then
    claude_md=$(file_entry "${CLAUDE_DIR}/CLAUDE.md")
  fi

  local rules="{}"
  if [ -d "${CLAUDE_DIR}/rules" ]; then
    rules=$(scan_dir_entries "${CLAUDE_DIR}/rules")
  fi

  # Procedural
  local skills="{}"
  if [ -d "${CLAUDE_DIR}/skills" ]; then
    skills=$(scan_dir_entries "${CLAUDE_DIR}/skills")
  fi

  local agents="{}"
  if [ -d "${CLAUDE_DIR}/agents" ]; then
    agents=$(scan_dir_entries "${CLAUDE_DIR}/agents")
  fi

  local output_styles="{}"
  if [ -d "${CLAUDE_DIR}/output-styles" ]; then
    output_styles=$(scan_dir_entries "${CLAUDE_DIR}/output-styles")
  fi

  # Shared namespace (only if brain repo exists)
  local shared_skills="{}"
  local shared_agents="{}"
  local shared_rules="{}"
  if [ -d "${BRAIN_REPO}/shared" ]; then
    if [ -d "${BRAIN_REPO}/shared/skills" ]; then
      shared_skills=$(scan_dir_entries "${BRAIN_REPO}/shared/skills")
    fi
    if [ -d "${BRAIN_REPO}/shared/agents" ]; then
      shared_agents=$(scan_dir_entries "${BRAIN_REPO}/shared/agents")
    fi
    if [ -d "${BRAIN_REPO}/shared/rules" ]; then
      shared_rules=$(scan_dir_entries "${BRAIN_REPO}/shared/rules")
    fi
  fi

  # Experiential: auto memory
  local auto_memory="{}"
  if [ -d "${CLAUDE_DIR}/projects" ]; then
      auto_memory=$(find "${CLAUDE_DIR}/projects" -maxdepth 1 -mindepth 1 -type d 2>/dev/null | while read -r proj_dir; do
        local mem_dir="${proj_dir}/memory"
        if [ -d "$mem_dir" ] && [ "$(ls -A "$mem_dir" 2>/dev/null)" ]; then
          local encoded
          encoded=$(basename "$proj_dir")
          local name
          name=$(project_name_from_encoded "$encoded")
          local entries
          entries=$(scan_dir_entries "$mem_dir")
          jq -n --arg key "$name" --argjson val "$entries" '{($key): $val}'
        fi
      done | jq -s 'add // {}')
  fi

  # Experiential: agent memory
  local agent_memory="{}"
  if [ -d "${CLAUDE_DIR}/agent-memory" ]; then
      agent_memory=$(find "${CLAUDE_DIR}/agent-memory" -maxdepth 1 -mindepth 1 -type d 2>/dev/null | while read -r agent_dir; do
        local agent_name
        agent_name=$(basename "$agent_dir")
        local entries
        entries=$(scan_dir_entries "$agent_dir")
        if [ "$entries" != "{}" ]; then
          jq -n --arg key "$agent_name" --argjson val "$entries" '{($key): $val}'
        fi
      done | jq -s 'add // {}')
  fi

  # Environmental: settings (strip env vars AND mcpServers — MCP exported separately)
  local settings="null"
  if [ -f "${CLAUDE_DIR}/settings.json" ]; then
    settings=$(jq 'del(.env) | del(.mcpServers)' "${CLAUDE_DIR}/settings.json")
  fi

  local settings_hash="null"
  if [ "$settings" != "null" ]; then
    settings_hash=$(echo "$settings" | compute_hash)
  fi

  # Environmental: keybindings
  local keybindings="null"
  local keybindings_hash="null"
  if [ -f "${CLAUDE_DIR}/keybindings.json" ]; then
    keybindings=$(cat "${CLAUDE_DIR}/keybindings.json")
    keybindings_hash=$(file_hash "${CLAUDE_DIR}/keybindings.json")
  fi

  # Environmental: MCP servers (from settings.json mcpServers field)
  # SECURITY: Strip env fields from each server config (may contain API keys/tokens)
  local mcp_servers="{}"
  if [ -f "${CLAUDE_DIR}/settings.json" ]; then
    mcp_servers=$(jq '
      .mcpServers // {} |
      to_entries |
      map(.value = (.value | del(.env))) |
      from_entries
    ' "${CLAUDE_DIR}/settings.json" 2>/dev/null || echo "{}")
    # Rewrite absolute home paths to ${HOME}
    mcp_servers=$(echo "$mcp_servers" | sed "s|${HOME}|\${HOME}|g")
  fi

  # Assemble full snapshot
    jq -n \
      --arg schema_ver "1.0.0" \
      --arg ts "$timestamp" \
      --arg mid "$machine_id" \
      --arg mn "$machine_name" \
      --arg os "$os_type" \
      --argjson claude_md "${claude_md:-null}" \
      --argjson rules "$rules" \
      --argjson skills "$skills" \
      --argjson agents "$agents" \
      --argjson output_styles "$output_styles" \
      --argjson auto_memory "$auto_memory" \
      --argjson agent_memory "$agent_memory" \
      --argjson settings "${settings:-null}" \
      --arg settings_hash "${settings_hash}" \
      --argjson keybindings "${keybindings:-null}" \
      --arg keybindings_hash "${keybindings_hash}" \
      --argjson mcp_servers "$mcp_servers" \
      --argjson shared_skills "$shared_skills" \
      --argjson shared_agents "$shared_agents" \
      --argjson shared_rules "$shared_rules" \
      '{
        schema_version: $schema_ver,
        exported_at: $ts,
        machine: { id: $mid, name: $mn, os: $os },
        declarative: {
          claude_md: $claude_md,
          rules: $rules
        },
        procedural: {
          skills: $skills,
          agents: $agents,
          output_styles: $output_styles
        },
        experiential: {
          auto_memory: $auto_memory,
          agent_memory: $agent_memory
        },
        environmental: {
          settings: { content: $settings, hash: ("sha256:" + $settings_hash) },
          keybindings: { content: $keybindings, hash: ("sha256:" + $keybindings_hash) },
          mcp_servers: $mcp_servers
        },
        shared: {
          skills: $shared_skills,
          agents: $shared_agents,
          rules: $shared_rules
        }
      }'
}

# ── Main ───────────────────────────────────────────────────────────────────────
snapshot=$(build_snapshot)

# Size guard on full snapshot
snapshot_size=$(echo "$snapshot" | wc -c | tr -d ' ')
if [ "$snapshot_size" -gt "$MAX_SNAPSHOT_SIZE_BYTES" ]; then
  log_warn "Brain snapshot is very large (${snapshot_size} bytes). Consider cleaning up memory files."
fi

# Secret scanning
if ! $SKIP_SECRET_SCAN; then
  if ! echo "$snapshot" | scan_for_secrets 2>/dev/null; then
    log_warn "Potential secrets found in brain data. Export continues, but review the warnings above."
    log_warn "Pass --skip-secret-scan to suppress this check."
  fi
fi

# Compute top-level hash for quick change detection
snapshot_hash=$(echo "$snapshot" | compute_hash)

snapshot=$(echo "$snapshot" | jq --arg h "sha256:${snapshot_hash}" '. + {snapshot_hash: $h}')

if [ -n "$OUTPUT" ]; then
  if encryption_enabled && command -v age &>/dev/null; then
    # Encrypt the snapshot before writing
    encrypted_snapshot=$(encrypt_content "$snapshot") || {
      log_error "Failed to encrypt snapshot"
      exit 1
    }
    echo "$encrypted_snapshot" > "$OUTPUT"
    log_info "Brain snapshot exported (encrypted) to ${OUTPUT}"
  else
    echo "$snapshot" > "$OUTPUT"
    log_info "Brain snapshot exported to ${OUTPUT}"
  fi
  chmod 600 "$OUTPUT"
else
  # For stdout output, don't encrypt (caller handles)
  echo "$snapshot"
fi
