# Changelog

All notable changes to claude-brain will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Fixed
- **`SessionStart`-hook fork bomb during sync.** The headless `claude -p` call inside `merge-semantic.sh`/`evolve.sh` re-ran the brain-sync `SessionStart` hook in the child process, which started another `pull.sh → merge-semantic.sh → claude -p` chain — spawning a new process every few seconds (30+ runaway processes within minutes). Fixed with a `BRAIN_SYNC_ACTIVE` env-var sentinel: `pull.sh`/`push.sh` export it and exit early if already set, `evolve.sh`/`merge-semantic.sh` export it defensively at their `claude -p` spawn site, and the `SessionStart`/`SessionEnd`/`PreCompact` hooks skip when it is set. The flag is inherited by the `claude -p` child, so its hook no-ops instead of recursing.
- **OAuth auth broke during semantic merge.** An earlier fix used `--bare` on the `claude -p` call to stop the fork bomb, but `--bare` also disables keychain reads — so users authenticated via Claude.ai OAuth (rather than `ANTHROPIC_API_KEY`) saw every semantic merge fail with "Not logged in" and fall back to concatenation. `--bare` is replaced by the env-var guard above, restoring OAuth keychain access.
- **Idempotent concatenation fallback.** When the semantic merge fell back to concatenation, it appended an "Unmerged content" marker block on every run without stripping pre-existing ones — so `CLAUDE.md` grew by one duplicate copy per sync (observed accumulating identical copies across repeated syncs in the wild). The fallback now strips prior marker sections from both base and incoming snapshots before re-appending, so repeated runs converge.

### Changed
- Headless `claude -p` merge/evolve calls now pass `--no-session-persistence` so these one-shot calls leave no entry in the Claude Code session picker.

## [0.2.0] - 2026-05-07

### Fixed
- **`SessionEnd` push silently did nothing** when `shared/` directory didn't exist. `git add` aborted on the missing path, nothing got staged, `git commit` reported "nothing to commit" and exited cleanly. Auto-sync looked healthy but no commits ever landed. Now uses split adds with existence checks.
- **Encryption flag silently flipped to `false` on every push.** `register-machine.sh` rewrote `~/.claude/brain-config.json` from scratch on each call, hardcoding `encryption.enabled: false` unless `--encrypt` was passed. `push.sh` calls it without `--encrypt`. Users who initialized with `/brain-init --encrypt` had their flag flipped on the next `SessionEnd`. `register_machine` now preserves `auto_sync`, `registered_at`, and `encryption` from existing config.
- Plugin failed to load skills and sync after fresh install (#31).
- Sync timestamps lost on re-registration; macOS `sed` errors (#30).
- macOS compatibility: `sed -i` flag handling, `ARG_MAX` overflow, `.env` variable leak (#40).
- MCP servers now read/written from `~/.claude.json` instead of `settings.json` (#27).
- Import: process substitution replaced with temp files for POSIX portability (#26).
- Semantic merge: stdin pipe instead of command substitution to avoid `ARG_MAX` (#25).
- Cross-platform test failures on Alpine, Ubuntu, and WSL.
- Bash `local` keyword outside functions; `CLAUDE_DIR` env var now respected.
- Critical syntax errors and macOS compatibility issues from senior code review (#29).
- Skills, agents, and hooks now declared in `plugin.json`; install name corrected in README (#28).

### Changed
- `merge-semantic`: `--max-turns` bumped 1 → 10 to give schema-constrained calls room to retry.
- `max_budget_usd` default raised 0.50 → 3.00 to accommodate larger merges.
- Age encryption invocations now use `-a` (ASCII armor) for portability across systems.

## [0.1.0] - 2026-03-03

### Added
- Initial release
- Brain sync via Git (`/brain-init`, `/brain-join`, `/brain-sync`)
- Semantic merge for CLAUDE.md and memory using `claude -p`
- Structured merge for settings, keybindings, MCP configs
- N-way merge support (laptop + desktop + cloud VM)
- Auto-sync hooks on session start/end
- Brain status and inventory (`/brain-status`)
- Sync history log (`/brain-log`)
- Brain evolution — promote stable patterns from memory to config (`/brain-evolve`)
- Conflict detection and resolution (`/brain-conflicts`)
- Team sharing of skills, agents, and rules (`/brain-share`)
- Secret scanning with pattern-based detection
- Optional age encryption for snapshots at rest
- Automatic backups before import
- `--dry-run` flag for push/pull (community contribution by @a638011)
- Sync statistics in status output
- WSL support with path handling
- Chinese README translation
