#!/usr/bin/env bash
# merge-semantic.sh — LLM-powered semantic merge for unstructured brain data
# Uses claude -p with structured output for intelligent deduplication and conflict resolution
# Supports N-way merge: all machine snapshots merged in a single prompt
set -euo pipefail

# Fork-bomb note: this script runs the headless `claude -p` below, whose child
# process re-fires the brain-sync SessionStart hook. It is normally invoked as a
# child of pull.sh (which already exports BRAIN_SYNC_ACTIVE), but we re-export
# the guard defensively right before the claude -p call so the invariant "any
# claude -p we spawn runs with the guard set" holds at every spawn site.

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

# Per-run log: replaces the silent stderr discard with a structured record
# under ${BRAIN_RUNS_DIR}. run_log_init must NOT be captured via $(...) —
# that would isolate RUN_LOG_PATH in a subshell.
run_log_init "merge"
RUN_LOG="$RUN_LOG_PATH"
run_log_field "model" "sonnet"
run_log_field "max_turns" "10"
run_log_field "max_budget_usd" "$MAX_BUDGET"
run_log_field "snapshot_count" "${#SNAPSHOTS[@]}"
run_log_field "prompt_bytes" "$(wc -c < "$PROMPT_FILE" | tr -d ' ')"

# Publish our run-log path so a calling pull.sh can attach it to the merge-log
# entry. We only write when pull.sh handed us a PID-keyed marker via
# BRAIN_RUN_LOG_MARKER; a standalone invocation sets nothing, so it can never
# leave a stale marker for a later pull to misattribute. The marker lives
# outside the synced repo (machine-local diagnostics).
if [ -n "${BRAIN_RUN_LOG_MARKER:-}" ]; then
  echo "$RUN_LOG" > "$BRAIN_RUN_LOG_MARKER"
fi

# Guard at the spawn site (see header note): keep BRAIN_SYNC_ACTIVE in the env
# so the claude -p child inherits it and its SessionStart hook no-ops.
# --no-session-persistence keeps this headless one-shot out of the session list.
export BRAIN_SYNC_ACTIVE=1
STDERR_FILE=$(brain_mktemp)
start_epoch=$(date +%s)
EXIT_CODE=0
RESULT=$(cat "$PROMPT_FILE" | claude -p - \
  --no-session-persistence \
  --output-format json \
  --json-schema "$SCHEMA" \
  --model sonnet \
  --max-turns 10 \
  --max-budget-usd "$MAX_BUDGET" \
  2>"$STDERR_FILE") || EXIT_CODE=$?

run_log_field "duration_seconds" "$(( $(date +%s) - start_epoch ))"
run_log_field "exit_code" "$EXIT_CODE"
run_log_file   "stderr" "$STDERR_FILE"
run_log_blob   "response_json" "$RESULT"

if [ "$EXIT_CODE" -ne 0 ]; then
  log_warn "claude -p failed (exit $EXIT_CODE). See $RUN_LOG. Falling back to concatenation merge."
  # Fallback: use first snapshot as base, append others with markers.
  # Idempotency: strip any pre-existing "Unmerged content" sections from BOTH
  # the base and each incoming snapshot before comparison. Without this, every
  # fallback run grew CLAUDE.md by one marker block — it accumulated identical
  # copies across repeated syncs in the wild before this fix landed.
  base_snapshot="${SNAPSHOTS[0]}"
  cp "$base_snapshot" "$OUTPUT"

  # Strip everything from the first marker onward.
  strip_markers() {
    awk '/<!-- === Unmerged content from .* === -->/{exit} {print}' <<< "$1"
  }

  base_claude_md=$(jq -r '.declarative.claude_md.content // ""' "$base_snapshot")
  base_claude_md_clean=$(strip_markers "$base_claude_md")
  fallback_claude_md="$base_claude_md_clean"

  for snapshot_file in "${SNAPSHOTS[@]:1}"; do
    machine_name=$(jq -r '.machine.name // "unknown"' "$snapshot_file")
    claude_md_content=$(jq -r '.declarative.claude_md.content // ""' "$snapshot_file")
    claude_md_clean=$(strip_markers "$claude_md_content")

    if [ -n "$claude_md_clean" ] && [ "$claude_md_clean" != "$base_claude_md_clean" ]; then
      fallback_claude_md="${fallback_claude_md}

<!-- === Unmerged content from ${machine_name} === -->
${claude_md_clean}"
    fi
  done

  # Update output with concatenated content
  tmp=$(brain_mktemp)
  jq --arg content "$fallback_claude_md" \
    '.declarative.claude_md.content = $content' "$OUTPUT" > "$tmp" && mv "$tmp" "$OUTPUT"
  exit 0
fi

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
  echo "$merged_memory" | jq_lines 'keys[]' | while read -r project; do
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

run_log_section "summary"
{
  echo "conflicts: $conflict_count"
  echo "deduped: $dedup_count"
  echo "result: success"
} >> "$RUN_LOG_PATH"

log_info "Semantic merge complete."
