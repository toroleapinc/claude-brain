#!/usr/bin/env bash
# merge-structured.sh — Deterministic JSON merge for structured brain data
# Merges settings, keybindings, MCP servers, skills, agents, rules
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

BASE="$1"    # Base/consolidated brain JSON
OTHER="$2"   # Other machine's brain JSON
OUTPUT="$3"  # Output path for merged brain

if [ ! -f "$BASE" ] || [ ! -f "$OTHER" ]; then
  log_error "Input files not found."
  exit 1
fi


# Write to a temp file first: pull.sh passes the same path as BASE and OUTPUT,
# and `> "$OUTPUT"` would truncate BASE before jq reads it.
merged_tmp=$(brain_mktemp)

# Create a comprehensive merge using jq
jq -s '
def deep_merge:
  # Recursively merge two objects
  # Arrays are unioned (deduplicated), objects are recursively merged
  if (.[0] | type) == "object" and (.[1] | type) == "object" then
    .[0] as $a | .[1] as $b |
    ($a | keys) + ($b | keys) | unique | map(
      . as $key |
      if ($a | has($key)) and ($b | has($key)) then
        {($key): ([$a[$key], $b[$key]] | deep_merge)}
      elif ($a | has($key)) then
        {($key): $a[$key]}
      else
        {($key): $b[$key]}
      end
    ) | add // {}
  elif (.[0] | type) == "array" and (.[1] | type) == "array" then
    (.[0] + .[1]) | unique
  else
    # For scalar conflicts, prefer the second (other/newer)
    .[1] // .[0]
  end;

.[0] as $base | .[1] as $other |

# Merge declarative: CLAUDE.md kept from base (semantic merge handles this)
# Merge declarative: rules (union by filename)
($base.declarative.rules // {}) as $base_rules |
($other.declarative.rules // {}) as $other_rules |
($base_rules * $other_rules) as $merged_rules |

# Merge procedural: skills (union by name)
($base.procedural.skills // {}) as $base_skills |
($other.procedural.skills // {}) as $other_skills |
# For skills: if both have it and content differs, keep base (semantic merge handles conflicts)
# If only one has it, take it
([$base_skills, $other_skills] | add // {}) as $merged_skills |

# Merge procedural: agents (union by name)
($base.procedural.agents // {}) as $base_agents |
($other.procedural.agents // {}) as $other_agents |
([$base_agents, $other_agents] | add // {}) as $merged_agents |

# Merge procedural: output_styles (union)
($base.procedural.output_styles // {}) as $base_styles |
($other.procedural.output_styles // {}) as $other_styles |
([$base_styles, $other_styles] | add // {}) as $merged_styles |

# Merge environmental: settings (deep merge, arrays deduped)
($base.environmental.settings.content // {}) as $base_settings |
($other.environmental.settings.content // {}) as $other_settings |
([$base_settings, $other_settings] | deep_merge) as $merged_settings |

# Merge environmental: keybindings (deep merge)
($base.environmental.keybindings.content // {}) as $base_kb |
($other.environmental.keybindings.content // {}) as $other_kb |
([$base_kb, $other_kb] | deep_merge) as $merged_kb |

# Merge environmental: MCP servers (union by name)
($base.environmental.mcp_servers // {}) as $base_mcp |
($other.environmental.mcp_servers // {}) as $other_mcp |
($base_mcp * $other_mcp) as $merged_mcp |

# Merge experiential: auto_memory (union projects AND files within each project;
# same filename → other wins). MEMORY.md indexes are unioned line-by-line so
# entries added on either machine survive. Previously `add` replaced whole
# projects, dropping every memory file the base machine had for that project.
($base.experiential.auto_memory // {}) as $base_mem |
($other.experiential.auto_memory // {}) as $other_mem |
(($base_mem * $other_mem)
  | with_entries(
      .key as $p
      | ($base_mem[$p]["MEMORY.md"].content // null) as $bi
      | ($other_mem[$p]["MEMORY.md"].content // null) as $oi
      | if $bi != null and $oi != null and $bi != $oi then
          .value["MEMORY.md"] = {
            content: (reduce (($bi | split("\n")) + ($oi | split("\n")))[] as $l
                        ([]; if ($l != "" and any(.[]; . == $l)) then . else . + [$l] end)
                      | join("\n")),
            hash: "merged"
          }
        else . end
    )) as $merged_mem |

# Merge experiential: agent_memory (union agents, keep base content for semantic merge)
($base.experiential.agent_memory // {}) as $base_amem |
($other.experiential.agent_memory // {}) as $other_amem |
([$base_amem, $other_amem] | add // {}) as $merged_amem |

# Assemble merged brain
$base * {
  declarative: {
    claude_md: $base.declarative.claude_md,
    rules: $merged_rules
  },
  procedural: {
    skills: $merged_skills,
    agents: $merged_agents,
    output_styles: $merged_styles
  },
  experiential: {
    auto_memory: $merged_mem,
    agent_memory: $merged_amem
  },
  environmental: {
    settings: { content: $merged_settings, hash: "merged" },
    keybindings: { content: $merged_kb, hash: "merged" },
    mcp_servers: $merged_mcp
  }
}
' "$BASE" "$OTHER" > "$merged_tmp"
mv "$merged_tmp" "$OUTPUT"

log_info "Structured merge complete."
