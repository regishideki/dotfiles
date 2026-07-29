---
name: dotfiles-rcm
description: "Symlink tool config dirs into rcm dotfiles repo."
version: 1.0.0
---

# Dotfiles & rcm Config Symlinking

Manage config directory symlinks for tools (Claude, Hermes, Codex, etc.) inside an rcm-based dotfiles repo. The pattern: move the real config dir into the repo, create a symlink back, and use a `.gitignore` to track only portable config files — not runtime data, secrets, or binaries.

## When to Use

- User wants to version a tool's config (`.claude`, `.hermes`, `.codex`, etc.) in their dotfiles repo.
- Adding a new config dir to an rcm-managed repo.
- Troubleshooting broken rcm symlinks or `rcup` behavior.

## The Pattern (4 Steps)

### 1. Move the real dir into the repo, symlink back

```bash
mv ~/.<tool> ~/dotfiles/<tool> && ln -s ~/dotfiles/<tool> ~/.<tool>
```

This is safe even while the tool's process is running: `mv` on the same filesystem is an atomic rename (instant regardless of size), and `ln -s` is instant. The process holds open file descriptors and won't crash. If something breaks, undo: `rm ~/.<tool> && mv ~/dotfiles/<tool> ~/.<tool>`.

### 2. Create a `.gitignore` inside the repo dir

Use the whitelist pattern — ignore everything, then unignore only portable config:

```gitignore
# Ignore everything by default
*

# Keep user configuration files
!.gitignore
!config.yaml
!settings.json
!SOUL.md
!CLAUDE.md

# Keep custom commands/skills (uncomment when they exist)
# !commands/
# !skills/**
```

The `*` + `!file` pattern is essential for dirs with gigabytes of runtime data (Hermes is 2.7GB). Without it, `git status` crawls and backups bloat.

### 3. Update `rcrc`

rcm needs two entries for each symlinked dir:

```
EXCLUDES="... <tool>"          # prevents rcup from creating individual file symlinks inside it
SYMLINK_DIRS="... <tool>"      # tells rcup to manage the dir as a single symlink
```

Both are required. `EXCLUDES` without `SYMLINK_DIRS` means rcup ignores the dir entirely. `SYMLINK_DIRS` without `EXCLUDES` means rcup will try to symlink individual files inside the dir, breaking the single-symlink approach.

### 4. Verify

```bash
# Symlink target correct
readlink ~/.<tool>

# Git sees only the intended files
cd ~/dotfiles && git add -n <tool>/

# Secrets excluded
git add -n <tool>/.env <tool>/auth.json 2>&1  # should not list them

# Tool still works through the symlink
ls ~/.<tool>/<config-file>
```

## What to Track vs Ignore

### Track (portable user config)
- Main config file (`config.yaml`, `settings.json`)
- Custom system prompts (`SOUL.md`, `CLAUDE.md`)
- User-authored commands/skills
- Keybindings
- `tui-theme-boot.json` — user-customized Hermes theme/skin
- `slack-manifest.json` — Slack app manifest (if using Slack gateway)
- `memories/MEMORY.md`, `memories/USER.md` — user-authored persistent memory; portable between machines

### Ignore (runtime/secrets/binary)
- `.env` — API keys and credentials
- `auth.json` — OAuth tokens
- `auth.lock`, `mcp-tokens/` — auth state and tokens
- `sessions/`, `state.db*` — session history
- `cache/`, `logs/` — runtime state
- `cron/` — scheduled job executions
- `hermes-agent/`, `node/`, `bin/` — vendored binaries (reinstalled by installer)
- `bootstrap-cache/`, `desktop/`, `audio_cache/` — runtime artifacts
- Built-in skills — reinstalled on update; only track custom ones
- `*.json` cache files (model lists, provider info)

See `references/tool-config-inventory.md` for per-tool breakdowns.
See `references/migrating-claude-to-hermes.md` for the Claude → Hermes config/skill/command migration workflow.

## Pitfalls

- **Don't track built-in skills.** They're reinstalled on every update and change frequently. Only track user-authored skills. The `.gitignore` should leave `skills/` ignored by default; uncomment the `!skills/**` line only when you have custom skills to track.
- **Don't forget `EXCLUDES` in rcrc.** Without it, `rcup` will descend into the symlinked dir and create individual file symlinks, creating a mess.
- **Don't move the dir while the tool's installer is running.** A `hermes setup` or update in progress writes to the dir. Check with `ps aux | grep <tool>` first.
- **The `*` whitelist pattern needs every path segment unignored.** When `*` ignores everything, git cannot re-include a file inside a directory whose parent is still ignored. `!skills/` un-ignores the `skills/` entry itself but NOT its contents — `skills/github/` stays ignored by `*`. You must explicitly unignore EACH directory in the path down to the files: `!skills/github/` AND `!skills/github/my-skill/` AND `!skills/github/my-skill/**`. Omit any level and nothing below it is tracked. This is why `!skills/software-development/` worked (we listed it) but `!skills/github/` initially didn't (we forgot that level).
- **`!skills/**` alone is insufficient for selective tracking.** If you want to track only SOME skills (custom) but not others (built-in), you cannot use `!skills/**` — that un-ignores everything including built-ins. Instead, use `!skills/` + `!skills/<category>/` + `!skills/<category>/<custom-skill>/` + `!skills/<category>/<custom-skill>/**` for each custom skill individually.
- **Shortcut: `!skills/<category>/**` when all skills in a category are custom.** If every skill under a category (e.g., `software-development/`) is user-authored, you can track the whole category at once with `!skills/<category>/**` instead of listing each skill individually. This avoids the maintenance burden of adding new custom skills one by one. Only use this when you're confident the category has no built-in skills — check with `ls skills/<category>/` first.
- **Secrets may be commented but still present.** An `.env` where all keys are commented out still shouldn't be tracked — the user may uncomment them later, and git history is forever.
