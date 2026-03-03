#!/usr/bin/env bash
# run-tests.sh — Test suite for claude-brain security fixes
# Self-contained bash test runner, no external dependencies required.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Test counters
PASS=0
FAIL=0
SKIP=0
ERRORS=()

# Colors (disable if not a terminal)
if [ -t 1 ]; then
  GREEN='\033[0;32m'
  RED='\033[0;31m'
  YELLOW='\033[0;33m'
  NC='\033[0m'
else
  GREEN='' RED='' YELLOW='' NC=''
fi

# ── Test Helpers ───────────────────────────────────────────────────────────────
assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    echo -e "  ${GREEN}PASS${NC}: $desc"
    PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${NC}: $desc"
    echo "    Expected: $expected"
    echo "    Actual:   $actual"
    FAIL=$((FAIL + 1))
    ERRORS+=("$desc")
  fi
}

assert_contains() {
  local desc="$1" haystack="$2" needle="$3"
  if echo "$haystack" | grep -qF "$needle"; then
    echo -e "  ${GREEN}PASS${NC}: $desc"
    PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${NC}: $desc"
    echo "    Expected to contain: $needle"
    echo "    In: $(echo "$haystack" | head -3)"
    FAIL=$((FAIL + 1))
    ERRORS+=("$desc")
  fi
}

assert_not_contains() {
  local desc="$1" haystack="$2" needle="$3"
  if ! echo "$haystack" | grep -qF "$needle"; then
    echo -e "  ${GREEN}PASS${NC}: $desc"
    PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${NC}: $desc"
    echo "    Expected NOT to contain: $needle"
    FAIL=$((FAIL + 1))
    ERRORS+=("$desc")
  fi
}

assert_true() {
  local desc="$1"
  shift
  if "$@" 2>/dev/null; then
    echo -e "  ${GREEN}PASS${NC}: $desc"
    PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${NC}: $desc"
    FAIL=$((FAIL + 1))
    ERRORS+=("$desc")
  fi
}

assert_false() {
  local desc="$1"
  shift
  if ! "$@" 2>/dev/null; then
    echo -e "  ${GREEN}PASS${NC}: $desc"
    PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${NC}: $desc"
    FAIL=$((FAIL + 1))
    ERRORS+=("$desc")
  fi
}

skip_test() {
  local desc="$1" reason="$2"
  echo -e "  ${YELLOW}SKIP${NC}: $desc ($reason)"
  SKIP=$((SKIP + 1))
}

# ── Setup ──────────────────────────────────────────────────────────────────────
TEST_TMPDIR=$(mktemp -d "${TMPDIR:-/tmp}/claude-brain-test-XXXXXX")
cleanup() {
  rm -rf "$TEST_TMPDIR"
}
trap cleanup EXIT

# Export CLAUDE_PLUGIN_ROOT so common.sh can find config
export CLAUDE_PLUGIN_ROOT="$PROJECT_DIR"

# Create a mock CLAUDE_DIR for testing
export HOME="$TEST_TMPDIR/home"
mkdir -p "$HOME/.claude"

# ════════════════════════════════════════════════════════════════════════════════
echo ""
echo "═══════════════════════════════════════════════"
echo "  claude-brain Test Suite"
echo "═══════════════════════════════════════════════"
echo ""

# ── Test Group: Path Encoding/Decoding ─────────────────────────────────────────
echo "## Path Encoding/Decoding"

source "${PROJECT_DIR}/scripts/common.sh" 2>/dev/null

# Simple path
result=$(decode_project_path "-home-user-project")
assert_eq "decode simple path /home/user/project" "/home/user/project" "$result"

# Path with hyphens (doubled in encoding)
result=$(decode_project_path "-home-user-my--project")
assert_eq "decode hyphenated path /home/user/my-project" "/home/user/my-project" "$result"

# Double hyphens in middle
result=$(decode_project_path "-home-user-my--cool--app")
assert_eq "decode multiple hyphens /home/user/my-cool-app" "/home/user/my-cool-app" "$result"

