---
name: macos-disk-cleanup
description: Use when disk is full or finding macOS cleanup targets.
---

# macOS Disk Cleanup

Find and reclaim disk space on a macOS machine. The default deliverable is a
**tiered report** (what to delete, how much it frees, how safe it is) — NOT
immediate deletion. The user typically wants to decide before anything is removed.

## Workflow

1. **Locate the mount**, don't trust the root `df`. On APFS, `df /` shows the
   sealed system snapshot, not `~`. Find the real volume with `df -h ~`.
2. **Never run a bare `du -sh ~`** — it times out on large home dirs (60s+).
   Break into targeted top-level dirs and run them in PARALLEL batches:
   - `du -sh ~/Library/Caches/*`, `~/Library/Application\ Support/*`,
     `~/Library/Developer/*`, `~/workspace/*`, `~/.*`
3. Drill into the biggest buckets with `du -sh <dir>/* | sort -rh | head`.
4. **Age-check anything ambiguous** (`ls -lt`) to separate stale from active.
   Example: a git worktree is NOT stale if `git log -1` shows commits from today.
5. Present a tiered report. Only delete after explicit user confirmation.

## Safety tiers (typical macOS targets, biggest first)

| Target | Typical size | Safe? | Notes |
|---|---|---|---|
| Docker `Docker.raw` | tens of GB | prune=yes, shrink=no | See pitfall below |
| Xcode `DerivedData` | several GB | ✅ | Rebuilds on demand |
| Claude desktop `vm_bundles/*.bundle` | GBs | ✅ if stale | Rebuilt by Claude; close app first |
| Package caches (yarn/poetry/pip/playwright) | GBs | ✅ | Re-download on demand; user may note they "come right back" |
| `CoreSimulator` devices+caches | GBs | ⚠️ | Only ONE runtime means no old-runtime win |
| Stale duplicate repo checkouts (`*-2`) | ~1GB | ⚠️ | Check for untracked unique work first |
| Browser profiles (`Chrome/Default`) | GBs | ⚠️ | Hard to clean without breaking sessions |
| `.Trash`, `~/Downloads` | variable | ⚠️ | Ask before emptying Trash |

## Pitfalls

- **`Docker.raw` never shrinks on its own.** It is a sparse file that grows to
  the max disk-image size and stays allocated even after `docker system prune -a`.
  Reclaim requires two steps: (1) `docker system prune -a --volumes` to free space
  *inside* the VM, then (2) shrink the disk — Docker Desktop → Settings →
  Resources → "Disk image size" (refuses if below actual usage), OR Settings →
  Troubleshoot → "Reset to factory defaults" (wipes everything). A 152G apparent /
  90G on-disk `.raw` is normal and expected, not corruption.
- **Docker Desktop GUI running ≠ daemon up.** The CLI can hit "Cannot connect to
  the Docker daemon" while the Desktop app is open. Check the socket, wait, and
  retry; if still down you can't inventory images — say so instead of guessing.
- **Worktrees look stale but often aren't.** Verify with `git worktree list` +
  `git log -1 --format=%ci` before flagging any for deletion; an active dev may
  have 10+ worktrees all touched the same day.

## User preference (this workspace)

Map first, report, then wait. Deleting caches is low-risk but the user is
explicitly wary of them "coming right back" — present caches as a separate,
lower-priority tier and let them opt in. Do NOT run destructive commands
unilaterally on a no-response clarify; a conservative report is the correct
end state.
