#!/usr/bin/env bash
# common.sh — Shared utilities for claude-brain
set -euo pipefail

# ── Paths ──────────────────────────────────────────────────────────────────────
CLAUDE_DIR="${CLAUDE_DIR:-${HOME}/.claude}"
CLAUDE_JSON="${CLAUDE_JSON:-${HOME}/.claude.json}"
BRAIN_CONFIG="${BRAIN_CONFIG:-${CLAUDE_DIR}/brain-config.json}"
BRAIN_REPO="${BRAIN_REPO:-${CLAUDE_DIR}/brain-repo}"
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
    Linux*)  
      # Check for WSL
      if [ -f /proc/version ] && grep -qi microsoft /proc/version; then
        echo "wsl"
      else
        echo "linux"
      fi
      ;;
    Darwin*) echo "macos" ;;
    MINGW*|MSYS*|CYGWIN*) echo "windows" ;;
    *)       echo "unknown" ;;
  esac
}

OS="$(detect_os)"

# WSL-specific path handling
is_wsl() {
  [ "$OS" = "wsl" ]
}

# Convert Windows paths to WSL paths if needed
normalize_path() {
  local path="$1"
  if is_wsl && echo "$path" | grep -q '^[A-Za-z]:'; then
    # Convert C:\Users\... to /mnt/c/Users/...
    echo "$path" | sed 's|^\([A-Za-z]\):|/mnt/\L\1|' | sed 's|\\|/|g'
  else
    echo "$path"
  fi
}

# Get the appropriate home directory
get_user_home() {
  if is_wsl && [ -n "${USERPROFILE:-}" ]; then
    # In WSL, prefer Windows user profile for consistency
    normalize_path "$USERPROFILE"
  else
    echo "$HOME"
  fi
}

# ── JSON Query (requires jq) ───────────────────────────────────────────────────
if ! command -v jq &>/dev/null; then
  echo "ERROR: jq is required. Install: apt install jq / brew install jq" >&2
  exit 1
fi

json_query() {
  # Usage: json_query '.field.subfield' < input.json
  local filter="$1"
  jq -r "$filter"
}

json_build() {
  # Build JSON from arguments using jq
  # Usage: json_build --arg key value --arg key2 value2 'template'
  jq "$@"
}

json_set() {
  # Set a key in a JSON file
  # Usage: json_set file.json '.key' 'value'
  local file="$1" path="$2" value="$3"
  local tmp
  tmp=$(brain_mktemp)
  jq --argjson val "$value" "${path} = \$val" "$file" > "$tmp" && mv "$tmp" "$file"
}

