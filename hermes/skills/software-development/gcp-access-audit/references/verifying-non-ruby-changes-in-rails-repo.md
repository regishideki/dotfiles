# Verifying non-Ruby changes in a Rails/standardrb repo

`AGENTS.md` says "run `make lint` / `bundle exec standardrb --fix` before
committing", but that rule targets `.rb` changes. When a change is a shell
script, Makefile target, YAML, or other non-Ruby file:

- `bundle exec standardrb <path>` run against a non-`.rb` file (e.g. a
  Makefile or `.sh`) tries to parse it as Ruby and produces a wall of
  `Lint/Syntax` errors. This is **expected tool misuse, not a real failure**
  — standardrb only auto-scopes to `.rb` files when run with no args, so
  `make lint` alone never touches shell/Makefile changes.
- Verify shell scripts with `shellcheck <script>.sh` (install via
  `brew install shellcheck` if missing) and `bash -n <script>.sh` for a
  syntax check. Verify a new Makefile target by running `make -n <target>`
  (dry-run, checks parsing/dependency resolution without executing).
- If `make lint` reports offenses in paths you did not touch (e.g. a
  personal `custom_gitignore/` snippets folder gitignored via `~/.gitignore`),
  confirm with `git status --short <path>` and `git log --oneline -1 -- <path>`
  before assuming they're pre-existing baseline noise — an empty log means
  the path was never committed and is local-only, not part of the repo's lint
  baseline.
- `make test` / `make build` are not applicable when the diff contains no
  Ruby/app code (pure tooling/infra scripts) — say so explicitly rather than
  running them for form's sake.
