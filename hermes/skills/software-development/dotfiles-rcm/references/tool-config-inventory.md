# Tool Config Inventory

Per-tool breakdown of what files exist, what to track, and what to ignore when symlinking into an rcm dotfiles repo.

## Claude (~/.claude → ~/dotfiles/claude)

The reference implementation of this pattern.

**Track:**
- `CLAUDE.md` — global instructions
- `settings.json` — permissions, model config
- `keybindings.json`
- `commands/` — user-authored slash commands
- `skills/` — user-authored skills (built-in ones are reinstalled)
- `statusline-command.sh`

**Ignore (via .gitignore whitelist `*` pattern):**
- `.credentials.json` — OAuth tokens
- `history.jsonl` — conversation history (1MB+)
- `projects/` — per-project state
- `sessions/`, `session-env/` — session runtime
- `cache/`, `debug/`, `logs/`
- `paste-cache/`, `file-history/`, `shell-snapshots/`
- `plans/`, `tasks/`, `todos/`
- `plugins/marketplaces/` — auto-generated marketplace data
- `stats-cache.json`, `statsig/`, `telemetry/`
- `daemon*`, `hooks/`, `jobs/`
- `settings.local.json` — machine-specific, intentionally not shared

**rcrc entries:**
```
EXCLUDES="... claude"
SYMLINK_DIRS="claude"
```

## Hermes (~/.hermes → ~/dotfiles/hermes)

**Track:**
- `config.yaml` — main config (settings only, no secrets; 8KB)
- `SOUL.md` — custom system prompt (514B)

**Ignore (2.7GB+ of runtime):**
- `.env` — API keys (all keys may be commented but still don't track)
- `auth.json` — OAuth tokens and credential pools
- `auth.lock`
- `hermes-agent/` — 2.4GB source code + venv (reinstalled by `hermes setup`)
- `node/` — 187MB Node.js runtime
- `bin/` — 69MB vendored binaries
- `hermes-setup` — 11MB installer binary
- `models_dev_cache.json` — 3.1MB cached model list
- `provider_models_cache.json`, `ollama_cloud_models_cache.json`
- `state.db*` — SQLite session store
- `sessions/` — gateway routing, transcripts
- `cron/` — scheduled job executions DB
- `cache/`, `logs/`, `bootstrap-cache/`
- `memories/` — injected at runtime
- `skills/` — all built-in (reinstalled on update)
- `pairing/`, `hooks/`, `image_cache/`, `audio_cache/`
- `.hermes_history`, `.update_check`, `.skills_prompt_snapshot.json`

**rcrc entries:**
```
EXCLUDES="... hermes"
SYMLINK_DIRS="... hermes"
```

**Key difference from Claude:** Hermes is much heavier (2.7GB vs ~50MB) because it bundles its own source, venv, and Node runtime inside `~/.hermes`. The `.gitignore` whitelist (`*` then `!file`) is not optional here — without it, `git status` takes seconds and backups balloon.

## General Pattern for New Tools

When adding a new tool, run these to inventory it:

```bash
# Size breakdown
du -sh ~/.<tool>/* 2>/dev/null | sort -rh | head -20

# Check for secrets
grep -iE '(key|secret|token|password|api)' ~/.<tool>/* 2>/dev/null
grep -vE '^#|^$' ~/.<tool>/.env 2>/dev/null  # active (uncommented) env vars

# Check config file for embedded secrets
cat ~/.<tool>/config.yaml | grep -iE '(key|secret|token|password)'

# Is the tool currently running? (safe to move if so, but check)
ps aux | grep <tool> | grep -v grep
```

Rules of thumb:
1. If a file has secrets or credentials, ignore it — even if commented out.
2. If a dir is binary/runtime (venv, node_modules, caches), ignore it.
3. If a file is user-authored config that's portable across machines, track it.
4. If skills/commands are built-in (reinstalled on update), don't track them — only track user-authored ones.
5. When in doubt, start with `*` (ignore all) and unignore file-by-file. Easier to add than to remove from history.