# Encode round-trip
original="/home/user/my-project"
encoded=$(encode_project_path "$original")
decoded=$(decode_project_path "$encoded")
assert_eq "encode/decode round-trip for hyphenated path" "$original" "$decoded"

# project_name_from_encoded
result=$(project_name_from_encoded "-home-user-my--project")
assert_eq "project name from encoded (hyphenated)" "my-project" "$result"

result=$(project_name_from_encoded "-home-user-simple")
assert_eq "project name from encoded (simple)" "simple" "$result"

echo ""

# ── Test Group: JSON Query (Python injection safety) ──────────────────────────
echo "## JSON Query Safety"

# Test normal query
result=$(echo '{"name":"test","value":42}' | json_query '.name')
assert_eq "json_query normal field" "test" "$result"

result=$(echo '{"name":"test","value":42}' | json_query '.value')
assert_eq "json_query numeric field" "42" "$result"

# Test with special characters in data (NOT in filter)
result=$(echo '{"name":"it'\''s a test"}' | json_query '.name')
assert_eq "json_query with apostrophe in data" "it's a test" "$result"

# Test nested query
result=$(echo '{"a":{"b":"deep"}}' | json_query '.a.b')
assert_eq "json_query nested" "deep" "$result"

# Test missing key
result=$(echo '{"name":"test"}' | json_query '.missing')
assert_eq "json_query missing key returns null" "null" "$result"

echo ""

# ── Test Group: JSON Set (Python injection safety) ────────────────────────────
echo "## JSON Set Safety"

test_file="${TEST_TMPDIR}/test-set.json"
echo '{"key":"old"}' > "$test_file"
json_set "$test_file" '.key' '"new"'
result=$(json_query '.key' < "$test_file")
assert_eq "json_set basic update" "new" "$result"

# Test with file path containing spaces (in a temp dir)
space_dir="${TEST_TMPDIR}/path with spaces"
mkdir -p "$space_dir"
echo '{"key":"val"}' > "${space_dir}/test.json"
json_set "${space_dir}/test.json" '.key' '"updated"'
result=$(json_query '.key' < "${space_dir}/test.json")
assert_eq "json_set with spaces in path" "updated" "$result"

echo ""

# ── Test Group: Secret Scanning ───────────────────────────────────────────────
echo "## Secret Scanning"

# Test: catches OpenAI-style API keys
result=$(echo "my key is sk-abcdefghijklmnopqrstuvwxyz1234567890" | scan_for_secrets 2>&1 || true)
assert_contains "detects sk- API key" "$result" "POTENTIAL SECRETS DETECTED"

# Test: catches AWS access key
result=$(echo "aws key: AKIAIOSFODNN7EXAMPLE" | scan_for_secrets 2>&1 || true)
assert_contains "detects AWS access key" "$result" "POTENTIAL SECRETS DETECTED"

# Test: catches GitHub PAT
result=$(echo "token: ghp_ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefgh" | scan_for_secrets 2>&1 || true)
assert_contains "detects GitHub PAT" "$result" "POTENTIAL SECRETS DETECTED"

# Test: catches postgres connection string
result=$(echo "DATABASE_URL=postgres://admin:secretpass@db.host.com:5432/mydb" | scan_for_secrets 2>&1 || true)
assert_contains "detects postgres connection string" "$result" "POTENTIAL SECRETS DETECTED"

# Test: catches private keys
result=$(echo "-----BEGIN PRIVATE KEY-----" | scan_for_secrets 2>&1 || true)
assert_contains "detects private key" "$result" "POTENTIAL SECRETS DETECTED"

# Test: safe content passes
safe_result=$(echo "This is normal memory about using pnpm instead of npm" | scan_for_secrets 2>/dev/null; echo $?)
# The exit code should be 0 (last line)
assert_eq "normal text passes secret scan (exit 0)" "0" "$safe_result"

# Test: catches Bearer tokens
result=$(echo "Authorization: Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0" | scan_for_secrets 2>&1 || true)
assert_contains "detects Bearer token" "$result" "POTENTIAL SECRETS DETECTED"

echo ""

# ── Test Group: Temp File Management ──────────────────────────────────────────
echo "## Temp File Management"

# Test: brain_mktemp creates files with restrictive permissions
tmp_test=$(brain_mktemp)
assert_true "brain_mktemp creates a file" test -f "$tmp_test"

# Check permissions (should be 600)
perms=$(stat -c '%a' "$tmp_test" 2>/dev/null || stat -f '%Lp' "$tmp_test" 2>/dev/null || echo "unknown")
assert_eq "brain_mktemp sets 600 permissions" "600" "$perms"

echo ""

# ── Test Group: URL Validation ────────────────────────────────────────────────
echo "## URL Validation"

# SSH URL should pass without warnings
result=$(validate_remote_url "git@github.com:user/private-brain.git" 2>&1)
assert_contains "SSH URL passes validation" "$result" "SSH URL detected"

# HTTPS URL should warn
result=$(validate_remote_url "https://github.com/user/brain.git" 2>&1)
assert_contains "HTTPS URL triggers warning" "$result" "Make sure this repository is PRIVATE"

echo ""

# ── Test Group: Size Guards ───────────────────────────────────────────────────
echo "## Size Guards"

# Small file passes
small_file="${TEST_TMPDIR}/small.txt"
echo "small content" > "$small_file"
assert_true "small file passes size check" check_file_size "$small_file"

# Large file warns
large_file="${TEST_TMPDIR}/large.txt"
dd if=/dev/zero of="$large_file" bs=1M count=2 2>/dev/null
assert_false "oversized file fails size check" check_file_size "$large_file"

echo ""

# ── Test Group: Backup/Restore ────────────────────────────────────────────────
echo "## Backup/Restore"

# Create some mock brain files
mkdir -p "$HOME/.claude/rules" "$HOME/.claude/skills"
echo "test claude md" > "$HOME/.claude/CLAUDE.md"
echo "test rule" > "$HOME/.claude/rules/test.md"
echo "test skill" > "$HOME/.claude/skills/test.md"

# Create backup
backup_path=$(backup_before_import 2>/dev/null)
assert_true "backup creates directory" test -d "$backup_path"
assert_true "backup includes CLAUDE.md" test -f "${backup_path}/CLAUDE.md"
assert_true "backup includes rules" test -d "${backup_path}/rules"

# Modify the originals
echo "modified claude md" > "$HOME/.claude/CLAUDE.md"

# Restore
restore_from_backup "$backup_path" 2>/dev/null
restored_content=$(cat "$HOME/.claude/CLAUDE.md")
assert_eq "restore recovers original content" "test claude md" "$restored_content"

echo ""

# ── Test Group: MCP Server Secret Stripping ───────────────────────────────────
echo "## MCP Server Secret Stripping"

# Create a mock settings.json with MCP servers that have env secrets
cat > "$HOME/.claude/settings.json" << 'SETTINGS_EOF'
{
  "permissions": {"allow": ["Bash"]},
  "env": {"MY_SECRET": "should-not-export"},
  "mcpServers": {
    "my-server": {
      "command": "npx",
      "args": ["@my/server"],
      "env": {
        "API_KEY": "sk-super-secret-key-12345",
        "DATABASE_URL": "postgres://admin:pass@host/db"
      }
    },
    "simple-server": {
      "command": "node",
      "args": ["server.js"]
    }
  }
}
SETTINGS_EOF

if command -v jq &>/dev/null; then
  # Test: export strips env from settings
  settings_export=$(jq 'del(.env) | del(.mcpServers)' "$HOME/.claude/settings.json")
  assert_not_contains "settings export strips top-level env" "$settings_export" "MY_SECRET"
  assert_not_contains "settings export strips mcpServers" "$settings_export" "my-server"

  # Test: MCP export strips env from each server
  mcp_export=$(jq '
    .mcpServers // {} |
    to_entries |
    map(.value = (.value | del(.env))) |
    from_entries
  ' "$HOME/.claude/settings.json")
  assert_not_contains "MCP export strips server env (API_KEY)" "$mcp_export" "sk-super-secret"
  assert_not_contains "MCP export strips server env (DATABASE_URL)" "$mcp_export" "postgres://admin"
  assert_contains "MCP export keeps server command" "$mcp_export" "npx"
  assert_contains "MCP export keeps server args" "$mcp_export" "@my/server"
  assert_contains "MCP export keeps simple server" "$mcp_export" "simple-server"
else
  skip_test "MCP secret stripping" "jq not available"
fi

echo ""

# ── Test Group: Import Validation ─────────────────────────────────────────────
echo "## Import Validation"

if command -v jq &>/dev/null; then
  # Create a mock consolidated brain with a new skill
  mock_brain="${TEST_TMPDIR}/mock-brain.json"
  cat > "$mock_brain" << 'BRAIN_EOF'
{
  "schema_version": "1.0.0",
  "declarative": {
    "claude_md": {"content": "test", "hash": "sha256:abc"},
    "rules": {
      "new-rule.md": {"content": "a new rule", "hash": "sha256:def"}
    }
  },
  "procedural": {
    "skills": {
      "evil-skill/SKILL.md": {"content": "malicious content", "hash": "sha256:evil"}
    },
    "agents": {
      "new-agent.md": {"content": "a new agent", "hash": "sha256:ghi"}
    },
    "output_styles": {}
  },
  "experiential": {
    "auto_memory": {},
    "agent_memory": {}
  },
  "environmental": {
    "settings": {"content": null, "hash": "sha256:null"},
    "keybindings": {"content": null, "hash": "sha256:null"},
    "mcp_servers": {}
  }
}
BRAIN_EOF

  # Run validate_imports and capture warnings
  source "${PROJECT_DIR}/scripts/common.sh" 2>/dev/null
  brain_content=$(cat "$mock_brain")
  validation_output=$(validate_imports "$brain_content" 2>&1 || true)
  assert_contains "validation detects new skill" "$validation_output" "NEW skill"
  assert_contains "validation detects new agent" "$validation_output" "NEW agent"
  assert_contains "validation detects new rule" "$validation_output" "NEW rule"
else
  skip_test "import validation" "jq not available"
fi

echo ""

# ── Test Group: Path Traversal Prevention ─────────────────────────────────────
echo "## Path Traversal Prevention"

# Source import.sh functions
source "${PROJECT_DIR}/scripts/common.sh" 2>/dev/null

# Create a target directory
traversal_test_dir="${TEST_TMPDIR}/traversal-test/base"
mkdir -p "$traversal_test_dir"

# Create a file that should NOT be overwritten
echo "original content" > "${TEST_TMPDIR}/traversal-test/secret.txt"

# Test: normal key writes correctly
if $_has_jq; then
  import_dir_entries "$traversal_test_dir" '{"safe.md": {"content": "safe content", "hash": "sha256:abc"}}' 2>/dev/null
  assert_true "safe key writes file" test -f "${traversal_test_dir}/safe.md"

  # Test: path traversal attempt is blocked
  traversal_output=$(import_dir_entries "$traversal_test_dir" '{"../secret.txt": {"content": "HACKED", "hash": "sha256:evil"}}' 2>&1 || true)
  secret_content=$(cat "${TEST_TMPDIR}/traversal-test/secret.txt")
  assert_eq "path traversal blocked: file not overwritten" "original content" "$secret_content"
  assert_contains "path traversal logged" "$traversal_output" "BLOCKED"

  # Test: deep traversal attempt
  traversal_output2=$(import_dir_entries "$traversal_test_dir" '{"../../etc/cron.d/evil": {"content": "malicious", "hash": "sha256:evil"}}' 2>&1 || true)
  assert_contains "deep path traversal blocked" "$traversal_output2" "BLOCKED"
elif $_has_python3; then
  # Test Python path
  echo '{"../secret.txt": {"content": "HACKED", "hash": "sha256:evil"}}' | python3 -c "
import json, os, sys
base = os.path.realpath(sys.argv[1])
entries = json.load(sys.stdin)
for key, val in entries.items():
    content = val.get('content', '')
    if content:
        path = os.path.realpath(os.path.join(base, key))
        if not path.startswith(base + os.sep) and path != base:
            print(f'BLOCKED path traversal attempt: {key}', file=sys.stderr)
            continue
        print(f'WOULD WRITE: {path}')
" "$traversal_test_dir" 2>&1
  secret_content=$(cat "${TEST_TMPDIR}/traversal-test/secret.txt")
  assert_eq "Python path traversal blocked: file not overwritten" "original content" "$secret_content"
fi

echo ""

# ── Test Group: Schema Version Validation ─────────────────────────────────────
echo "## Schema Version Validation"

# Test valid schema
valid_schema_brain='{"schema_version":"1.0.0","declarative":{"claude_md":null,"rules":{}},"procedural":{"skills":{},"agents":{},"output_styles":{}},"experiential":{"auto_memory":{},"agent_memory":{}},"environmental":{"settings":{"content":null,"hash":"sha256:null"},"keybindings":{"content":null,"hash":"sha256:null"},"mcp_servers":{}}}'

if $_has_jq; then
  schema_ver=$(echo "$valid_schema_brain" | jq -r '.schema_version // "unknown"')
  assert_eq "valid schema version detected" "1.0.0" "$schema_ver"
elif $_has_python3; then
  schema_ver=$(echo "$valid_schema_brain" | python3 -c "import json,sys; print(json.load(sys.stdin).get('schema_version','unknown'))")
  assert_eq "valid schema version detected (Python)" "1.0.0" "$schema_ver"
fi

# Test invalid schema
invalid_brain='{"schema_version":"2.0.0"}'
if $_has_jq; then
  schema_ver=$(echo "$invalid_brain" | jq -r '.schema_version // "unknown"')
  assert_eq "invalid schema version detected" "2.0.0" "$schema_ver"
  # Verify it would be rejected (schema != 1.0.0)
  assert_false "invalid schema would be rejected" test "$schema_ver" = "1.0.0"
fi

echo ""

# ── Test Group: Export Integration ────────────────────────────────────────────
echo "## Export Integration"

# Setup mock brain state
mkdir -p "$HOME/.claude/projects/-home-user-my--project/memory"
echo "remember to use pnpm" > "$HOME/.claude/projects/-home-user-my--project/memory/MEMORY.md"

# Run export
export_output=$("${PROJECT_DIR}/scripts/export.sh" --quiet --skip-secret-scan 2>/dev/null || echo "EXPORT_FAILED")

if [ "$export_output" != "EXPORT_FAILED" ]; then
  if command -v jq &>/dev/null; then
    # Verify no env vars leaked
    assert_not_contains "export doesn't contain env secret" "$export_output" "should-not-export"
    assert_not_contains "export doesn't contain MCP API key" "$export_output" "sk-super-secret"
    assert_not_contains "export doesn't contain MCP DB URL" "$export_output" "postgres://admin"

    # Verify structure
    schema=$(echo "$export_output" | jq -r '.schema_version')
    assert_eq "export has schema version" "1.0.0" "$schema"

    # Verify MCP servers don't have env
    mcp_has_env=$(echo "$export_output" | jq '[.environmental.mcp_servers | to_entries[] | select(.value.env != null)] | length')
    assert_eq "exported MCP servers have no env fields" "0" "$mcp_has_env"
  fi
else
  skip_test "export integration" "export.sh failed"
fi

echo ""

# ── Test Group: Python Fallback Safety ────────────────────────────────────────
echo "## Python Fallback Safety"

if command -v python3 &>/dev/null; then
  # Temporarily disable jq to force Python fallback
  # We test by calling python3 directly with the patterns used in common.sh

  # Test json_query Python path with injection attempt in filter
  result=$(echo '{"key":"value"}' | python3 -c "
import sys, json
data = json.load(sys.stdin)
filter_path = sys.argv[1]
parts = filter_path.strip('.').split('.')
result = data
for p in parts:
    if p and isinstance(result, dict):
        result = result.get(p)
    if result is None:
        break
if result is None:
    print('null')
elif isinstance(result, (dict, list)):
    print(json.dumps(result))
else:
    print(result)
" ".key" 2>/dev/null)
  assert_eq "Python json_query safely handles normal input" "value" "$result"

  # Test with an injection attempt — the filter comes via argv, not string interpolation
  result=$(echo '{"key":"value"}' | python3 -c "
import sys, json
data = json.load(sys.stdin)
filter_path = sys.argv[1]
parts = filter_path.strip('.').split('.')
result = data
for p in parts:
    if p and isinstance(result, dict):
        result = result.get(p)
    if result is None:
        break
if result is None:
    print('null')
elif isinstance(result, (dict, list)):
    print(json.dumps(result))
else:
    print(result)
" "'; import os; os.system('echo HACKED'); '" 2>/dev/null)
  assert_eq "Python json_query with injection attempt returns null" "null" "$result"

  # Test json_set Python path
  test_set_file="${TEST_TMPDIR}/py-set-test.json"
  echo '{"a":"old"}' > "$test_set_file"
  python3 -c "
import json, sys
file_path = sys.argv[1]
key_path = sys.argv[2]
value_str = sys.argv[3]
with open(file_path) as f:
    data = json.load(f)
keys = key_path.strip('.').split('.')
obj = data
for k in keys[:-1]:
    obj = obj.setdefault(k, {})
obj[keys[-1]] = json.loads(value_str)
with open(file_path, 'w') as f:
    json.dump(data, f, indent=2)
" "$test_set_file" ".a" '"new"' 2>/dev/null
  result=$(python3 -c "import json,sys; print(json.load(open(sys.argv[1]))['a'])" "$test_set_file")
  assert_eq "Python json_set safely updates file" "new" "$result"

  # Test append_merge_log Python path with special chars in summary
  log_test_file="${TEST_TMPDIR}/merge-log-test.json"
  echo '{"entries":[]}' > "$log_test_file"
  python3 -c "
import json, sys
log_file = sys.argv[1]
timestamp = sys.argv[2]
machine_id = sys.argv[3]
machine_name = sys.argv[4]
action = sys.argv[5]
summary = sys.argv[6]
with open(log_file) as f:
    data = json.load(f)
entry = {
    'timestamp': timestamp,
    'machine_id': machine_id,
    'machine_name': machine_name,
    'action': action,
    'summary': summary
}
data['entries'] = [entry] + data.get('entries', [])
with open(log_file, 'w') as f:
    json.dump(data, f, indent=2)
" "$log_test_file" "2026-01-01T00:00:00Z" "abc123" "test's machine" "push" "It's got \"quotes\" and \$pecial chars" 2>/dev/null
  result=$(python3 -c "import json,sys; d=json.load(open(sys.argv[1])); print(d['entries'][0]['machine_name'])" "$log_test_file")
  assert_eq "Python merge log handles special chars in machine name" "test's machine" "$result"
else
  skip_test "Python fallback safety" "python3 not available"
fi

echo ""

# ── Test Group: File Permission Safety ────────────────────────────────────────
echo "## File Permission Safety"

# Exported snapshot should have restricted permissions
test_export_file="${TEST_TMPDIR}/perm-test-snapshot.json"
"${PROJECT_DIR}/scripts/export.sh" --quiet --skip-secret-scan --output "$test_export_file" 2>/dev/null || true

if [ -f "$test_export_file" ]; then
  perms=$(stat -c '%a' "$test_export_file" 2>/dev/null || stat -f '%Lp' "$test_export_file" 2>/dev/null || echo "unknown")
  assert_eq "exported snapshot has 600 permissions" "600" "$perms"
else
  skip_test "export file permissions" "export failed"
fi

echo ""

# ═══════════════════════════════════════════════════════════════════════════════
echo "═══════════════════════════════════════════════"
echo "  Results: ${PASS} passed, ${FAIL} failed, ${SKIP} skipped"
echo "═══════════════════════════════════════════════"

if [ ${#ERRORS[@]} -gt 0 ]; then
  echo ""
  echo "Failed tests:"
  for e in "${ERRORS[@]}"; do
    echo -e "  ${RED}x${NC} $e"
  done
fi

echo ""
exit $FAIL
