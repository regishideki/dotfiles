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
- **Root-level custom skills need their own entries.** Not all custom skills live under a category directory like `software-development/` or `github/`. Skills created directly at `skills/<name>/` (e.g., `skills/create-user-story/`, `skills/explain-diff/`, `skills/fable-method/`, `skills/ost-construction/`) are at the root level and fall outside any existing category whitelist. They need explicit `!skills/<name>/` + `!skills/<name>/**` entries — the parent `!skills/` un-ignores only the directory entry itself, not its children. When adding a new root-level skill, always check `git check-ignore skills/<name>/SKILL.md` and add entries if it returns the catch-all `*` rule.
- **Detection: `git check-ignore -v <path>`** tells you exactly which rule is ignoring a file. Use it to verify new whitelist entries work: if the output shows `!skills/<name>/**` (un-ignore), the skill is tracked. If it shows `*` (catch-all), the whitelist is missing that path.
- **Hermes auto-compacts `memories/MEMORY.md` and `memories/USER.md` mid-session.** The runtime rewrites these files to stay under the char budget, so `git status` can show them as "modified" right after you just committed them — the diff is the runtime's compaction, not new user-authored content. Before finalizing a commit/push, re-run `git status`: if memories reappear as modified, inspect `git diff hermes/memories/` and commit the compaction separately (`memories: auto-compaction by Hermes runtime`) rather than bundling it into a thematic commit. Don't be surprised when this happens repeatedly across a long session.
- **Secrets may be commented but still present.** An `.env` where all keys are commented out still shouldn't be tracked — the user may uncomment them later, and git history is forever.
- **`.env.example` / template files can have MIXED masking — some values redacted, others left real.** The Firebase-style mask `AIzaSy...NpKo` does NOT mean the whole file is safe. In one session a committed `.env.dev-local.example` template had the Firebase API key masked but the Split.io authorization key (`VITE_SPLIT_IO_AUTHORIZATION_KEY`) and Help Hero key (`VITE_HELP_HERO_KEY`) left as real 32-char/10-char values. A grep scoped to `api[_-]?key` and `{16,}`-min-length missed both. Redact any unmasked real credential to a placeholder consistent with the file's existing masking (`<SPLIT_IO_AUTHORIZATION_KEY>`, `<HELP_HERO_KEY>`). Client-side-but-public config (Firebase `VAPID_KEY`, `APP_ID`, Auth0 SPA `CLIENT_ID`, `ORG_ID`, `CUSTOMER_ID`) is fine to commit as-is.
- **Pre-commit secret scan — run it on EVERY dotfiles commit, not just when you touched secrets.** The durable recipe:
  1. `git diff --cached` (and `git ls-files --others --exclude-standard`) piped through a BROAD grep: `(KEY|SECRET|TOKEN|PASSWORD|AUTHORIZATION|api[_-]?key|AKIA|ghp_|AIza[A-Za-z0-9_-]{20,})`, plus a client-env prefix pass (`VITE_`, `NEXT_PUBLIC_`, `REACT_APP_`, `x-api-key`, `Bearer `). A single narrow regex WILL miss things.
  2. Manually `read_file` every `.env*`, `*.example`, `templates/*`, and `references/*` file that could embed a real value. Grep is a net, not a proof.
  3. Confirm any `x-api-key`/token in committed content is already masked as `***` (Hermes redaction) or a `<PLACEHOLDER>`.
  4. Verify after redaction with an ad-hoc check that asserts the real values are gone and the placeholders are present (a tiny `hermes-verify-*` script under the temp dir, removed after).
