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

  if [ ! -d "$dir" ]; then
    echo "{}"
    return
  fi

    local scan_result
    # Prune hidden dirs (.venv, .git, .cache), package dirs, and skip dotfiles + *.env
    # The dotfile exclusion is critical: .env files commonly hold API keys and must
    # never reach the brain snapshot (which is pushed to a Git remote).
    scan_result=$(find "$dir" \
        \( -type d \( -name ".*" -o -name "node_modules" -o -name "__pycache__" -o -name "venv" \) -prune \) \
        -o \( -type f ! -name ".*" ! -name "*.env" ! -name "*.pem" ! -name "*.key" -print \) \
        2>/dev/null | sort | while read -r f; do
      # Size guard per file
      if ! check_file_size "$f" 2>/dev/null; then
        continue
      fi
      local relpath
      relpath="${f#"$dir"/}"
      [ "$relpath" = "$f" ] && relpath="$(basename "$f")"
      local hash
      hash=$(file_hash "$f")
      # Use jq -Rs to safely read file content (handles all special chars)
      jq -Rs --arg key "$relpath" --arg hash "sha256:${hash}" \
        '{($key): {"content": ., "hash": $hash}}' < "$f"
    done | jq -s 'add // {}')
  echo "$scan_result"
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
  local rules="{}"
  # Procedural
  local skills="{}"
  local agents="{}"
  local output_styles="{}"
  # Shared namespace
  local shared_skills="{}"
  local shared_agents="{}"
  local shared_rules="{}"

  if ! $MEMORY_ONLY; then
    if [ -f "${CLAUDE_DIR}/CLAUDE.md" ]; then
      claude_md=$(file_entry "${CLAUDE_DIR}/CLAUDE.md")
    fi

    if [ -d "${CLAUDE_DIR}/rules" ]; then
      rules=$(scan_dir_entries "${CLAUDE_DIR}/rules")
    fi

    if [ -d "${CLAUDE_DIR}/skills" ]; then
      skills=$(scan_dir_entries "${CLAUDE_DIR}/skills")
    fi

    if [ -d "${CLAUDE_DIR}/agents" ]; then
      agents=$(scan_dir_entries "${CLAUDE_DIR}/agents")
    fi

    if [ -d "${CLAUDE_DIR}/output-styles" ]; then
      output_styles=$(scan_dir_entries "${CLAUDE_DIR}/output-styles")
    fi

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

  # Environmental: settings (strip env vars — mcpServers live in ~/.claude.json, not here)
  local settings="null"
  if ! $MEMORY_ONLY && [ -f "${CLAUDE_DIR}/settings.json" ]; then
    settings=$(jq 'del(.env)' "${CLAUDE_DIR}/settings.json")
  fi

  local settings_hash="null"
  if [ "$settings" != "null" ]; then
    settings_hash=$(echo "$settings" | compute_hash)
  fi

  # Environmental: keybindings
  local keybindings="null"
  local keybindings_hash="null"
  if ! $MEMORY_ONLY && [ -f "${CLAUDE_DIR}/keybindings.json" ]; then
    keybindings=$(cat "${CLAUDE_DIR}/keybindings.json")
    keybindings_hash=$(file_hash "${CLAUDE_DIR}/keybindings.json")
  fi

  # Environmental: MCP servers (from ~/.claude.json, NOT settings.json)
  # Claude Code stores mcpServers in ~/.claude.json (CLAUDE_JSON),
  # while settings.json only contains MCP policy fields.
  # SECURITY: Strip env fields from each server config (may contain API keys/tokens)
  local mcp_servers="{}"
  if ! $MEMORY_ONLY && [ -f "${CLAUDE_JSON}" ]; then
    mcp_servers=$(jq '
      .mcpServers // {} |
      to_entries |
      map(.value = (.value | del(.env))) |
      from_entries
    ' "${CLAUDE_JSON}" 2>/dev/null || echo "{}")
    # Rewrite absolute home paths to ${HOME}
    mcp_servers=$(echo "$mcp_servers" | sed "s|${HOME}|\${HOME}|g")
  fi

  # Assemble full snapshot
  # Route large JSON vars through temp files to avoid ARG_MAX (macOS ~256KB).
  local tmpdir
  tmpdir=$(mktemp -d)
  printf '%s' "${claude_md:-null}"          > "$tmpdir/claude_md.json"
  printf '%s' "${rules:-null}"              > "$tmpdir/rules.json"
  printf '%s' "${skills:-null}"             > "$tmpdir/skills.json"
  printf '%s' "${agents:-null}"             > "$tmpdir/agents.json"
  printf '%s' "${output_styles:-null}"      > "$tmpdir/output_styles.json"
  printf '%s' "${auto_memory:-null}"        > "$tmpdir/auto_memory.json"
  printf '%s' "${agent_memory:-null}"       > "$tmpdir/agent_memory.json"
  printf '%s' "${settings:-null}"           > "$tmpdir/settings.json"
  printf '%s' "${keybindings:-null}"        > "$tmpdir/keybindings.json"
  printf '%s' "${mcp_servers:-null}"        > "$tmpdir/mcp_servers.json"
  printf '%s' "${shared_skills:-null}"      > "$tmpdir/shared_skills.json"
  printf '%s' "${shared_agents:-null}"      > "$tmpdir/shared_agents.json"
  printf '%s' "${shared_rules:-null}"       > "$tmpdir/shared_rules.json"

  jq -n \
    --arg schema_ver "1.0.0" \
    --arg ts "$timestamp" \
    --arg mid "$machine_id" \
    --arg mn "$machine_name" \
    --arg os "$os_type" \
    --slurpfile claude_md     "$tmpdir/claude_md.json" \
    --slurpfile rules         "$tmpdir/rules.json" \
    --slurpfile skills        "$tmpdir/skills.json" \
    --slurpfile agents        "$tmpdir/agents.json" \
    --slurpfile output_styles "$tmpdir/output_styles.json" \
    --slurpfile auto_memory   "$tmpdir/auto_memory.json" \
    --slurpfile agent_memory  "$tmpdir/agent_memory.json" \
    --slurpfile settings      "$tmpdir/settings.json" \
    --arg settings_hash "${settings_hash}" \
    --slurpfile keybindings   "$tmpdir/keybindings.json" \
    --arg keybindings_hash "${keybindings_hash}" \
    --slurpfile mcp_servers   "$tmpdir/mcp_servers.json" \
    --slurpfile shared_skills "$tmpdir/shared_skills.json" \
    --slurpfile shared_agents "$tmpdir/shared_agents.json" \
    --slurpfile shared_rules  "$tmpdir/shared_rules.json" \
    '{
      schema_version: $schema_ver,
      exported_at: $ts,
      machine: { id: $mid, name: $mn, os: $os },
      declarative: {
        claude_md: $claude_md[0],
        rules: $rules[0]
      },
      procedural: {
        skills: $skills[0],
        agents: $agents[0],
        output_styles: $output_styles[0]
      },
      experiential: {
        auto_memory: $auto_memory[0],
        agent_memory: $agent_memory[0]
      },
      environmental: {
        settings: { content: $settings[0], hash: ("sha256:" + $settings_hash) },
        keybindings: { content: $keybindings[0], hash: ("sha256:" + $keybindings_hash) },
        mcp_servers: $mcp_servers[0]
      },
      shared: {
        skills: $shared_skills[0],
        agents: $shared_agents[0],
        rules: $shared_rules[0]
      }
    }'
  rm -rf "$tmpdir"
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
