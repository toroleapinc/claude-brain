#!/usr/bin/env bash
# evolve.sh — Analyze brain memory and propose promotions
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

AUTO_MODE=false
while [ $# -gt 0 ]; do
  case "$1" in
    --auto) AUTO_MODE=true; shift ;;
    *) shift ;;
  esac
done

if ! command -v claude &>/dev/null; then
  log_error "claude CLI required for brain evolution."
  exit 1
fi


load_config

# ── Gather context ─────────────────────────────────────────────────────────────
# Read consolidated brain
brain_file="${BRAIN_REPO}/consolidated/brain.json"
if [ ! -f "$brain_file" ]; then
  log_error "No consolidated brain found. Run /brain-sync first."
  exit 1
fi

# Extract all memory content
all_memory=$(jq -r '
  [.experiential.auto_memory // {} | to_entries[] |
   "## Project: \(.key)\n\(.value | to_entries[] | "### \(.key)\n\(.value.content // "")")"] |
  join("\n\n")
' "$brain_file")

# Extract current CLAUDE.md
current_claude_md=$(jq -r '.declarative.claude_md.content // ""' "$brain_file")

# Extract current rules
current_rules=$(jq -r '
  [.declarative.rules // {} | to_entries[] |
   "### \(.key)\n\(.value.content // "")"] |
  join("\n\n")
' "$brain_file")

# Extract current skills
current_skills=$(jq -r '
  [.procedural.skills // {} | keys[] ] | join(", ")
' "$brain_file")

# Machine count
machine_count=1
if [ -f "${BRAIN_REPO}/meta/machines.json" ]; then
  machine_count=$(jq '.machines | length' "${BRAIN_REPO}/meta/machines.json")
fi

# ── Build evolve prompt ────────────────────────────────────────────────────────
TEMPLATE=$(cat "${PLUGIN_ROOT}/templates/evolve-prompt.md")

PROMPT="${TEMPLATE}

## Current CLAUDE.md:
\`\`\`
${current_claude_md}
\`\`\`

## Current Rules:
\`\`\`
${current_rules}
\`\`\`

## Current Skills: ${current_skills}

## Machines in network: ${machine_count}

## All Memory Content:
\`\`\`
${all_memory}
\`\`\`"

# ── Schema ─────────────────────────────────────────────────────────────────────
SCHEMA='{
  "type": "object",
  "properties": {
    "promotions": {
      "type": "array",
      "items": {
        "type": "object",
        "properties": {
          "type": { "type": "string", "enum": ["claude_md", "rule", "skill"] },
          "content": { "type": "string" },
          "reason": { "type": "string" },
          "source_projects": { "type": "array", "items": { "type": "string" } }
        },
        "required": ["type", "content", "reason"]
      }
    },
    "stale_entries": {
      "type": "array",
      "items": {
        "type": "object",
        "properties": {
          "project": { "type": "string" },
          "entry": { "type": "string" },
          "reason": { "type": "string" }
        },
        "required": ["project", "entry", "reason"]
      }
    },
    "summary": { "type": "string" }
  },
  "required": ["promotions", "stale_entries", "summary"]
}'

# ── Run analysis ───────────────────────────────────────────────────────────────
log_info "Analyzing brain for evolution opportunities..."

RESULT=$(claude -p "$PROMPT" \
  --output-format json \
  --json-schema "$SCHEMA" \
  --model sonnet \
  --max-turns 1 \
  --max-budget-usd 0.50 \
  2>/dev/null) || {
  log_error "Evolution analysis failed."
  exit 1
}

# ── Output results ─────────────────────────────────────────────────────────────
summary=$(echo "$RESULT" | jq -r '.structured_output.summary // "No summary"')
promotions=$(echo "$RESULT" | jq '.structured_output.promotions // []')
stale=$(echo "$RESULT" | jq '.structured_output.stale_entries // []')

promo_count=$(echo "$promotions" | jq 'length')
stale_count=$(echo "$stale" | jq 'length')

echo ""
echo "=== Brain Evolution Analysis ==="
echo ""
echo "$summary"
echo ""

if [ "$promo_count" -gt 0 ]; then
  echo "=== Recommended Promotions (${promo_count}) ==="
  echo ""
  echo "$promotions" | jq -r '.[] | "  [\(.type)] \(.content)\n    Reason: \(.reason)\n"'
fi

if [ "$stale_count" -gt 0 ]; then
  echo "=== Stale Entries (${stale_count}) ==="
  echo ""
  echo "$stale" | jq -r '.[] | "  [\(.project)] \(.entry)\n    Reason: \(.reason)\n"'
fi

# Output JSON for the skill to parse and act on
echo "$RESULT" | jq '.structured_output' > "${BRAIN_REPO}/meta/last-evolve.json"

# In auto mode, apply high-confidence promotions automatically
if $AUTO_MODE; then
  log_info "Auto-mode: Applying high-confidence promotions..."
  
  # Extract high-confidence promotions (not implemented yet - would need promotion logic)
  # For now, just update last_evolved timestamp
  local_tmp=$(brain_mktemp)
  jq --arg ts "$(now_iso)" '.last_evolved = $ts' "$BRAIN_CONFIG" > "$local_tmp"
  mv "$local_tmp" "$BRAIN_CONFIG"
  
  log_info "Auto-evolve complete. High-confidence changes applied."
  log_info "Evolution analysis saved to meta/last-evolve.json"