# ── Hashing ────────────────────────────────────────────────────────────────────
compute_hash() {
  # Compute SHA256 hash of stdin
  if command -v sha256sum &>/dev/null; then
    sha256sum | cut -d' ' -f1
  elif command -v shasum &>/dev/null; then
    shasum -a 256 | cut -d' ' -f1
  elif command -v python3 &>/dev/null; then
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
  elif command -v python3 &>/dev/null; then
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

  local tmp
  tmp=$(brain_mktemp)
  jq --arg ts "$timestamp" \
     --arg mid "$machine_id" \
     --arg mn "$machine_name" \
     --arg act "$action" \
     --arg sum "$summary" \
     '.entries = [{"timestamp":$ts,"machine_id":$mid,"machine_name":$mn,"action":$act,"summary":$sum}] + .entries | .entries = .entries[:200]' \
     "$log_file" > "$tmp" && mv "$tmp" "$log_file"
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

  if ! command -v jq &>/dev/null; then
    missing+=("jq")
  fi

  # Check age if encryption is enabled
  if is_initialized && encryption_enabled && ! command -v age &>/dev/null; then
    missing+=("age (for encryption)")
  fi

  if [ ${#missing[@]} -gt 0 ]; then
    echo "ERROR: Missing dependencies: ${missing[*]}" >&2
    echo "Install them before using claude-brain." >&2
    echo "age can be installed from: https://github.com/FiloSottile/age" >&2
    return 1
  fi
}

# ── Age Encryption ────────────────────────────────────────────────────────────
encryption_enabled() {
  if [ -f "$BRAIN_CONFIG" ]; then
    local enabled
    enabled=$(jq -r '.encryption.enabled // false' "$BRAIN_CONFIG")
    [ "$enabled" = "true" ]
  else
    false
  fi
}

get_age_identity() {
  if [ -f "$BRAIN_CONFIG" ]; then
    jq -r '.encryption.identity // "~/.claude/brain-age-key.txt"' "$BRAIN_CONFIG" | sed "s|~|$HOME|"
  else
    echo "${HOME}/.claude/brain-age-key.txt"
  fi
}

get_age_recipients() {
  if [ -f "$BRAIN_CONFIG" ]; then
    jq -r '.encryption.recipients // "~/.claude/brain-repo/meta/recipients.txt"' "$BRAIN_CONFIG" | sed "s|~|$HOME|"
  else
    echo "${BRAIN_REPO}/meta/recipients.txt"
  fi
}

generate_age_keypair() {
  local identity_file="$1"
  local recipients_file="$2"
  
  if ! command -v age-keygen &>/dev/null; then
    log_error "age-keygen not found. Install age from https://github.com/FiloSottile/age"
    return 1
  fi
  
  mkdir -p "$(dirname "$identity_file")" "$(dirname "$recipients_file")"
  
  # Generate keypair
  age-keygen -o "$identity_file" 2>/dev/null || {
    log_error "Failed to generate age keypair"
    return 1
  }
  
  # Extract public key to recipients file
  grep "# public key:" "$identity_file" | cut -d' ' -f4 > "$recipients_file"
  chmod 600 "$identity_file"
  chmod 644 "$recipients_file"
  
  log_info "Generated age keypair:"
  log_info "  Identity (private): $identity_file"
  log_info "  Recipients (public): $recipients_file"
}

encrypt_content() {
  local content="$1"
  local recipients_file
  recipients_file=$(get_age_recipients)
  
  if [ ! -f "$recipients_file" ]; then
    log_error "Age recipients file not found: $recipients_file"
    return 1
  fi
  
  echo "$content" | age -R "$recipients_file" 2>/dev/null || {
    log_error "Failed to encrypt content"
    return 1
  }
}

decrypt_content() {
  local encrypted_content="$1"
  local identity_file
  identity_file=$(get_age_identity)
  
  if [ ! -f "$identity_file" ]; then
    log_error "Age identity file not found: $identity_file"
    return 1
  fi
  
  echo "$encrypted_content" | age -d -i "$identity_file" 2>/dev/null || {
    log_error "Failed to decrypt content"
    return 1
  }
}

is_encrypted_content() {
  local content="$1"
  # Check for age armor header
  echo "$content" | head -1 | grep -q "^-----BEGIN AGE ENCRYPTED FILE-----"
}

encrypt_file() {
  local input_file="$1"
  local output_file="$2"
  local recipients_file
  recipients_file=$(get_age_recipients)
  
  if [ ! -f "$recipients_file" ]; then
    log_error "Age recipients file not found: $recipients_file"
    return 1
  fi
  
  age -R "$recipients_file" -o "$output_file" "$input_file" 2>/dev/null || {
    log_error "Failed to encrypt file: $input_file"
    return 1
  }
}

decrypt_file() {
  local input_file="$1"
  local output_file="$2"
  local identity_file
  identity_file=$(get_age_identity)
  
  if [ ! -f "$identity_file" ]; then
    log_error "Age identity file not found: $identity_file"
    return 1
  fi
  
  age -d -i "$identity_file" -o "$output_file" "$input_file" 2>/dev/null || {
    log_error "Failed to decrypt file: $input_file"
    return 1
  }
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
