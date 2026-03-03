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

  if $_has_jq; then
    jq -Rs --arg hash "sha256:${hash}" \
      '{"content": ., "hash": $hash}' < "$filepath"
  elif $_has_python3; then
    # Read file content via stdin to avoid injection
    python3 -c "
import json, sys
content = sys.stdin.read()
hash_val = sys.argv[1]
print(json.dumps({'content': content, 'hash': hash_val}))
" "sha256:${hash}" < "$filepath"
  fi
}

# ── Helper: scan directory for files ───────────────────────────────────────────
scan_dir_entries() {
  local dir="$1"
  local result="{}"

  if [ ! -d "$dir" ]; then
    echo "{}"
    return
  fi

  if $_has_jq; then
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
  elif $_has_python3; then
    # Python handles its own file reading safely
    result=$(python3 -c "
import os, json, hashlib, sys
d = sys.argv[1]
max_size = int(sys.argv[2])
result = {}
for root, dirs, files in os.walk(d):
    for f in sorted(files):
        if f.endswith('.md'):
            path = os.path.join(root, f)
            if os.path.getsize(path) > max_size:
                continue
            relpath = os.path.relpath(path, d)
            with open(path) as fh:
                content = fh.read()
            h = hashlib.sha256(content.encode()).hexdigest()
            result[relpath] = {'content': content, 'hash': f'sha256:{h}'}
print(json.dumps(result))
" "$dir" "$MAX_SINGLE_FILE_BYTES")
  fi
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

  # Experiential: auto memory
  local auto_memory="{}"
  if [ -d "${CLAUDE_DIR}/projects" ]; then
    if $_has_jq; then
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
    elif $_has_python3; then
      auto_memory=$(python3 -c "
import os, json, hashlib, sys
projects_dir = sys.argv[1]
max_size = int(sys.argv[2])
result = {}
if os.path.isdir(projects_dir):
    for encoded in sorted(os.listdir(projects_dir)):
        mem_dir = os.path.join(projects_dir, encoded, 'memory')
        if os.path.isdir(mem_dir) and os.listdir(mem_dir):
            # Decode: leading hyphen -> slash, double hyphens -> hyphen, single hyphens -> slash
            decoded = encoded
            if decoded.startswith('-'):
                decoded = '/' + decoded[1:]
            decoded = decoded.replace('--', '\x00').replace('-', '/').replace('\x00', '-')
            name = os.path.basename(decoded)
            entries = {}
            for f in sorted(os.listdir(mem_dir)):
                fp = os.path.join(mem_dir, f)
                if os.path.isfile(fp) and os.path.getsize(fp) <= max_size:
                    with open(fp) as fh:
                        content = fh.read()
                    h = hashlib.sha256(content.encode()).hexdigest()
                    entries[f] = {'content': content, 'hash': f'sha256:{h}'}
            if entries:
                result[name] = entries
print(json.dumps(result))
" "${CLAUDE_DIR}/projects" "$MAX_SINGLE_FILE_BYTES")
    fi
  fi

  # Experiential: agent memory
  local agent_memory="{}"
  if [ -d "${CLAUDE_DIR}/agent-memory" ]; then
    if $_has_jq; then
      agent_memory=$(find "${CLAUDE_DIR}/agent-memory" -maxdepth 1 -mindepth 1 -type d 2>/dev/null | while read -r agent_dir; do
        local agent_name
        agent_name=$(basename "$agent_dir")
        local entries
        entries=$(scan_dir_entries "$agent_dir")
        if [ "$entries" != "{}" ]; then
          jq -n --arg key "$agent_name" --argjson val "$entries" '{($key): $val}'
        fi
      done | jq -s 'add // {}')
    else
      agent_memory="{}"
    fi
  fi

  # Environmental: settings (strip env vars AND mcpServers — MCP exported separately)
  local settings="null"
  if [ -f "${CLAUDE_DIR}/settings.json" ]; then
    if $_has_jq; then
      settings=$(jq 'del(.env) | del(.mcpServers)' "${CLAUDE_DIR}/settings.json")
    elif $_has_python3; then
      settings=$(python3 -c "
import json, sys
with open(sys.argv[1]) as f:
    data = json.load(f)
data.pop('env', None)
data.pop('mcpServers', None)
print(json.dumps(data))
" "${CLAUDE_DIR}/settings.json")
    fi
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
  if [ -f "${CLAUDE_DIR}/settings.json" ] && $_has_jq; then
    mcp_servers=$(jq '
      .mcpServers // {} |
      to_entries |
      map(.value = (.value | del(.env))) |
      from_entries
    ' "${CLAUDE_DIR}/settings.json" 2>/dev/null || echo "{}")
    # Rewrite absolute home paths to ${HOME}
    mcp_servers=$(echo "$mcp_servers" | sed "s|${HOME}|\${HOME}|g")
  elif [ -f "${CLAUDE_DIR}/settings.json" ] && $_has_python3; then
    mcp_servers=$(python3 -c "
import json, sys, os
with open(sys.argv[1]) as f:
    data = json.load(f)
servers = data.get('mcpServers', {})
# Strip env from each server config
for name in servers:
    if isinstance(servers[name], dict):
        servers[name].pop('env', None)
# Rewrite home paths
home = os.path.expanduser('~')
result = json.dumps(servers)
result = result.replace(home, '\${HOME}')
print(result)
" "${CLAUDE_DIR}/settings.json")
  fi

  # Assemble full snapshot
  if $_has_jq; then
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
        }
      }'
  elif $_has_python3; then
    # Assemble via Python: write parts to a temp file to avoid shell expansion issues
    local parts_file
    parts_file=$(brain_mktemp)

    # Write each JSON component to the parts file safely (no shell expansion)
    python3 -c "
import json, sys
# Read component name-value pairs from argv (pairs of key, json_string)
parts = {}
args = sys.argv[1:]
i = 0
while i < len(args) - 1:
    key = args[i]
    val = args[i+1]
    try:
        parts[key] = json.loads(val) if val and val != 'null' else None
    except json.JSONDecodeError:
        parts[key] = None
    i += 2
with open(args[-1] if len(args) % 2 == 1 else '/dev/stdout', 'w') as f:
    json.dump(parts, f)
" \
      "claude_md" "$claude_md" \
      "rules" "$rules" \
      "skills" "$skills" \
      "agents" "$agents" \
      "output_styles" "$output_styles" \
      "auto_memory" "$auto_memory" \
      "agent_memory" "$agent_memory" \
      "settings" "${settings:-null}" \
      "keybindings" "${keybindings:-null}" \
      "mcp_servers" "$mcp_servers" \
      "$parts_file"

    # Now assemble the snapshot from the parts file
    python3 -c "
import json, sys
with open(sys.argv[1]) as f:
    parts = json.load(f)
snapshot = {
    'schema_version': '1.0.0',
    'exported_at': sys.argv[2],
    'machine': {'id': sys.argv[3], 'name': sys.argv[4], 'os': sys.argv[5]},
    'declarative': {
        'claude_md': parts.get('claude_md'),
        'rules': parts.get('rules', {})
    },
    'procedural': {
        'skills': parts.get('skills', {}),
        'agents': parts.get('agents', {}),
        'output_styles': parts.get('output_styles', {})
    },
    'experiential': {
        'auto_memory': parts.get('auto_memory', {}),
        'agent_memory': parts.get('agent_memory', {})
    },
    'environmental': {
        'settings': {'content': parts.get('settings'), 'hash': 'sha256:' + sys.argv[6]},
        'keybindings': {'content': parts.get('keybindings'), 'hash': 'sha256:' + sys.argv[7]},
        'mcp_servers': parts.get('mcp_servers', {})
    }
}
print(json.dumps(snapshot, indent=2))
" "$parts_file" "$timestamp" "$machine_id" "$machine_name" "$os_type" "$settings_hash" "$keybindings_hash"
  fi
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

if $_has_jq; then
  snapshot=$(echo "$snapshot" | jq --arg h "sha256:${snapshot_hash}" '. + {snapshot_hash: $h}')
fi

if [ -n "$OUTPUT" ]; then
  echo "$snapshot" > "$OUTPUT"
  chmod 600 "$OUTPUT"
  log_info "Brain snapshot exported to ${OUTPUT}"
else
  echo "$snapshot"
fi
