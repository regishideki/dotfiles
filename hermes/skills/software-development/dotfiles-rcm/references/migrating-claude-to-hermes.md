# Migrating Claude Config to Hermes

Workflow for symlinking `~/.hermes` into an rcm dotfiles repo and migrating
Claude skills/commands into Hermes skills. Developed when a user who already
had `~/.claude` symlinked wanted the same for `~/.hermes`.

## 1. Symlink ~/.hermes into the repo

Same 4-step pattern as the main SKILL.md, but Hermes is 2.7GB (vs Claude's
~50MB) — the `.gitignore` whitelist is mandatory, not optional.

```bash
mv ~/.hermes ~/dotfiles/hermes && ln -s ~/dotfiles/hermes ~/.hermes
```

Safe while Hermes is running: `mv` on the same filesystem is atomic.

Track only: `config.yaml`, `SOUL.md`, `.gitignore`, and custom skills.
Everything else (2.7GB of binaries, caches, secrets) is gitignored.

## 2. Migrate Claude skills → Hermes skills

Claude and Hermes skills use the same format (YAML frontmatter + markdown
body). Hermes has additional optional fields (`version`, `author`, `license`,
`platforms`, `metadata.hermes.tags`) that Claude skills lack.

### Direct copy (format-compatible)

Claude skills can be copied as-is — the frontmatter is compatible. To make
them feel native, add the Hermes peer fields:

```yaml
---
name: my-skill                    # same
description: "..."                # same (quoted for safety)
version: 1.0.0                    # ADD
author: <user>                    # ADD
license: MIT                      # ADD
platforms: [linux, macos, windows] # ADD
metadata:                         # ADD
  hermes:
    tags: [tag1, tag2]
    related_skills: [other-skill]  # optional cross-refs
---
```

### Placement

Hermes organizes skills by category subdirectories:
`skills/<category>/<skill-name>/SKILL.md`. Categories: `github`,
`software-development`, `productivity`, `creative`, `research`, etc.

Pick the closest category. Don't invent new top-level categories.

## 3. Migrate Claude commands → Hermes skills

Hermes has NO equivalent of Claude's custom slash commands (`~/.claude/commands/*.md`
becoming `/command-name`). All Hermes slash commands are built-in (registered in
`hermes_cli/commands.py`).

**Conversion:** each Claude command `.md` file becomes a Hermes skill. The
body (instructions/procedure) carries over directly. Wrap it in Hermes
frontmatter and place under the appropriate category.

### Conversion checklist (per command)

1. Read the Claude command file.
2. Determine the target category (most are `github` for PR/review workflows,
   `productivity` for deepwork-style).
3. Create `skills/<category>/<command-name>/SKILL.md` with Hermes frontmatter.
4. Copy the body verbatim — it's already procedural instructions.
5. Replace Claude-specific references:
   - `/pr-analyse-comments` (command) → `pr-analyse-comments` (skill name)
   - `Skill` tool invocations → just reference the skill name
   - `$ARGUMENTS` → "the arguments provided" (Hermes skills aren't invoked
     with positional args the same way; they're loaded by the agent)
6. Add `related_skills` cross-references where one skill calls another.

### Common Claude → Hermes reference replacements

| Claude | Hermes |
|---|---|
| `/command-name` (slash command) | `skill-name` (skill, loaded by agent) |
| `Skill` tool | Agent loads skill via `skill_view` |
| `$ARGUMENTS` | "arguments provided to the agent" |
| `mcp__claude_ai_Claude_Code_Remote__*` | stays as-is (CCR MCP, not Hermes-native) |

## 4. Update .gitignore for custom skills

Custom skills must be explicitly un-ignored at EVERY path level. See the
pitfall in the main SKILL.md about path segments. For each custom skill:

```gitignore
!skills/<category>/
!skills/<category>/<skill-name>/
!skills/<category>/<skill-name>/**
```

The `!skills/<category>/` line is mandatory — without it, git ignores the
category directory entirely and nothing below it is tracked.

## 5. Verify

```bash
# All custom skills tracked, no built-ins leaked
cd ~/dotfiles && git add -n hermes/skills/

# Symlink intact
readlink ~/.hermes

# Hermes still running
ps aux | grep hermes-agent/hermes | grep -v grep
```

## Key differences: Claude vs Hermes config

| Aspect | Claude (~/.claude) | Hermes (~/.hermes) |
|---|---|---|
| Size | ~50MB | 2.7GB |
| Custom commands | `commands/*.md` → slash commands | None (all built-in) |
| Skills format | YAML frontmatter + body | Same + optional `metadata.hermes` |
| Skills location | `skills/<name>/` (flat) | `skills/<category>/<name>/` (categorized) |
| Built-in skills | Reinstalled on update | Same |
| Config file | `settings.json` | `config.yaml` |
| System prompt | `CLAUDE.md` | `SOUL.md` |
| Secrets | `.credentials.json` | `.env` + `auth.json` |
