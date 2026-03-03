#!/usr/bin/env bash
# common.sh — Shared utilities for claude-brain
set -euo pipefail

# ── Paths ──────────────────────────────────────────────────────────────────────
CLAUDE_DIR="${HOME}/.claude"
CLAUDE_JSON="${HOME}/.claude.json"
BRAIN_CONFIG="${CLAUDE_DIR}/brain-config.json"
BRAIN_REPO="${CLAUDE_DIR}/brain-repo"
PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
DEFAULTS_FILE="${PLUGIN_ROOT}/config/defaults.json"

# ── Temp File Management ──────────────────────────────────────────────────────
# Track temp files for cleanup on exit/error
_BRAIN_TEMP_FILES=()

brain_mktemp() {
  local tmp
  tmp=$(mktemp "${TMPDIR:-/tmp}/claude-brain-XXXXXX")
  chmod 600 "$tmp"
  _BRAIN_TEMP_FILES+=("$tmp")
  echo "$tmp"
}

_brain_cleanup_temps() {
  for f in "${_BRAIN_TEMP_FILES[@]:-}"; do
    rm -f "$f" 2>/dev/null || true
  done
}

trap _brain_cleanup_temps EXIT

# ── OS Detection ───────────────────────────────────────────────────────────────
detect_os() {
  case "$(uname -s)" in
    Linux*)  echo "linux" ;;
    Darwin*) echo "macos" ;;
    MINGW*|MSYS*|CYGWIN*) echo "windows" ;;
    *)       echo "unknown" ;;
  esac
}

OS="$(detect_os)"

# ── JSON Query ─────────────────────────────────────────────────────────────────
# Uses jq if available, falls back to python3
_has_jq=false
_has_python3=false

if command -v jq &>/dev/null; then
  _has_jq=true
elif command -v python3 &>/dev/null; then
  _has_python3=true
fi

json_query() {
  # Usage: json_query '.field.subfield' < input.json
  #    or: echo '{}' | json_query '.field'
  local filter="$1"
  if $_has_jq; then
    jq -r "$filter"
  elif $_has_python3; then
    # Pass filter via argv to avoid injection
    python3 -c "
import sys, json
data = json.load(sys.stdin)
filter_path = sys.argv[1]
parts = filter_path.strip('.').split('.')
result = data
for p in parts:
    if p and isinstance(result, dict):
        result = result.get(p)
    elif p and isinstance(result, list):
        result = result[int(p)] if p.isdigit() else None
    if result is None:
        break
if result is None:
    print('null')
elif isinstance(result, (dict, list)):
    print(json.dumps(result))
else:
    print(result)
" "$filter"
  else
    echo "ERROR: Neither jq nor python3 found. Install one of them." >&2
    return 1
  fi
}

json_build() {
  # Build JSON from arguments using jq or python3
  # Usage: json_build --arg key value --arg key2 value2 'template'
  if $_has_jq; then
    jq "$@"
  elif $_has_python3; then
    # Fallback: only supports simple --arg key val patterns
    python3 -c "
import sys, json
args = sys.argv[1:]
data = {}
i = 0
while i < len(args) - 1:
    if args[i] == '--arg' and i + 2 < len(args):
        data[args[i+1]] = args[i+2]
        i += 3
    else:
        i += 1
print(json.dumps(data, indent=2))
" "$@"
  else
    echo "ERROR: Neither jq nor python3 found." >&2
    return 1
  fi
}

json_set() {
  # Set a key in a JSON file
  # Usage: json_set file.json '.key' 'value'
  local file="$1" path="$2" value="$3"
  if $_has_jq; then
    local tmp
    tmp=$(brain_mktemp)
    jq --argjson val "$value" "${path} = \$val" "$file" > "$tmp" && mv "$tmp" "$file"
  elif $_has_python3; then
    # Pass file, path, value via argv to avoid injection
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
" "$file" "$path" "$value"
  fi
}

# ── Hashing ────────────────────────────────────────────────────────────────────
compute_hash() {
  # Compute SHA256 hash of stdin
  if command -v sha256sum &>/dev/null; then
    sha256sum | cut -d' ' -f1
  elif command -v shasum &>/dev/null; then
    shasum -a 256 | cut -d' ' -f1
  elif $_has_python3; then
    python3 -c "import sys,hashlib; print(hashlib.sha256(sys.stdin.buffer.read()).hexdigest())"
  else
    echo "ERROR: No hash utility found." >&2
    return 1
  fi
}

file_hash() {
  # Compute SHA256 hash of a file
  local file="$1"
  if [ -f "$file" ]; then
    compute_hash < "$file"
  else
    echo "null"
  fi
}

