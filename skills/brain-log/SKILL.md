---
name: brain-log
description: Show brain sync and evolution history. Pass a number for entry count, "verbose" for full details of the latest run, or "verbose <n>" / "<n> verbose" to see details for entry #n.
---


Show the user their brain's sync history. Optionally surface the per-run detail log written by `merge-semantic.sh` / `evolve.sh` (stderr, exit code, duration, response payload — the diagnostics that used to vanish into the Claude Code session list before `--no-session-persistence` was added).

## Argument parsing

`$ARGUMENTS` may be:

| Form | Meaning |
|---|---|
| *(empty)* | List 20 most recent entries (default) |
| `<n>` | List `<n>` most recent entries |
| `verbose` | List default entries, then dump the detail log of entry #1 (most recent) |
| `verbose <n>` or `<n> verbose` | List default entries, then dump the detail log of entry `<n>` (1-based) |

## Steps

1. Read the merge log and load its entries:
   ```bash
   LOG=~/.claude/brain-repo/meta/merge-log.json
   [ -f "$LOG" ] || { echo "No sync history yet."; exit 0; }
   RUNS_DIR="${BRAIN_RUNS_DIR:-$HOME/.claude/brain-runs}"
   jq -r '.entries[] | "\(.timestamp)\t\(.machine_name)\t\(.action)\t\(.summary)\t\(.run_log // "")"' "$LOG"
   ```
   `run_log` is stored as a bare filename (not an absolute path) so the synced
   log doesn't leak any machine's username/layout. Reconstruct the full path
   locally as `"$RUNS_DIR/<run_log>"`.

2. List entries in reverse chronological order. Default count is 20; if `$ARGUMENTS` contains a bare number, use it.

   For each entry, format as:
   ```
   #<idx> [<timestamp>] <machine_name> (<action>): <summary>
         run_log: <$RUNS_DIR/run_log, if present>
   ```

   Example (the run_log filename is joined with the local runs dir for display):
   ```
   #1 [2026-05-28T13:27:53Z] mbp-80 (pull+merge): Merged 3 machine snapshots
        run_log: /Users/olaf/.claude/brain-runs/20260528T132751Z-merge.log
   #2 [2026-05-28T10:02:13Z] mbp-80 (evolve): Analyzed brain (2 promotions, 0 stale)
        run_log: /Users/olaf/.claude/brain-runs/20260528T100210Z-evolve.log
   ```

3. If `$ARGUMENTS` contains `verbose`:
   - Determine target entry index `N` (default `1`).
   - Extract the `run_log` filename from entry #N via jq: `jq -r ".entries[$((N-1))].run_log // empty"`.
   - If empty/null, tell the user the entry has no detail log (older entries pre-date this feature).
   - Otherwise reconstruct the path as `"$RUNS_DIR/<run_log>"` and `cat` it. Detail logs are machine-local — an entry produced by a different machine names a file that doesn't exist here; report that clearly ("detail log lives on the machine that produced this entry").

## Notes

- Detail logs live under `~/.claude/brain-runs/` and are **not** synced via Git. They are machine-local diagnostics, written each time `merge-semantic.sh` or `evolve.sh` invokes `claude -p --no-session-persistence`.
- Old logs can be pruned manually (`rm ~/.claude/brain-runs/*.log`); the merge-log entry remains but `verbose` will report the file as missing.
