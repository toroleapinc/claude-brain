#!/usr/bin/env bash
# merge-semantic.sh — LLM-powered semantic merge for unstructured brain data
# Uses claude -p with structured output for intelligent deduplication and conflict resolution
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

BASE="$1"    # Base/consolidated brain JSON
OTHER="$2"   # Other machine's brain JSON
OUTPUT="$3"  # Output path for merged brain

CONFIDENCE_THRESHOLD=0.8
MAX_BUDGET="0.50"

# Load defaults
if [ -f "$DEFAULTS_FILE" ] && $_has_jq; then
  CONFIDENCE_THRESHOLD=$(jq -r '.merge_confidence_threshold // 0.8' "$DEFAULTS_FILE")
  MAX_BUDGET=$(jq -r '.max_budget_usd // 0.50' "$DEFAULTS_FILE")
fi

if ! command -v claude &>/dev/null; then
  log_warn "claude CLI not found. Skipping semantic merge."
  exit 0
fi

# ── Extract content to merge ───────────────────────────────────────────────────
if ! $_has_jq; then
  log_warn "jq not available. Skipping semantic merge."
  exit 0
fi

# Extract CLAUDE.md content from both
base_claude_md=$(jq -r '.declarative.claude_md.content // ""' "$BASE")
other_claude_md=$(jq -r '.declarative.claude_md.content // ""' "$OTHER")

# Extract auto memory content
base_memory=$(jq -r '
  [.experiential.auto_memory // {} | to_entries[] |
   "## Project: \(.key)\n\(.value | to_entries[] | "\(.key):\n\(.value.content // "")")"] |
  join("\n\n")
' "$BASE")

other_memory=$(jq -r '
  [.experiential.auto_memory // {} | to_entries[] |
   "## Project: \(.key)\n\(.value | to_entries[] | "\(.key):\n\(.value.content // "")")"] |
  join("\n\n")
' "$OTHER")

# Extract machine names
base_machine=$(jq -r '.machine.name // "machine-a"' "$BASE")
other_machine=$(jq -r '.machine.name // "machine-b"' "$OTHER")

# ── Skip if content is identical ───────────────────────────────────────────────
base_hash=$(echo "${base_claude_md}${base_memory}" | compute_hash)
other_hash=$(echo "${other_claude_md}${other_memory}" | compute_hash)

if [ "$base_hash" = "$other_hash" ]; then
  log_info "No semantic differences to merge."
  cp "$BASE" "$OUTPUT"
  exit 0
fi

# ── Build merge prompt ─────────────────────────────────────────────────────────
MERGE_TEMPLATE=$(cat "${PLUGIN_ROOT}/templates/merge-prompt.md")

# Substitute placeholders
PROMPT=$(echo "$MERGE_TEMPLATE" | \
  sed "s|{{MACHINE_A}}|${base_machine}|g" | \
  sed "s|{{MACHINE_B}}|${other_machine}|g")

# Append the actual content
PROMPT="${PROMPT}

## CLAUDE.md from ${base_machine}:
\`\`\`
${base_claude_md}
\`\`\`

## CLAUDE.md from ${other_machine}:
\`\`\`
${other_claude_md}
\`\`\`

## Memory from ${base_machine}:
\`\`\`
${base_memory}
\`\`\`

## Memory from ${other_machine}:
\`\`\`
${other_memory}
\`\`\`"

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

RESULT=$(claude -p "$PROMPT" \
  --output-format json \
  --json-schema "$SCHEMA" \
  --model sonnet \
  --max-turns 1 \
  --max-budget-usd "$MAX_BUDGET" \
  2>/dev/null) || {
  log_warn "claude -p failed. Falling back to concatenation merge."
  # Fallback: concatenate both with markers
  if [ -n "$other_claude_md" ] && [ "$base_claude_md" != "$other_claude_md" ]; then
    fallback_claude_md="${base_claude_md}

<!-- === Unmerged content from ${other_machine} === -->
${other_claude_md}"
    jq --arg content "$fallback_claude_md" \
      '.declarative.claude_md.content = $content' "$BASE" > "$OUTPUT"
  else
    cp "$BASE" "$OUTPUT"
  fi
  exit 0
}

# ── Parse result and update brain ──────────────────────────────────────────────
merged_claude_md=$(echo "$RESULT" | jq -r '.structured_output.merged_claude_md // empty')
merged_memory=$(echo "$RESULT" | jq '.structured_output.merged_memory_entries // {}')
conflicts=$(echo "$RESULT" | jq '.structured_output.conflicts // []')
deduped=$(echo "$RESULT" | jq '.structured_output.deduped // []')

# Start with base brain, apply semantic merges
cp "$BASE" "$OUTPUT"

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
    local content
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