# ── Machine ID ─────────────────────────────────────────────────────────────────
generate_machine_id() {
  # Generate an 8-char hex ID
  if [ -f /dev/urandom ]; then
    head -c 4 /dev/urandom | od -An -tx1 | tr -d ' \n'
  elif $_has_python3; then
    python3 -c "import secrets; print(secrets.token_hex(4))"
  else
    date +%s | compute_hash | head -c 8
  fi
}

get_machine_id() {
  if [ -f "$BRAIN_CONFIG" ]; then
    json_query '.machine_id' < "$BRAIN_CONFIG"
  else
    echo ""
  fi
}

get_machine_name() {
  # Allow user-configured name, fall back to hostname
  if [ -f "$BRAIN_CONFIG" ]; then
    local custom_name
    custom_name=$(json_query '.machine_name' < "$BRAIN_CONFIG" 2>/dev/null || echo "")
    if [ -n "$custom_name" ] && [ "$custom_name" != "null" ]; then
      echo "$custom_name"
      return
    fi
  fi
  hostname 2>/dev/null || echo "unknown"
}

# ── Brain Config ───────────────────────────────────────────────────────────────
is_initialized() {
  [ -f "$BRAIN_CONFIG" ] && [ -d "$BRAIN_REPO/.git" ]
}

load_config() {
  if [ ! -f "$BRAIN_CONFIG" ]; then
    echo "ERROR: Brain not initialized. Run /brain-init first." >&2
    return 1
  fi
}

get_config() {
  local key="$1"
  json_query ".$key" < "$BRAIN_CONFIG"
}

# ── Git Operations ─────────────────────────────────────────────────────────────
brain_git() {
  git -C "$BRAIN_REPO" "$@"
}

brain_push_with_retry() {
  local max_attempts="${1:-3}"
  local delay="${2:-2}"
  local attempt=1

  while [ "$attempt" -le "$max_attempts" ]; do
    if brain_git push origin main 2>/dev/null; then
      return 0
    fi
    # Pull rebase and retry
    brain_git pull --rebase origin main 2>/dev/null || true
    attempt=$((attempt + 1))
    if [ "$attempt" -le "$max_attempts" ]; then
      sleep "$delay"
    fi
  done

  echo "WARNING: Push failed after $max_attempts attempts." >&2
  return 1
}

# ── URL Validation ─────────────────────────────────────────────────────────────
validate_remote_url() {
  # Warn if the remote URL appears to be a public repo
  local url="$1"

  # Check for common public patterns
  if echo "$url" | grep -qiE '^https?://(github\.com|gitlab\.com|bitbucket\.org)'; then
    log_warn "HTTPS URL detected. Make sure this repository is PRIVATE."
    log_warn "Your brain data (memory, skills, settings) will be stored there."

    # Try to check visibility via GitHub API if it looks like a github URL
    local repo_path
    repo_path=$(echo "$url" | sed -E 's|https?://github\.com/||; s|\.git$||')
    if command -v curl &>/dev/null && echo "$url" | grep -q "github.com"; then
      local visibility
      visibility=$(curl -s -o /dev/null -w "%{http_code}" "https://api.github.com/repos/${repo_path}" 2>/dev/null || echo "000")
      if [ "$visibility" = "200" ]; then
        log_warn "WARNING: This GitHub repository appears to be PUBLIC!"
        log_warn "Your brain contains sensitive configuration. Use a PRIVATE repo."
        log_warn "To make it private: https://github.com/${repo_path}/settings"
        return 1
      fi
    fi
  fi

  if echo "$url" | grep -qE '^git@|^ssh://'; then
    log_info "SSH URL detected (typically private). Good."
  fi

  return 0
}

# ── Logging ────────────────────────────────────────────────────────────────────
brain_log() {
  local level="$1"
  shift
  if [ "${BRAIN_QUIET:-false}" != "true" ]; then
    echo "[claude-brain] $level: $*" >&2
  fi
}

log_info() { brain_log "INFO" "$@"; }
log_warn() { brain_log "WARN" "$@"; }
log_error() { brain_log "ERROR" "$@"; }

