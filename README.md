# claude-brain

Sync and evolve your Claude Code brain across machines.

## Security Notice

**Read this before using claude-brain.** This plugin syncs your Claude Code configuration and accumulated knowledge via a Git remote. Understand what data leaves your machine:

### What IS exported to the Git remote

- **CLAUDE.md, rules, skills, agents** — your instructions and workflows
- **Auto memory and agent memory** — patterns Claude learned from your sessions
- **Settings** — hooks, permissions, preferences (NOT env vars)
- **MCP server configurations** — command and args only (env vars containing API keys are **stripped**)
- **Keybindings** — your keyboard shortcuts
- **Machine hostname and project directory names** — used for merge tracking

### What is NEVER exported

- OAuth tokens and API keys
- `~/.claude.json` (internal state, credentials)
- Environment variables from settings
- MCP server `env` fields (may contain API keys/tokens)
- `.local` config files (settings.local.json, CLAUDE.local.md)
- Session transcripts

### Important security considerations

1. **Use a PRIVATE Git repository.** Your brain data is stored in plaintext. The plugin warns if it detects a public repo, but you are responsible for repo visibility.
2. **Memory may contain sensitive context.** Claude stores information from your sessions in memory files. Review `~/.claude/projects/*/memory/` before initializing. The export runs a pattern-based secret scan and warns if potential API keys or tokens are found, but this is not exhaustive.
3. **Git history is permanent.** Even if you later remove sensitive data from memory, it persists in Git history. Consider `git-filter-repo` or BFG Repo Cleaner if you need to purge history.
4. **Auto-sync runs silently.** On every Claude Code session start/end, your brain is automatically pushed/pulled. The plugin creates backups before each import.
5. **Semantic merge sends memory to Claude API.** When merging brains from multiple machines, memory content is sent to `claude -p` for intelligent deduplication. This is the same API your Claude Code sessions use.
6. **Trust all machines in your network.** Imported skills, agents, and rules execute with Claude's permissions. A compromised machine could inject malicious instructions. Only add machines you fully control.
7. **Backups are created automatically.** Before each import, a backup is saved to `~/.claude/brain-backups/`. Use `/brain-status` to check, and restore manually if needed.

## What It Does

Claude Code accumulates knowledge over time: auto-memory, custom agents, skills, rules, settings, and CLAUDE.md instructions. This plugin makes that knowledge portable across all your machines.

- **Export** your brain state to a portable format
- **Sync** brains across machines via Git (no central server)
- **Merge** intelligently: deterministic for structured data, LLM-powered for unstructured knowledge
- **Evolve** by promoting stable patterns from memory to durable configuration
- **Auto-sync** on every Claude Code session start/end via hooks

## Quick Start

### First machine (initialize)

```
/brain-init git@github.com:you/my-brain.git
```

### Other machines (join)

```
/brain-join git@github.com:you/my-brain.git
```

### That's it

Hooks auto-sync on every session start/end. Your brain follows you.

## Commands

| Command | Description |
|---------|-------------|
| `/brain-init <remote>` | Initialize brain network with a Git remote |
| `/brain-join <remote>` | Join an existing brain network |
| `/brain-status` | Show brain inventory and sync status |
| `/brain-sync` | Manually trigger full sync cycle |
| `/brain-evolve` | Promote stable patterns from memory |
| `/brain-conflicts` | Review and resolve merge conflicts |
| `/brain-log` | Show sync history |

## How It Works

### Sync Model

Each machine pushes brain snapshots to a shared Git repo. When a machine pulls, it merges all snapshots:

- **Structured data** (settings, keybindings, MCP servers): Deterministic JSON deep-merge
- **Unstructured data** (memory, CLAUDE.md): LLM-powered semantic merge via `claude -p`

### What Gets Synced

| Component | Synced? | Strategy |
|-----------|---------|----------|
| CLAUDE.md | Yes | Semantic merge |
| Rules | Yes | Union by filename |
| Skills | Yes | Union by name |
| Agents | Yes | Union by name |
| Auto memory | Yes | Semantic merge |
| Agent memory | Yes | Semantic merge |
| Settings (hooks, permissions) | Yes | Deep merge (env vars excluded) |
| Keybindings | Yes | Union |
| MCP servers | Yes | Union, paths rewritten, env vars stripped |
| OAuth tokens | Never | Security |
| Env vars | Never | Machine-specific |
| MCP server env fields | Never | May contain API keys |

## Dependencies

- `git` (for sync transport)
- `jq` or `python3` (for JSON processing)
- `claude` CLI (for semantic merge — already installed if you have Claude Code)

## Architecture

```
Machine A              Machine B              Machine C
┌──────────┐          ┌──────────┐          ┌──────────┐
│ claude-   │          │ claude-   │          │ claude-   │
│ brain     │          │ brain     │          │ brain     │
│ plugin    │          │ plugin    │          │ plugin    │
└─────┬─────┘          └─────┬─────┘          └─────┬─────┘
      │                      │                      │
      └──────────┬───────────┴──────────┬───────────┘
                 │     Git Remote       │
                 │  (user's private     │
                 │       repo)          │
                 └──────────────────────┘
```

No central server. Each machine merges on pull. Git handles transport.

## Installation

### From marketplace (when available)

```
/plugin marketplace add toroleapinc/claude-brain
/plugin install claude-brain
```

### Local development

```
claude --plugin-dir ./claude-brain
```

## Export flags

| Flag | Description |
|------|-------------|
| `--skip-secret-scan` | Suppress the automatic secret pattern scan on export |
| `--quiet` | Suppress informational output |

## License

MIT
