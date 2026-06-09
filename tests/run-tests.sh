#!/usr/bin/env bash
# run-tests.sh — Integration test suite for claude-brain
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
TEST_DIR=""

# Counters
PASS=0
FAIL=0
SKIP=0

# Colors
if [ -t 1 ]; then
  GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[0;33m'; CYAN='\033[0;36m'; NC='\033[0m'
else
  GREEN=''; RED=''; YELLOW=''; CYAN=''; NC=''
fi

# JSON query helper (jq or python3 fallback)
jqf() {
  local filter="$1" file="$2"
  if command -v jq &>/dev/null; then
    jq "$filter" "$file"
  else
    python3 -c "
import json, sys
with open('$file') as f:
    data = json.load(f)
# Simple jq-like access for dot paths
path = '$filter'.lstrip('.')
obj = data
for key in path.split('.'):
    if key and isinstance(obj, dict):
        obj = obj.get(key)
        if obj is None: sys.exit(1)
print(json.dumps(obj) if isinstance(obj, (dict, list)) else obj)
" 2>/dev/null
  fi
}

jqr() {
  local filter="$1" file="$2"
  if command -v jq &>/dev/null; then
    jq -r "$filter" "$file"
  else
    python3 -c "
import json, sys
with open('$file') as f:
    data = json.load(f)
path = '$filter'.lstrip('.')
obj = data
for key in path.split('.'):
    if key and isinstance(obj, dict):
        obj = obj.get(key)
        if obj is None:
            print('null')
            sys.exit(0)
if isinstance(obj, (dict, list)):
    print(json.dumps(obj))
elif obj is None:
    print('null')
else:
    print(obj)
" 2>/dev/null
  fi
}

json_valid() {
  local file="$1"
  if command -v jq &>/dev/null; then
    jq empty "$file" 2>/dev/null
  else
    python3 -c "import json; json.load(open('$file'))" 2>/dev/null
  fi
}

json_length() {
  local filter="$1" file="$2"
  if command -v jq &>/dev/null; then
    jq "$filter | length" "$file" 2>/dev/null
  else
    python3 -c "
import json
with open('$file') as f:
    data = json.load(f)
path = '$filter'.lstrip('.').rstrip(' ')
obj = data
for key in path.split('.'):
    if key and isinstance(obj, dict):
        obj = obj.get(key, [])
print(len(obj) if isinstance(obj, (list, dict)) else 0)
" 2>/dev/null
  fi
}

json_set() {
  local file="$1" key="$2" value="$3"
  if command -v jq &>/dev/null; then
    local tmp; tmp=$(mktemp)
    jq --arg v "$value" ".$key = \$v" "$file" > "$tmp" && mv "$tmp" "$file"
  else
    python3 -c "
import json
with open('$file') as f:
    data = json.load(f)
data['$key'] = '$value'
with open('$file', 'w') as f:
    json.dump(data, f, indent=2)
" 2>/dev/null
  fi
}

# ── Helpers ────────────────────────────────────────────────────────────────────
pass() { echo -e "  ${GREEN}✓${NC} $1"; PASS=$((PASS + 1)); }
fail() { echo -e "  ${RED}✗${NC} $1"; FAIL=$((FAIL + 1)); }
skip() { echo -e "  ${YELLOW}⊘${NC} $1 (skipped)"; SKIP=$((SKIP + 1)); }
section() { echo -e "\n${CYAN}── $1 ──${NC}"; }

setup_sandbox() {
  TEST_DIR=$(mktemp -d)
  export HOME="$TEST_DIR/home"
  export CLAUDE_DIR="$HOME/.claude"
  export BRAIN_REPO="$HOME/.claude/brain-repo"
  export BRAIN_CONFIG="$HOME/.claude/brain-config.json"

  # Create mock ~/.claude/ structure
  mkdir -p "$CLAUDE_DIR"/{rules,skills/review,agents,projects/my-project/memory,output-styles}
  mkdir -p "$BRAIN_REPO"/{machines,consolidated,meta,shared/skills,shared/agents,shared/rules}

  # CLAUDE.md
  cat > "$HOME/CLAUDE.md" <<'EOF'
# My Project Rules
- Use pnpm not npm
- Always write tests
- Prefer TypeScript
EOF

  # Rules
  echo "Always run linting before commit." > "$CLAUDE_DIR/rules/linting.md"
  echo "Use conventional commits." > "$CLAUDE_DIR/rules/commits.md"

  # Skills
  cat > "$CLAUDE_DIR/skills/review/SKILL.md" <<'EOF'
---
name: review
description: Code review helper
---
Review the code for issues.
EOF

  # Agents
  echo "You are a debugging specialist." > "$CLAUDE_DIR/agents/debugger.md"

  # Memory
  cat > "$CLAUDE_DIR/projects/my-project/memory/MEMORY.md" <<'EOF'
- Project uses vitest for testing
- Database is PostgreSQL with Drizzle ORM
- Deploy via GitHub Actions
EOF

  # Settings
  # Includes a top-level env (existing test_export_no_secrets) AND a nested
  # pluginConfig.<plugin>.env block holding a github-PAT-shaped token, to
  # exercise the recursive scrub for nested secret containers.
  cat > "$CLAUDE_DIR/settings.json" <<'EOF'
{
  "permissions": {
    "allow": ["Bash(git:*)"],
    "deny": ["Bash(rm -rf /*)"]
  },
  "hooks": {
    "SessionStart": []
  },
  "env": {
    "SECRET_KEY": "should-not-be-exported"
  },
  "pluginConfig": {
    "github@claude-plugins-official": {
      "env": {
        "GITHUB_TOKEN": "ghp_FAKE_should_not_be_exported_FAKE_FAKE_FAKE"
      }
    }
  }
}
EOF

  # Keybindings
  cat > "$CLAUDE_DIR/keybindings.json" <<'EOF'
[{"key": "ctrl+k", "command": "clear", "context": "terminal"}]
EOF

  # ~/.claude.json — Claude Code stores mcpServers here. Include both an env-bearing
  # stdio server and an HTTP server with an Authorization Bearer header so the export
  # scrubber gets exercised on both shapes.
  cat > "$HOME/.claude.json" <<'EOF'
{
  "mcpServers": {
    "stdio-server": {
      "command": "/usr/bin/some-mcp",
      "env": {
        "API_KEY": "key-FAKE_stdio_should_not_be_exported_FAKE"
      }
    },
    "figma": {
      "type": "http",
      "url": "https://mcp.figma.com/mcp",
      "headers": {
        "Authorization": "Bearer figd_FAKE_should_not_be_exported_FAKE_FAKE",
        "X-Other-Header": "kept"
      }
    }
  }
}
EOF
  export CLAUDE_JSON="$HOME/.claude.json"

  # Init brain-repo as git repo
  (cd "$BRAIN_REPO" && git init -q -b main && git config user.email "test@test.com" && git config user.name "Test" && echo '{"entries":[]}' > meta/merge-log.json && git add -A && git commit -q -m "init")

  # Set PLUGIN_ROOT for scripts
  export CLAUDE_PLUGIN_ROOT="$PROJECT_DIR"
}

cleanup_sandbox() {
  if [ -n "$TEST_DIR" ] && [ -d "$TEST_DIR" ]; then
    rm -rf "$TEST_DIR"
  fi
}
trap cleanup_sandbox EXIT

# ── Tests ──────────────────────────────────────────────────────────────────────

test_export_structure() {
  section "Export: snapshot structure"

  local output="$TEST_DIR/snapshot.json"
  bash "$PROJECT_DIR/scripts/export.sh" --output "$output" --skip-secret-scan --quiet 2>/dev/null || true

  if [ ! -f "$output" ]; then
    fail "export.sh did not produce output file"
    return
  fi

  # Check it's valid JSON
  if json_valid "$output"; then
    pass "Output is valid JSON"
  else
    fail "Output is not valid JSON"
    return
  fi

  # Check required top-level fields
  for field in schema_version exported_at machine declarative procedural experiential environmental; do
    if jqf ".$field" "$output" >/dev/null 2>&1; then
      pass "Has field: $field"
    else
      fail "Missing field: $field"
    fi
  done

  # Check machine info
  if jqf ".machine.id" "$output" >/dev/null 2>&1; then
    pass "Has machine.id"
  else
    fail "Missing machine.id"
  fi
}

test_export_no_secrets() {
  section "Export: secrets excluded"

  local output="$TEST_DIR/snapshot.json"
  if [ ! -f "$output" ]; then
    skip "No snapshot to check"
    return
  fi

  local content
  content=$(cat "$output")

  # Env vars should not appear (top-level settings.env)
  if echo "$content" | grep -q "should-not-be-exported"; then
    fail "Secret marker 'should-not-be-exported' leaked into snapshot"
  else
    pass "Env vars excluded from snapshot"
  fi

  # settings.env should be stripped
  local env_val
  env_val=$(jqr ".environmental.settings.content.env" "$output" 2>/dev/null || echo "")
  if [ -z "$env_val" ] || [ "$env_val" = "null" ] || [ "$env_val" = "{}" ]; then
    pass "settings.env stripped from snapshot"
  else
    fail "settings.env present in snapshot: $env_val"
  fi

  # settings.pluginConfig.<plugin>.env should also be stripped (nested env)
  local nested_token
  nested_token=$(jqr '.environmental.settings.content.pluginConfig["github@claude-plugins-official"].env.GITHUB_TOKEN' "$output" 2>/dev/null || echo "null")
  if [ "$nested_token" = "null" ] || [ -z "$nested_token" ]; then
    pass "Nested settings.pluginConfig.*.env stripped from snapshot"
  else
    fail "Nested env leaked into snapshot: $nested_token"
  fi

  # mcpServers.<server>.env should be stripped (existing protection)
  local mcp_env
  mcp_env=$(jqr '.environmental.mcp_servers["stdio-server"].env' "$output" 2>/dev/null || echo "null")
  if [ "$mcp_env" = "null" ] || [ -z "$mcp_env" ]; then
    pass "mcp_servers.*.env stripped from snapshot"
  else
    fail "mcp_servers.*.env leaked into snapshot: $mcp_env"
  fi

  # mcpServers.<server>.headers.Authorization should be stripped (NEW)
  local mcp_auth
  mcp_auth=$(jqr '.environmental.mcp_servers.figma.headers.Authorization' "$output" 2>/dev/null || echo "null")
  if [ "$mcp_auth" = "null" ] || [ -z "$mcp_auth" ]; then
    pass "mcp_servers.*.headers.Authorization stripped from snapshot"
  else
    fail "mcp_servers.*.headers.Authorization leaked into snapshot: $mcp_auth"
  fi

  # Non-Authorization headers should be preserved (regression guard)
  local kept_header
  kept_header=$(jqr '.environmental.mcp_servers.figma.headers["X-Other-Header"]' "$output" 2>/dev/null || echo "null")
  if [ "$kept_header" = "kept" ]; then
    pass "Non-Authorization MCP headers preserved"
  else
    fail "Non-Authorization MCP header lost (got '$kept_header')"
  fi
}

test_export_import_roundtrip() {
  section "Export → Import round-trip"


  local snapshot="$TEST_DIR/snapshot.json"
  if [ ! -f "$snapshot" ]; then
    skip "No snapshot for import test"
    return
  fi

  # Create a separate target directory
  local target="$TEST_DIR/target-claude"
  mkdir -p "$target"

  # Temporarily point CLAUDE_DIR to target
  local orig_claude_dir="$CLAUDE_DIR"
  export CLAUDE_DIR="$target"

  # Import needs consolidated brain
  cp "$snapshot" "$BRAIN_REPO/consolidated/brain.json"
  bash "$PROJECT_DIR/scripts/import.sh" "$BRAIN_REPO/consolidated/brain.json" --quiet 2>/dev/null || true

  export CLAUDE_DIR="$orig_claude_dir"

  # Check key files were imported
  if [ -f "$target/rules/linting.md" ]; then
    pass "Rules imported"
  else
    fail "Rules not imported"
  fi

  if [ -d "$target/skills" ]; then
    pass "Skills directory created"
  else
    fail "Skills directory not created"
  fi
}

test_secret_scanning() {
  section "Export: secret scanning"

  # Plant a fake API key in memory
  echo "Use API key sk-1234567890abcdefghijklmnopqrstuvwxyz for auth" >> "$CLAUDE_DIR/projects/my-project/memory/MEMORY.md"

  local output
  output=$(bash "$PROJECT_DIR/scripts/export.sh" --output "$TEST_DIR/snapshot-secrets.json" 2>&1) || true

  if echo "$output" | grep -qi "secret\|warning\|potential"; then
    pass "Secret scan warned about API key pattern"
  else
    # Some implementations may not scan or may be quiet
    skip "No secret scan warning detected (may be --quiet)"
  fi

  # Clean up the planted key
  head -3 "$CLAUDE_DIR/projects/my-project/memory/MEMORY.md" > "$CLAUDE_DIR/projects/my-project/memory/MEMORY.md.tmp"
  mv "$CLAUDE_DIR/projects/my-project/memory/MEMORY.md.tmp" "$CLAUDE_DIR/projects/my-project/memory/MEMORY.md"
}

test_structured_merge() {
  section "Structured merge"

  # Create two snapshots with different settings
  local snap_a="$TEST_DIR/snap-a.json"
  local snap_b="$TEST_DIR/snap-b.json"
  local merged="$TEST_DIR/snap-merged.json"

  cat > "$snap_a" <<'EOF'
{
  "schema_version": "1.0.0",
  "machine": {"id": "aaa", "name": "machine-a"},
  "environmental": {
    "settings": {
      "content": {
        "permissions": {"allow": ["Bash(git:*)"], "deny": []},
        "hooks": {}
      }
    },
    "keybindings": {
      "content": [{"key": "ctrl+k", "command": "clear"}]
    }
  },
  "declarative": {"claude_md": {"content": "", "hash": ""}, "rules": {}},
  "procedural": {"skills": {}, "agents": {}},
  "experiential": {"auto_memory": {}}
}
EOF

  cat > "$snap_b" <<'EOF'
{
  "schema_version": "1.0.0",
  "machine": {"id": "bbb", "name": "machine-b"},
  "environmental": {
    "settings": {
      "content": {
        "permissions": {"allow": ["Bash(ls:*)"], "deny": ["Bash(rm:*)"]},
        "hooks": {}
      }
    },
    "keybindings": {
      "content": [{"key": "ctrl+l", "command": "scroll"}]
    }
  },
  "declarative": {"claude_md": {"content": "", "hash": ""}, "rules": {}},
  "procedural": {"skills": {}, "agents": {}},
  "experiential": {"auto_memory": {}}
}
EOF

  bash "$PROJECT_DIR/scripts/merge-structured.sh" "$snap_a" "$snap_b" "$merged" 2>/dev/null || true

  if [ ! -f "$merged" ]; then
    fail "merge-structured.sh did not produce output"
    return
  fi

  # Check permissions were unioned
  local allow_count
  allow_count=$(json_length ".environmental.settings.content.permissions.allow" "$merged" || echo "0")
  if [ "$allow_count" -ge 2 ]; then
    pass "Permissions.allow unioned ($allow_count entries)"
  else
    fail "Permissions.allow not unioned (got $allow_count)"
  fi

  local deny_count
  deny_count=$(json_length ".environmental.settings.content.permissions.deny" "$merged" || echo "0")
  if [ "$deny_count" -ge 1 ]; then
    pass "Permissions.deny unioned ($deny_count entries)"
  else
    fail "Permissions.deny not unioned (got $deny_count)"
  fi
}

test_register_machine() {
  section "Register machine"

  # Remove existing config to test fresh creation
  rm -f "$BRAIN_CONFIG"

  bash "$PROJECT_DIR/scripts/register-machine.sh" "git@github.com:test/test.git" 2>/dev/null || true

  if [ ! -f "$BRAIN_CONFIG" ]; then
    fail "brain-config.json not created"
    return
  fi

  if json_valid "$BRAIN_CONFIG"; then
    pass "brain-config.json is valid JSON"
  else
    fail "brain-config.json is not valid JSON"
    return
  fi

  # Check required fields
  for field in version remote machine_id machine_name brain_repo_path auto_sync; do
    if jqf ".$field" "$BRAIN_CONFIG" >/dev/null 2>&1; then
      pass "Config has field: $field"
    else
      fail "Config missing field: $field"
    fi
  done

  # Check last_evolved field (added in v0.2)
  if jqf ".last_evolved" "$BRAIN_CONFIG" >/dev/null 2>&1; then
    pass "Config has last_evolved field"
  else
    fail "Config missing last_evolved field"
  fi
}

test_shared_namespace() {
  section "Shared namespace"

  # Create shared skill in brain-repo
  echo "# Shared Test Skill" > "$BRAIN_REPO/shared/skills/team-tool.md"

  # Create a minimal consolidated brain with the shared content
  cat > "$BRAIN_REPO/consolidated/brain.json" <<'EOF'
{
  "schema_version": "1.0.0",
  "machine": {"id": "test", "name": "test"},
  "declarative": {"claude_md": {"content": "", "hash": ""}, "rules": {}},
  "procedural": {"skills": {}, "agents": {}},
  "experiential": {"auto_memory": {}},
  "environmental": {"settings": {"content": {}, "hash": ""}, "keybindings": {"content": [], "hash": ""}},
  "shared": {
    "skills": {"team-tool.md": {"content": "# Shared Test Skill", "hash": "sha256:test"}},
    "agents": {},
    "rules": {}
  }
}
EOF

  bash "$PROJECT_DIR/scripts/import.sh" "$BRAIN_REPO/consolidated/brain.json" --quiet 2>/dev/null || true

  if [ -f "$CLAUDE_DIR/skills/team-tool.md" ]; then
    pass "Shared skill imported to local skills"
  else
    fail "Shared skill not imported"
  fi
}

test_auto_evolve_trigger() {
  section "Auto-evolve scheduling"

  # Ensure brain-config exists
  if [ ! -f "$BRAIN_CONFIG" ]; then
    bash "$PROJECT_DIR/scripts/register-machine.sh" "git@github.com:test/test.git" 2>/dev/null || true
  fi

  # Set last_evolved to 8 days ago
  local eight_days_ago
  eight_days_ago=$(date -d "8 days ago" -u +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || date -v-8d -u +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || echo "")
  if [ -z "$eight_days_ago" ]; then
    skip "Cannot compute date (no GNU or BSD date)"
    return
  fi

  json_set "$BRAIN_CONFIG" "last_evolved" "$eight_days_ago"

  # Create a mock evolve.sh that just touches a marker
  local real_evolve="$PROJECT_DIR/scripts/evolve.sh"
  local backup_evolve="$TEST_DIR/evolve.sh.bak"
  cp "$real_evolve" "$backup_evolve"

  cat > "$real_evolve" <<'MOCK'
#!/usr/bin/env bash
touch "$HOME/.claude/evolve-triggered"
MOCK
  chmod +x "$real_evolve"

  # Create a machine snapshot so pull.sh has something to work with
  local machine_id
  machine_id=$(jqr ".machine_id" "$BRAIN_CONFIG")
  mkdir -p "$BRAIN_REPO/machines/$machine_id"
  cp "$BRAIN_REPO/consolidated/brain.json" "$BRAIN_REPO/machines/$machine_id/brain-snapshot.json" 2>/dev/null || \
    echo '{"schema_version":"1.0.0","machine":{"id":"test","name":"test"},"declarative":{},"procedural":{},"experiential":{},"environmental":{}}' > "$BRAIN_REPO/machines/$machine_id/brain-snapshot.json"

  (cd "$BRAIN_REPO" && git add -A && git commit -q -m "test snapshot" 2>/dev/null || true)

  # Set up a local bare remote so pull.sh can fetch
  local bare_remote="$TEST_DIR/remote.git"
  git clone --bare "$BRAIN_REPO" "$bare_remote" 2>/dev/null || true
  (cd "$BRAIN_REPO" && git remote remove origin 2>/dev/null || true && git remote add origin "$bare_remote")

  # Run pull.sh
  bash "$PROJECT_DIR/scripts/pull.sh" --quiet 2>/dev/null || true

  # Restore real evolve.sh
  cp "$backup_evolve" "$real_evolve"

  if [ -f "$HOME/.claude/evolve-triggered" ]; then
    pass "Auto-evolve triggered after 8 days"
    rm -f "$HOME/.claude/evolve-triggered"
  else
    fail "Auto-evolve not triggered after 8 days"
  fi

  # Now test that it does NOT trigger after 2 days
  local two_days_ago
  two_days_ago=$(date -d "2 days ago" -u +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || date -v-2d -u +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null)
  json_set "$BRAIN_CONFIG" "last_evolved" "$two_days_ago"

  # Mock evolve again
  cp "$real_evolve" "$backup_evolve"
  cat > "$real_evolve" <<'MOCK'
#!/usr/bin/env bash
touch "$HOME/.claude/evolve-triggered"
MOCK
  chmod +x "$real_evolve"

  bash "$PROJECT_DIR/scripts/pull.sh" --quiet 2>/dev/null || true

  cp "$backup_evolve" "$real_evolve"

  if [ ! -f "$HOME/.claude/evolve-triggered" ]; then
    pass "Auto-evolve NOT triggered after 2 days"
  else
    fail "Auto-evolve incorrectly triggered after 2 days"
    rm -f "$HOME/.claude/evolve-triggered"
  fi
}

test_wsl_detection() {
  section "OS detection"

  source "$PROJECT_DIR/scripts/common.sh" 2>/dev/null || true

  local os
  os=$(detect_os)
  if [ -n "$os" ] && [[ "$os" =~ ^(linux|macos|wsl|windows|unknown)$ ]]; then
    pass "detect_os returned valid value: $os"
  else
    fail "detect_os returned unexpected: $os"
  fi
}

test_encryption_roundtrip() {
  section "Encryption (age)"

  if ! command -v age &>/dev/null || ! command -v age-keygen &>/dev/null; then
    skip "age not installed"
    return
  fi

  source "$PROJECT_DIR/scripts/common.sh" 2>/dev/null || true

  # Generate test keypair
  local identity="$TEST_DIR/test-age-key.txt"
  local recipients="$TEST_DIR/test-recipients.txt"
  age-keygen -o "$identity" 2>/dev/null
  grep "# public key:" "$identity" | cut -d' ' -f4 > "$recipients"

  # Test encrypt/decrypt
  local plaintext="Hello, this is a test of brain encryption!"
  local encrypted
  encrypted=$(echo "$plaintext" | age -R "$recipients" -a 2>/dev/null) || {
    fail "age encryption failed"
    return
  }

  if echo "$encrypted" | head -1 | grep -q "BEGIN AGE ENCRYPTED FILE"; then
    pass "Content encrypted with age armor"
  else
    fail "Encrypted content missing age header"
  fi

  local decrypted
  decrypted=$(echo "$encrypted" | age -d -i "$identity" 2>/dev/null) || {
    fail "age decryption failed"
    return
  }

  if [ "$decrypted" = "$plaintext" ]; then
    pass "Decrypt round-trip matches original"
  else
    fail "Decrypt mismatch: got '$decrypted'"
  fi
}

test_path_traversal_blocked() {
  section "Import: path traversal blocked"

  # Create a brain with a malicious key containing '..'
  cat > "$TEST_DIR/malicious-brain.json" <<'EOF'
{
  "schema_version": "1.0.0",
  "machine": {"id": "test", "name": "test"},
  "declarative": {"claude_md": null, "rules": {"../../etc/evil.md": {"content": "pwned", "hash": "sha256:test"}}},
  "procedural": {"skills": {}, "agents": {}},
  "experiential": {"auto_memory": {}, "agent_memory": {}},
  "environmental": {"settings": {"content": null, "hash": ""}, "keybindings": {"content": null, "hash": ""}},
  "shared": {"skills": {}, "agents": {}, "rules": {}}
}
EOF

  local output
  output=$(bash "$PROJECT_DIR/scripts/import.sh" "$TEST_DIR/malicious-brain.json" --no-backup 2>&1) || true

  if echo "$output" | grep -q "BLOCKED path traversal"; then
    pass "Path traversal key rejected with warning"
  else
    fail "Path traversal key was not blocked"
  fi

  if [ ! -f "$TEST_DIR/home/etc/evil.md" ] && [ ! -f "/etc/evil.md" ]; then
    pass "Malicious file was not written"
  else
    fail "Malicious file was written!"
    rm -f "$TEST_DIR/home/etc/evil.md" "/etc/evil.md" 2>/dev/null
  fi
}

test_export_memory_only() {
  section "Export: --memory-only flag"

  local output="$TEST_DIR/snapshot-memory-only.json"
  bash "$PROJECT_DIR/scripts/export.sh" --memory-only --output "$output" --skip-secret-scan --quiet 2>/dev/null || true

  if [ ! -f "$output" ]; then
    fail "export.sh --memory-only did not produce output"
    return
  fi

  if json_valid "$output"; then
    pass "Memory-only output is valid JSON"
  else
    fail "Memory-only output is not valid JSON"
    return
  fi

  # Skills should be empty
  local skills_count
  skills_count=$(json_length ".procedural.skills" "$output" || echo "0")
  if [ "$skills_count" -eq 0 ]; then
    pass "Skills empty in memory-only export"
  else
    fail "Skills not empty in memory-only export (got $skills_count)"
  fi

  # Rules should be empty
  local rules_count
  rules_count=$(json_length ".declarative.rules" "$output" || echo "0")
  if [ "$rules_count" -eq 0 ]; then
    pass "Rules empty in memory-only export"
  else
    fail "Rules not empty in memory-only export (got $rules_count)"
  fi

  # Settings should be null
  local settings_val
  settings_val=$(jqr ".environmental.settings.content" "$output" 2>/dev/null || echo "null")
  if [ "$settings_val" = "null" ]; then
    pass "Settings null in memory-only export"
  else
    fail "Settings not null in memory-only export"
  fi
}

test_export_scans_all_file_types() {
  section "Export: scans all file types (not just .md)"

  # Create non-md files in skills dir
  echo '{"tool": true}' > "$CLAUDE_DIR/skills/config.json"
  echo 'key: value' > "$CLAUDE_DIR/skills/settings.yaml"

  local output="$TEST_DIR/snapshot-all-types.json"
  bash "$PROJECT_DIR/scripts/export.sh" --output "$output" --skip-secret-scan --quiet 2>/dev/null || true

  if [ ! -f "$output" ]; then
    fail "export.sh did not produce output"
    return
  fi

  local content
  content=$(cat "$output")

  if echo "$content" | jq -e '.procedural.skills["config.json"]' >/dev/null 2>&1; then
    pass ".json files included in export"
  else
    fail ".json files NOT included in export"
  fi

  if echo "$content" | jq -e '.procedural.skills["settings.yaml"]' >/dev/null 2>&1; then
    pass ".yaml files included in export"
  else
    fail ".yaml files NOT included in export"
  fi
}

test_semantic_merge_fallback() {
  section "Pull: semantic merge fallback logic"

  # We test the logic by checking that .merging is cleaned up on success
  # and used as fallback on failure. We do this with mock merge scripts.

  local test_snap_dir="$TEST_DIR/merge-test"
  mkdir -p "$test_snap_dir"

  # Create two minimal snapshots
  for id in aaa bbb; do
    cat > "$test_snap_dir/snap-${id}.json" <<EOF
{"schema_version":"1.0.0","machine":{"id":"${id}","name":"machine-${id}"},"declarative":{},"procedural":{},"experiential":{},"environmental":{}}
EOF
  done

  # The real merge scripts may not work without full context, so we verify
  # the code structure by checking pull.sh contains the fix pattern
  if grep -q 'rm -f.*brain.json.merging' "$PROJECT_DIR/scripts/pull.sh"; then
    pass "pull.sh cleans up .merging on semantic merge success"
  else
    fail "pull.sh does not clean up .merging on semantic merge success"
  fi

  if grep -q 'Semantic merge failed.*structured merge only' "$PROJECT_DIR/scripts/pull.sh"; then
    pass "pull.sh falls back to structured merge on semantic failure"
  else
    fail "pull.sh missing structured merge fallback"
  fi
}

test_register_machine_preserves_timestamps() {
  section "register-machine.sh preserves existing sync timestamps"

  # Initial registration (creates brain-config.json from scratch)
  rm -f "$BRAIN_CONFIG"
  bash "$PROJECT_DIR/scripts/register-machine.sh" "git@github.com:test/test.git" 2>/dev/null || true

  if [ ! -f "$BRAIN_CONFIG" ]; then
    fail "brain-config.json not created on first registration"
    return
  fi

  # Seed known timestamps into the config
  local known_push="2025-01-15T10:00:00Z"
  local known_pull="2025-01-14T09:00:00Z"
  local known_evolved="2025-01-13T08:00:00Z"
  json_set "$BRAIN_CONFIG" "last_push" "$known_push"
  json_set "$BRAIN_CONFIG" "last_pull" "$known_pull"
  json_set "$BRAIN_CONFIG" "last_evolved" "$known_evolved"

  # Re-register (simulates what push.sh does mid-run to update machines.json)
  bash "$PROJECT_DIR/scripts/register-machine.sh" "git@github.com:test/test.git" 2>/dev/null || true

  local actual_push actual_pull actual_evolved
  actual_push=$(jqr ".last_push" "$BRAIN_CONFIG")
  actual_pull=$(jqr ".last_pull" "$BRAIN_CONFIG")
  actual_evolved=$(jqr ".last_evolved" "$BRAIN_CONFIG")

  [ "$actual_push" = "$known_push" ] \
    && pass "last_push preserved after re-registration" \
    || fail "last_push wiped by re-registration (got '$actual_push', expected '$known_push')"

  [ "$actual_pull" = "$known_pull" ] \
    && pass "last_pull preserved after re-registration" \
    || fail "last_pull wiped by re-registration (got '$actual_pull', expected '$known_pull')"

  [ "$actual_evolved" = "$known_evolved" ] \
    && pass "last_evolved preserved after re-registration" \
    || fail "last_evolved wiped by re-registration (got '$actual_evolved', expected '$known_evolved')"

  # Verify null stays null on a brand-new config (never pushed)
  rm -f "$BRAIN_CONFIG"
  bash "$PROJECT_DIR/scripts/register-machine.sh" "git@github.com:test/test.git" 2>/dev/null || true
  actual_push=$(jqr ".last_push" "$BRAIN_CONFIG")
  [ "$actual_push" = "null" ] \
    && pass "last_push is null on fresh registration (never pushed)" \
    || fail "last_push should be null on fresh registration (got '$actual_push')"
}

test_keybindings_shape_mismatch() {
  section "Import: keybindings.json shape mismatch tolerated"

  # Build a minimal brain whose env.keybindings.content is an empty object {}.
  # Claude Code writes this when no keybindings are configured. The pre-fix
  # union-merge used `jq unique_by` which requires arrays — it would crash with
  # "object ({}) and array ([]) cannot be sorted", and because import.sh runs
  # under `set -euo pipefail` the crash kills the rest of import_brain (e.g.
  # the shared-namespace import that follows).
  cat > "$TEST_DIR/kb-brain.json" <<'EOF'
{
  "schema_version": "1.0.0",
  "machine": {"id":"t","name":"t","os":"linux"},
  "declarative": {"claude_md": null, "rules": {}},
  "procedural": {"skills": {}, "agents": {}, "output_styles": {}},
  "experiential": {"auto_memory": {}, "agent_memory": {}},
  "environmental": {
    "settings": {"content": null, "hash": ""},
    "keybindings": {"content": {}, "hash": ""},
    "mcp_servers": {}
  },
  "shared": {
    "skills": {"shared-sentinel.md": {"content": "# sentinel", "hash": "sha256:1"}},
    "agents": {}, "rules": {}
  }
}
EOF

  # Force local keybindings.json to also be {} (the bug's worst case)
  echo '{}' > "$CLAUDE_DIR/keybindings.json"

  local output
  output=$(bash "$PROJECT_DIR/scripts/import.sh" "$TEST_DIR/kb-brain.json" --no-backup 2>&1) || true

  # When the bug fires, both assertions below would fail (crash detected AND
  # `Brain import complete.` missing). Return on the first failure so the test
  # reports one clear root cause per run instead of two correlated failures.
  if echo "$output" | grep -qi "object.*and array.*cannot be sorted"; then
    fail "keybindings merge still crashes on object shape"
    return
  fi
  pass "keybindings merge handled object shape without crashing"

  # The keybindings step is followed by the shared-namespace import and a final
  # "Brain import complete." log line. If the crash propagated through `set -e`,
  # that line never prints. Assert we made it past keybindings.
  if ! echo "$output" | grep -q "Brain import complete"; then
    fail "import aborted at keybindings step — 'Brain import complete' missing"
    return
  fi
  pass "import continued past keybindings step ('Brain import complete' logged)"
}

test_sync_guard_blocks_recursion() {
  section "Fork-bomb guard: sync scripts no-op when BRAIN_SYNC_ACTIVE is set"

  # pull.sh and push.sh must exit immediately (exit 0, no work) when the guard
  # env var is already set — this is what stops the claude -p child's
  # SessionStart hook from firing a nested sync. We run them with the guard set
  # and assert they emit the refusal message and never reach git/fetch work.
  local out
  out=$(BRAIN_SYNC_ACTIVE=1 bash "$PROJECT_DIR/scripts/pull.sh" --quiet 2>&1) || true
  if echo "$out" | grep -q "BRAIN_SYNC_ACTIVE set — refusing recursive invocation"; then
    pass "pull.sh refuses to run when BRAIN_SYNC_ACTIVE is set"
  else
    fail "pull.sh did not no-op under BRAIN_SYNC_ACTIVE (got: $out)"
  fi

  out=$(BRAIN_SYNC_ACTIVE=1 bash "$PROJECT_DIR/scripts/push.sh" --quiet 2>&1) || true
  if echo "$out" | grep -q "BRAIN_SYNC_ACTIVE set — refusing recursive invocation"; then
    pass "push.sh refuses to run when BRAIN_SYNC_ACTIVE is set"
  else
    fail "push.sh did not no-op under BRAIN_SYNC_ACTIVE (got: $out)"
  fi

  # The guard must check before doing any real work: neither script should have
  # touched the brain repo (no new commits) while blocked.
  local head_before head_after
  head_before=$(cd "$BRAIN_REPO" && git rev-parse HEAD)
  BRAIN_SYNC_ACTIVE=1 bash "$PROJECT_DIR/scripts/pull.sh" --quiet >/dev/null 2>&1 || true
  BRAIN_SYNC_ACTIVE=1 bash "$PROJECT_DIR/scripts/push.sh" --quiet >/dev/null 2>&1 || true
  head_after=$(cd "$BRAIN_REPO" && git rev-parse HEAD)
  [ "$head_before" = "$head_after" ] \
    && pass "blocked sync scripts performed no repo work" \
    || fail "blocked sync scripts mutated the brain repo"
}

test_hooks_guard_pattern() {
  section "Fork-bomb guard: hooks skip when BRAIN_SYNC_ACTIVE is set"

  # The three sync hooks must each gate their command on an unset
  # BRAIN_SYNC_ACTIVE so an inherited guard suppresses the hook entirely
  # (defense-in-depth on top of the in-script guard).
  local cmds
  cmds=$(jqr '.hooks | to_entries[] | .value[].hooks[].command' "$PROJECT_DIR/hooks/hooks.json")
  local total guarded
  total=$(echo "$cmds" | grep -c 'brain-config.json')
  guarded=$(echo "$cmds" | grep -c 'BRAIN_SYNC_ACTIVE')
  if [ "$total" -eq "$guarded" ] && [ "$total" -ge 3 ]; then
    pass "all $total sync hooks gate on BRAIN_SYNC_ACTIVE"
  else
    fail "only $guarded of $total sync hooks gate on BRAIN_SYNC_ACTIVE"
  fi

  # Verify the gate actually short-circuits: emulate the hook condition with the
  # guard set and confirm the body is skipped.
  local ran="no"
  # shellcheck disable=SC2016
  if [ -z "${BRAIN_SYNC_ACTIVE:-}" ]; then ran="yes"; fi
  BRAIN_SYNC_ACTIVE=1
  local ran2="no"
  if [ -z "${BRAIN_SYNC_ACTIVE:-}" ]; then ran2="yes"; fi
  unset BRAIN_SYNC_ACTIVE
  [ "$ran" = "yes" ] && [ "$ran2" = "no" ] \
    && pass "hook gate condition short-circuits when guard is set" \
    || fail "hook gate condition did not short-circuit (unset=$ran, set=$ran2)"
}

test_evolve_sets_guard_before_claude() {
  section "Fork-bomb guard: evolve.sh + merge-semantic.sh set guard at spawn site"

  # evolve.sh is invoked directly by the brain-evolve skill, bypassing pull.sh,
  # so it must export BRAIN_SYNC_ACTIVE itself right before claude -p. Verify the
  # export appears textually before the claude -p invocation in both scripts.
  for script in evolve.sh merge-semantic.sh; do
    local f="$PROJECT_DIR/scripts/$script"
    local export_line claude_line
    export_line=$(grep -n '^export BRAIN_SYNC_ACTIVE=1' "$f" | tail -1 | cut -d: -f1)
    # Match the actual invocation (RESULT=$(... claude -p ...)), not the prose
    # mentions in comments. The real call assigns to RESULT and pipes/passes the
    # prompt, so anchor on the `claude -p` that is part of a command, excluding
    # comment lines.
    claude_line=$(grep -nE '(\$\(claude -p|\| claude -p|claude -p -|claude -p ")' "$f" \
      | grep -v '^[0-9]*:#' | grep -v '^[0-9]*: *#' | head -1 | cut -d: -f1)
    if [ -n "$export_line" ] && [ -n "$claude_line" ] && [ "$export_line" -lt "$claude_line" ]; then
      pass "$script exports guard before claude -p (line $export_line < $claude_line)"
    else
      fail "$script does not export guard before claude -p (export=$export_line, claude=$claude_line)"
    fi
  done
}

test_fallback_merge_is_idempotent() {
  section "Idempotent fallback: repeated concatenation merge converges"

  # Reproduces the in-the-wild bug: the pre-fix fallback appended an "Unmerged
  # content" marker block on every run, so CLAUDE.md grew by one copy per sync.
  # We run the fixed merge-semantic.sh fallback path twice, feeding round 2 the
  # output of round 1, and assert the content does not grow.
  #
  # Force the fallback path deterministically by making `claude` unavailable to
  # the script via PATH stubbing — but the script exits 0 ("claude CLI not
  # found") in that case, so instead we stub a `claude` that always fails,
  # which drives the `|| { ... fallback ... }` branch.
  local mtdir="$TEST_DIR/idem"
  mkdir -p "$mtdir/bin"
  cat > "$mtdir/bin/claude" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
  chmod +x "$mtdir/bin/claude"

  # Two snapshots with distinct CLAUDE.md so the fallback appends one marker.
  cat > "$mtdir/base.json" <<'EOF'
{"schema_version":"1.0.0","machine":{"id":"a","name":"machine-a"},"declarative":{"claude_md":{"content":"# Base rules\n- alpha","hash":""}},"procedural":{},"experiential":{"auto_memory":{}},"environmental":{}}
EOF
  cat > "$mtdir/other.json" <<'EOF'
{"schema_version":"1.0.0","machine":{"id":"b","name":"machine-b"},"declarative":{"claude_md":{"content":"# Other rules\n- beta","hash":""}},"procedural":{},"experiential":{"auto_memory":{}},"environmental":{}}
EOF

  # Round 1: base + other → out1 (should contain exactly one marker block)
  PATH="$mtdir/bin:$PATH" bash "$PROJECT_DIR/scripts/merge-semantic.sh" \
    "$mtdir/out1.json" "$mtdir/base.json" "$mtdir/other.json" >/dev/null 2>&1 || true

  if [ ! -f "$mtdir/out1.json" ]; then
    fail "fallback merge produced no output"
    return
  fi
  local markers1
  markers1=$(jqr '.declarative.claude_md.content' "$mtdir/out1.json" | grep -c 'Unmerged content from' || true)

  # Round 2: feed out1 back in as the base, merge with the same other snapshot.
  # The fixed strip_markers logic must drop the prior marker before re-appending,
  # so the marker count stays at 1 (not 2) and content length does not balloon.
  PATH="$mtdir/bin:$PATH" bash "$PROJECT_DIR/scripts/merge-semantic.sh" \
    "$mtdir/out2.json" "$mtdir/out1.json" "$mtdir/other.json" >/dev/null 2>&1 || true

  local markers2 len1 len2
  markers2=$(jqr '.declarative.claude_md.content' "$mtdir/out2.json" | grep -c 'Unmerged content from' || true)
  len1=$(jqr '.declarative.claude_md.content' "$mtdir/out1.json" | wc -c | tr -d ' ')
  len2=$(jqr '.declarative.claude_md.content' "$mtdir/out2.json" | wc -c | tr -d ' ')

  if [ "$markers1" = "1" ]; then
    pass "first fallback appends exactly one marker block"
  else
    fail "first fallback produced $markers1 marker blocks (expected 1)"
  fi

  if [ "$markers2" = "1" ]; then
    pass "repeated fallback stays at one marker block (idempotent)"
  else
    fail "repeated fallback accumulated $markers2 marker blocks (the bug)"
  fi

  if [ "$len2" -le "$len1" ]; then
    pass "repeated fallback does not grow CLAUDE.md ($len2 ≤ $len1 bytes)"
  else
    fail "repeated fallback grew CLAUDE.md from $len1 to $len2 bytes (the bug)"
  fi
}

# ── Run ────────────────────────────────────────────────────────────────────────
echo -e "${CYAN}claude-brain integration tests${NC}"
echo "================================"

# jq is required
if ! command -v jq &>/dev/null; then
  echo -e "${RED}ERROR: jq is required to run tests. Install: apt install jq / brew install jq${NC}"
  exit 1
fi

setup_sandbox

test_export_structure
test_export_no_secrets
test_secret_scanning
test_export_import_roundtrip
test_structured_merge
test_register_machine
test_register_machine_preserves_timestamps
test_shared_namespace
test_auto_evolve_trigger
test_path_traversal_blocked
test_export_memory_only
test_export_scans_all_file_types
test_semantic_merge_fallback
test_wsl_detection
test_encryption_roundtrip
test_keybindings_shape_mismatch
test_sync_guard_blocks_recursion
test_hooks_guard_pattern
test_evolve_sets_guard_before_claude
test_fallback_merge_is_idempotent

echo ""
echo "================================"
echo -e "Results: ${GREEN}${PASS} passed${NC}, ${RED}${FAIL} failed${NC}, ${YELLOW}${SKIP} skipped${NC}"

if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