append_merge_log() {
  local action="$1" summary="$2"
  local log_file="${BRAIN_REPO}/meta/merge-log.json"
  local timestamp
  timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  local machine_id
  machine_id=$(get_machine_id)
  local machine_name
  machine_name=$(get_machine_name)

  if [ ! -f "$log_file" ]; then
    echo '{"entries":[]}' > "$log_file"
  fi

  if $_has_jq; then
    local tmp
    tmp=$(brain_mktemp)
    jq --arg ts "$timestamp" \
       --arg mid "$machine_id" \
       --arg mn "$machine_name" \
       --arg act "$action" \
       --arg sum "$summary" \
       '.entries = [{"timestamp":$ts,"machine_id":$mid,"machine_name":$mn,"action":$act,"summary":$sum}] + .entries | .entries = .entries[:200]' \
       "$log_file" > "$tmp" && mv "$tmp" "$log_file"
  elif $_has_python3; then
    # Pass all data via argv to avoid injection
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
data['entries'] = data['entries'][:200]
with open(log_file, 'w') as f:
    json.dump(data, f, indent=2)
" "$log_file" "$timestamp" "$machine_id" "$machine_name" "$action" "$summary"
  fi
}

# ── Timestamp ──────────────────────────────────────────────────────────────────
now_iso() {
  date -u +"%Y-%m-%dT%H:%M:%SZ"
}

