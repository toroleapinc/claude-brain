---
name: brain-init
description: Initialize brain sync network. Creates a Git remote for your brain and exports your current Claude Code state.
user-invocable: true
disable-model-invocation: true
argument-hint: "<git-remote-url>"
allowed-tools: Bash, Read, Write, AskUserQuestion
---

The user wants to initialize their Claude Brain sync network.

The Git remote URL is provided as: $ARGUMENTS

## Steps

1. First, check dependencies by running:
   ```
   "${CLAUDE_PLUGIN_ROOT}/scripts/common.sh" && echo "OK"
   ```
   If jq and git are missing, tell the user what to install.

2. Validate the remote URL for security:
   ```bash
   source "${CLAUDE_PLUGIN_ROOT}/scripts/common.sh"
   validate_remote_url "$ARGUMENTS"
   ```
   If the URL is detected as pointing to a PUBLIC repository, STOP and warn the user:
   - "WARNING: This repository appears to be PUBLIC. Your brain data (memory, skills, settings, and potentially sensitive information) will be visible to anyone."
   - "Please use a PRIVATE repository."
   - Ask the user if they want to continue anyway.

3. Show the user their current brain inventory by running:
   ```
   bash "${CLAUDE_PLUGIN_ROOT}/scripts/status.sh"
   ```

4. **IMPORTANT: Show the user a security notice before proceeding:**
   Tell the user:
   - "Brain sync will export the following to the Git remote:"
   - "  - CLAUDE.md, rules, skills, agents (your instructions and workflows)"
   - "  - Auto memory and agent memory (learned patterns from your sessions)"
   - "  - Settings (hooks, permissions — NOT env vars)"
   - "  - MCP server configurations (command/args only — env vars with API keys are STRIPPED)"
   - "  - Keybindings"
   - ""
   - "What is NEVER exported: OAuth tokens, API keys in env vars, ~/.claude.json, session transcripts"
   - ""
   - "Note: Memory files may contain information from your conversations. Review ~/.claude/projects/*/memory/ if concerned."

5. Ask the user to confirm they want to initialize brain sync with the provided remote.

6. Run the initialization sequence:
   ```bash
   # Create brain repo directory
   mkdir -p ~/.claude/brain-repo

   # Initialize git repo
   cd ~/.claude/brain-repo
   git init
   git remote add origin "$ARGUMENTS" 2>/dev/null || git remote set-url origin "$ARGUMENTS"

   # Create directory structure
   mkdir -p machines consolidated meta

   # Initialize meta files
   echo '{"entries":[]}' > meta/merge-log.json

   # Register this machine
   bash "${CLAUDE_PLUGIN_ROOT}/scripts/register-machine.sh" "$ARGUMENTS"

   # Export initial brain snapshot
   MACHINE_ID=$(cat ~/.claude/brain-config.json | jq -r '.machine_id')
   mkdir -p "machines/${MACHINE_ID}"
   bash "${CLAUDE_PLUGIN_ROOT}/scripts/export.sh" --output "machines/${MACHINE_ID}/brain-snapshot.json"

   # Copy as initial consolidated brain
   cp "machines/${MACHINE_ID}/brain-snapshot.json" consolidated/brain.json

   # Commit and push (specific paths, not -A)
   git add machines/ consolidated/ meta/
   git commit -m "Initialize brain: $(hostname)"
   git branch -M main
   git push -u origin main
   ```

7. Confirm success and show the user:
   - Their machine ID and name
   - The remote URL
   - Instructions: "Install claude-brain on your other machines and run: /brain-join $ARGUMENTS"
   - Reminder: "Auto-sync is enabled. Brain syncs silently on every session start/end."

If any step fails, show the error and suggest fixes (e.g., create the remote repo first on GitHub).
