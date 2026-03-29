#!/usr/bin/env bash
# merge-semantic.sh — LLM-powered semantic merge for unstructured brain data
# Uses claude -p with structured output for intelligent deduplication and conflict resolution
# Supports N-way merge: all machine snapshots merged in a single prompt
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

# First arg is output, rest are input files (base + other snapshots)
OUTPUT="$1"
shift
SNAPSHOTS=("$@")

CONFIDENCE_THRESHOLD=0.8
MAX_BUDGET="0.50"

# Load defaults
if [ -f "$DEFAULTS_FILE" ]; then
  CONFIDENCE_THRESHOLD=$(jq -r '.merge_confidence_threshold // 0.8' "$DEFAULTS_FILE")
  MAX_BUDGET=$(jq -r '.max_budget_usd // 0.50' "$DEFAULTS_FILE")
fi

if ! command -v claude &>/dev/null; then
  log_warn "claude CLI not found. Skipping semantic merge."
  exit 0
fi

# ── Extract content to merge ───────────────────────────────────────────────────

if [ ${#SNAPSHOTS[@]} -eq 0 ]; then
  log_info "No snapshots to merge."
  exit 0
fi

if [ ${#SNAPSHOTS[@]} -eq 1 ]; then
  log_info "Only one snapshot, no merge needed."
  cp "${SNAPSHOTS[0]}" "$OUTPUT"
  exit 0
fi

# Extract content from all machines
machine_list=""
claude_md_sections=""
memory_sections=""
all_content_hash=""

for snapshot_file in "${SNAPSHOTS[@]}"; do
  if [ ! -f "$snapshot_file" ]; then
    log_warn "Snapshot not found: $snapshot_file"
    continue
  fi
  
  # Extract machine info
  machine_name=$(jq -r '.machine.name // "unknown"' "$snapshot_file")
  machine_id=$(jq -r '.machine.id // "unknown"' "$snapshot_file")
  
  # Build machine list
  if [ -z "$machine_list" ]; then
    machine_list="Machines: $machine_name ($machine_id)"
  else
    machine_list="$machine_list, $machine_name ($machine_id)"
  fi
  
  # Extract CLAUDE.md content
  claude_md_content=$(jq -r '.declarative.claude_md.content // ""' "$snapshot_file")
  claude_md_sections="${claude_md_sections}

## CLAUDE.md from ${machine_name}:
\`\`\`
${claude_md_content}
\`\`\`"
  
  # Extract auto memory content  
  memory_content=$(jq -r '
    [.experiential.auto_memory // {} | to_entries[] |
     "## Project: \(.key)\n\(.value | to_entries[] | "\(.key):\n\(.value.content // "")")"] |
    join("\n\n")
  ' "$snapshot_file")
  
  memory_sections="${memory_sections}

## Memory from ${machine_name}:
\`\`\`
${memory_content}
\`\`\`"

  # Accumulate content for hash check
  all_content_hash="${all_content_hash}${claude_md_content}${memory_content}"
done

# ── Check if all content is identical ─────────────────────────────────────────
content_hash=$(echo "$all_content_hash" | compute_hash)
# Simple check: if only one unique content hash, skip merge
unique_hashes=()
for snapshot_file in "${SNAPSHOTS[@]}"; do
  snapshot_hash=$(jq -r '.declarative.claude_md.content // ""' "$snapshot_file" | compute_hash)
  if [[ ! " ${unique_hashes[*]} " =~ " ${snapshot_hash} " ]]; then
    unique_hashes+=("$snapshot_hash")
  fi
done

if [ ${#unique_hashes[@]} -eq 1 ]; then
  log_info "No semantic differences to merge - all content identical."
  cp "${SNAPSHOTS[0]}" "$OUTPUT"
  exit 0
fi

# ── Build merge prompt (use temp file to avoid ARG_MAX limits) ─────────────────
PROMPT_FILE=$(brain_mktemp)
sed "s|{{MACHINE_LIST}}|${machine_list}|g" "${PLUGIN_ROOT}/templates/merge-prompt.md" > "$PROMPT_FILE"
echo "$claude_md_sections" >> "$PROMPT_FILE"
echo "$memory_sections" >> "$PROMPT_FILE"

# ── JSON Schema for structured output ──────────────────────────────────────────
SCHEMA='{
  "type": "object",
  "properties": {
    "merged_claude_md": {
      "type": "string",
      "description": "The merged CLAUDE.md content"
    },
    "merged_memory_entries": {
      "type": "object",
      "description": "Merged memory organized by project name, each containing a MEMORY.md string",
      "additionalProperties": {
        "type": "string"
      }
    },
    "conflicts": {
      "type": "array",
      "items": {
        "type": "object",
        "properties": {
          "topic": { "type": "string" },
          "machine_a_says": { "type": "string" },
          "machine_b_says": { "type": "string" },
          "suggestion": { "type": "string" },
          "confidence": { "type": "number" }
        },
        "required": ["topic", "machine_a_says", "machine_b_says", "suggestion", "confidence"]
      }
    },
    "deduped": {
      "type": "array",
      "items": { "type": "string" },
      "description": "List of entries that were duplicated and removed"
    }
  },
  "required": ["merged_claude_md", "merged_memory_entries", "conflicts", "deduped"]
}'

# ── Call claude -p ─────────────────────────────────────────────────────────────
log_info "Running semantic merge via claude..."

RESULT=$(cat "$PROMPT_FILE" | claude -p - \
  --output-format json \
  --json-schema "$SCHEMA" \
  --model sonnet \
  --max-turns 1 \
  --max-budget-usd "$MAX_BUDGET" \
  2>/dev/null) || {
  log_warn "claude -p failed. Falling back to concatenation merge."
  # Fallback: use first snapshot as base, append others with markers
  base_snapshot="${SNAPSHOTS[0]}"
  cp "$base_snapshot" "$OUTPUT"
  
  # Collect unique CLAUDE.md content to append
  base_claude_md=$(jq -r '.declarative.claude_md.content // ""' "$base_snapshot")
  fallback_claude_md="$base_claude_md"
  
  for snapshot_file in "${SNAPSHOTS[@]:1}"; do
    machine_name=$(jq -r '.machine.name // "unknown"' "$snapshot_file")
    claude_md_content=$(jq -r '.declarative.claude_md.content // ""' "$snapshot_file")
    
    if [ -n "$claude_md_content" ] && [ "$claude_md_content" != "$base_claude_md" ]; then
      fallback_claude_md="${fallback_claude_md}

<!-- === Unmerged content from ${machine_name} === -->
${claude_md_content}"
    fi
  done
  
  # Update output with concatenated content
  tmp=$(brain_mktemp)
  jq --arg content "$fallback_claude_md" \
    '.declarative.claude_md.content = $content' "$OUTPUT" > "$tmp" && mv "$tmp" "$OUTPUT"
  exit 0
}

# ── Parse result and update brain ──────────────────────────────────────────────
merged_claude_md=$(echo "$RESULT" | jq -r '.structured_output.merged_claude_md // empty')
merged_memory=$(echo "$RESULT" | jq '.structured_output.merged_memory_entries // {}')
conflicts=$(echo "$RESULT" | jq '.structured_output.conflicts // []')
deduped=$(echo "$RESULT" | jq '.structured_output.deduped // []')

# Start with first snapshot as base, apply semantic merges
cp "${SNAPSHOTS[0]}" "$OUTPUT"

# Update CLAUDE.md
if [ -n "$merged_claude_md" ]; then
  tmp=$(brain_mktemp)
  jq --arg content "$merged_claude_md" \
    '.declarative.claude_md.content = $content | .declarative.claude_md.hash = "merged"' \
    "$OUTPUT" > "$tmp" && mv "$tmp" "$OUTPUT"
fi

# Update memory entries
if [ "$(echo "$merged_memory" | jq 'length')" -gt 0 ]; then
  tmp=$(brain_mktemp)
  echo "$merged_memory" | jq -r 'keys[]' | while read -r project; do
    content=$(echo "$merged_memory" | jq -r --arg p "$project" '.[$p]')
    jq --arg p "$project" --arg c "$content" \
      '.experiential.auto_memory[$p]["MEMORY.md"].content = $c | .experiential.auto_memory[$p]["MEMORY.md"].hash = "merged"' \
      "$OUTPUT" > "$tmp" && mv "$tmp" "$OUTPUT"
  done
fi

# Handle conflicts
conflict_count=$(echo "$conflicts" | jq 'length')
if [ "$conflict_count" -gt 0 ]; then
  # Auto-resolve high-confidence conflicts, save low-confidence ones
  conflicts_file="${HOME}/.claude/brain-conflicts.json"
  if [ ! -f "$conflicts_file" ]; then
    echo '{"conflicts":[]}' > "$conflicts_file"
  fi

  low_confidence=$(echo "$conflicts" | jq --arg t "$CONFIDENCE_THRESHOLD" \
    '[.[] | select(.confidence < ($t | tonumber))]')

  low_count=$(echo "$low_confidence" | jq 'length')
  if [ "$low_count" -gt 0 ]; then
    tmp=$(brain_mktemp)
    jq --argjson new "$low_confidence" \
      '.conflicts = (.conflicts + $new)' "$conflicts_file" > "$tmp"
    mv "$tmp" "$conflicts_file"
    log_warn "${low_count} conflict(s) need manual resolution. Run /brain-conflicts"
  fi

  auto_resolved=$((conflict_count - low_count))
  if [ "$auto_resolved" -gt 0 ]; then
    log_info "${auto_resolved} conflict(s) auto-resolved (high confidence)."
  fi
fi

# Log deduplication
dedup_count=$(echo "$deduped" | jq 'length')
if [ "$dedup_count" -gt 0 ]; then
  log_info "${dedup_count} duplicate entries removed."
fi

log_info "Semantic merge complete."