# ── Dependency Check ───────────────────────────────────────────────────────────
check_dependencies() {
  local missing=()

  if ! command -v git &>/dev/null; then
    missing+=("git")
  fi

  if ! $_has_jq && ! $_has_python3; then
    missing+=("jq or python3")
  fi

  if [ ${#missing[@]} -gt 0 ]; then
    echo "ERROR: Missing dependencies: ${missing[*]}" >&2
    echo "Install them before using claude-brain." >&2
    return 1
  fi
}

# ── Secret Scanning ──────────────────────────────────────────────────────────
# Scans text for common secret patterns and warns the user
SECRET_PATTERNS=(
  'sk-[a-zA-Z0-9]{20,}'                           # OpenAI/Anthropic API keys
  'key-[a-zA-Z0-9]{20,}'                          # Generic API keys
  'AKIA[0-9A-Z]{16}'                              # AWS access key IDs
  'ghp_[a-zA-Z0-9]{20,}'                          # GitHub personal access tokens
  'gho_[a-zA-Z0-9]{20,}'                          # GitHub OAuth tokens
  'github_pat_[a-zA-Z0-9_]{22,}'                  # GitHub fine-grained tokens
  'glpat-[a-zA-Z0-9]{20,}'                        # GitLab personal access tokens
  'xoxb-[0-9]{10,}-[a-zA-Z0-9]{20,}'              # Slack bot tokens
  'xoxp-[0-9]{10,}-[a-zA-Z0-9]{20,}'              # Slack user tokens
  'Bearer [a-zA-Z0-9._+/=-]{20,}'                 # Bearer tokens
  'postgres(ql)?://[^:]+:[^@]+@'                   # PostgreSQL connection strings
  'mysql://[^:]+:[^@]+@'                           # MySQL connection strings
  'mongodb(\+srv)?://[^:]+:[^@]+@'                 # MongoDB connection strings
  'redis://:[^@]+@'                                # Redis connection strings
  'password[" ]*[:=][" ]*[^ ]{8,}'                # Password assignments
  'secret[" ]*[:=][" ]*[^ ]{8,}'                  # Secret assignments
  'token[" ]*[:=][" ]*[a-zA-Z0-9._]{20,}'         # Token assignments
  'PRIVATE KEY-----'                               # Private keys
)

scan_for_secrets() {
  # Scans content from stdin for common secret patterns
  # Returns 0 if no secrets found, 1 if secrets detected
  # Outputs warnings to stderr
  local content
  content=$(cat)
  local found=0

  for pattern in "${SECRET_PATTERNS[@]}"; do
    local matches
    matches=$(echo "$content" | grep -oEi "$pattern" 2>/dev/null | head -5 || true)
    if [ -n "$matches" ]; then
      if [ "$found" -eq 0 ]; then
        log_warn "POTENTIAL SECRETS DETECTED in brain data:"
        found=1
      fi
      # Show redacted match
      while IFS= read -r match; do
        local redacted
        redacted=$(echo "$match" | head -c 12)
        log_warn "  Pattern match: ${redacted}... (redacted)"
      done <<< "$matches"
    fi
  done

  if [ "$found" -eq 1 ]; then
    log_warn "Review your memory files and remove secrets before syncing."
    log_warn "Use --skip-secret-scan to suppress this warning."
    return 1
  fi
  return 0
}

# ── Size Guards ──────────────────────────────────────────────────────────────
MAX_SNAPSHOT_SIZE_BYTES=$((10 * 1024 * 1024))  # 10 MB
MAX_SINGLE_FILE_BYTES=$((1 * 1024 * 1024))     # 1 MB

check_file_size() {
  local file="$1" max="${2:-$MAX_SINGLE_FILE_BYTES}"
  if [ -f "$file" ]; then
    local size
    size=$(wc -c < "$file" | tr -d ' ')
    if [ "$size" -gt "$max" ]; then
      log_warn "File $file is very large (${size} bytes). This may cause issues."
      return 1
    fi
  fi
  return 0
}

# ── Backup / Restore ─────────────────────────────────────────────────────────
BACKUP_DIR="${CLAUDE_DIR}/brain-backups"

backup_before_import() {
  # Create a timestamped backup of current brain state before importing
  local timestamp
  timestamp=$(date +%Y%m%d-%H%M%S)
  local backup_path="${BACKUP_DIR}/${timestamp}"
  mkdir -p "$backup_path"

  # Back up key files
  [ -f "${CLAUDE_DIR}/CLAUDE.md" ] && cp "${CLAUDE_DIR}/CLAUDE.md" "${backup_path}/" 2>/dev/null || true
  [ -d "${CLAUDE_DIR}/rules" ] && cp -r "${CLAUDE_DIR}/rules" "${backup_path}/" 2>/dev/null || true
  [ -d "${CLAUDE_DIR}/skills" ] && cp -r "${CLAUDE_DIR}/skills" "${backup_path}/" 2>/dev/null || true
  [ -d "${CLAUDE_DIR}/agents" ] && cp -r "${CLAUDE_DIR}/agents" "${backup_path}/" 2>/dev/null || true
  [ -f "${CLAUDE_DIR}/settings.json" ] && cp "${CLAUDE_DIR}/settings.json" "${backup_path}/" 2>/dev/null || true
  [ -f "${CLAUDE_DIR}/keybindings.json" ] && cp "${CLAUDE_DIR}/keybindings.json" "${backup_path}/" 2>/dev/null || true

  # Prune old backups (keep last 5)
  if [ -d "$BACKUP_DIR" ]; then
    ls -1d "${BACKUP_DIR}"/[0-9]* 2>/dev/null | sort | head -n -5 | while read -r old; do
      rm -rf "$old"
    done
  fi

  log_info "Backup created: ${backup_path}"
  echo "$backup_path"
}

restore_from_backup() {
  local backup_path="$1"
  if [ ! -d "$backup_path" ]; then
    log_error "Backup not found: $backup_path"
    return 1
  fi

  log_info "Restoring from backup: $backup_path"
  [ -f "${backup_path}/CLAUDE.md" ] && cp "${backup_path}/CLAUDE.md" "${CLAUDE_DIR}/" 2>/dev/null || true
  [ -d "${backup_path}/rules" ] && cp -r "${backup_path}/rules" "${CLAUDE_DIR}/" 2>/dev/null || true
  [ -d "${backup_path}/skills" ] && cp -r "${backup_path}/skills" "${CLAUDE_DIR}/" 2>/dev/null || true
  [ -d "${backup_path}/agents" ] && cp -r "${backup_path}/agents" "${CLAUDE_DIR}/" 2>/dev/null || true
  [ -f "${backup_path}/settings.json" ] && cp "${backup_path}/settings.json" "${CLAUDE_DIR}/" 2>/dev/null || true
  [ -f "${backup_path}/keybindings.json" ] && cp "${backup_path}/keybindings.json" "${CLAUDE_DIR}/" 2>/dev/null || true
  log_info "Restore complete."
}

list_backups() {
  if [ -d "$BACKUP_DIR" ]; then
    ls -1d "${BACKUP_DIR}"/[0-9]* 2>/dev/null | sort -r
  else
    echo "No backups found."
  fi
}

# ── Path Encoding/Decoding ─────────────────────────────────────────────────────
# Claude Code encodes project paths: /home/user/my-project → -home-user-my--project
# Hyphens in names are doubled: my-project → my--project
# Leading slash becomes leading hyphen
decode_project_path() {
  local encoded="$1"
  # First restore leading slash, then un-double hyphens temporarily,
  # then convert remaining single hyphens to slashes, then restore hyphens
  echo "$encoded" | sed 's/^-/\//' | sed 's/--/\x00/g' | sed 's/-/\//g' | sed 's/\x00/-/g'
}

encode_project_path() {
  local path="$1"
  # Double any hyphens in the path first, then convert slashes to hyphens
  echo "$path" | sed 's/-/--/g' | sed 's/\//-/g'
}

# Extract a human-friendly project name from encoded path
project_name_from_encoded() {
  local encoded="$1"
  # Take the last segment of the decoded path
  local decoded
  decoded=$(decode_project_path "$encoded")
  basename "$decoded"
}
