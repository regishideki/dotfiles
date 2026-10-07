# Unblocking a PR stuck in BLOCKED state (babysit-until-merge)

A PR can sit at `mergeStateStatus: BLOCKED` while `mergeable: MERGEABLE` and
`reviewDecision: APPROVED` — green required checks + approval is NOT sufficient. GitHub says
"blocked" because of a branch-protection rule. This is the recipe for the "faça um babysit neste
PR até ele ser mergeado" task. Diagnose first, then fix the specific blocker.

## Step 0 — read the three merge signals together

```bash
gh pr view <N> --repo <owner/repo> \
  --json state,mergeable,mergeStateStatus,reviewDecision,isDraft,headRefName
```

`mergeStateStatus` is authoritative ("can I merge now"). `mergeable` alone is misleading (it only
means "no conflicts"). When BLOCKED persists, dump the branch protection:

```bash
gh api repos/<owner>/<repo>/branches/main/protection \
  | python3 -c "import json,sys; d=json.load(sys.stdin); \
print('checks:', [c.get('context') for c in d['required_status_checks']['checks']]); \
print('strict:', d['required_status_checks']['strict']); \
print('approvals:', d['required_pull_request_reviews']['required_approving_review_count']); \
print('conversation_resolution:', d['required_conversation_resolution']['enabled']); \
print('linear_history:', d['required_linear_history']['enabled'])"
```

## Blocker 1 — GitHub Actions outage cancelled/queued checks

Symptom: `gh pr checks` shows `Run tests (1,4) … CANCELLED`, `Run linters … CANCELLED`, or a check
`pending` far longer than normal. Common after a GitHub Actions incident (the user's "o actions
ficou parado um tempo").

Fix — re-dispatch only the failed/cancelled jobs (cleaner than an empty commit):

```bash
gh run list --repo <owner/repo> --branch <branch> --limit 5   # find the RUN_ID
gh run rerun <RUN_ID> --repo <owner/repo> --failed
```

An empty-commit push also re-triggers but adds a new SHA + noise.

## Blocker 2 — third-party check suites stuck in QUEUED

Symptom: required checks green but still BLOCKED. GitHub Apps beyond your workflows (Vercel,
Cursor, Claude, Figma, Datadog Official, etc.) can hold a `QUEUED` check suite that never started.
Inspect check SUITES (not just check runs):

```bash
gh api graphql -f query='query { repository(owner:"O", name:"R") {
  pullRequest(number: N) { commits(last:1){nodes{commit{
    checkSuites(first:30){nodes{ app{name} status conclusion }}
  }}}} } }'
```

A third-party app `QUEUED` with no workflow run is NOT one of your required checks — ignore it; it
does not block. The real blocker is usually conversation resolution (below).

## Blocker 3 — required_conversation_resolution + an open review thread

Symptom: `required_conversation_resolution.enabled` is true and a review thread (often from
`genialcare-engineering-agent[bot]` or `gemini-code-assist[bot]`) is unresolved. GitHub blocks the
merge until EVERY thread is resolved — even a thread the bot tagged "não-bloqueante"/non-blocking.

Find unresolved threads:

```bash
gh api graphql -f query='query { repository(owner:"O", name:"R") {
  pullRequest(number: N) { reviewThreads(first:20){nodes{ id isResolved
    comments(first:1){nodes{ author{ login } body }} } } } }'
```

Read the body (`gh api repos/<owner>/<repo>/pulls/<N>/comments --jq '.[].body'`). If the
suggestion is legitimate and cheap (e.g. "add one test covering this regression"), implement it —
that resolves the thread properly AND re-triggers CI in the same push. If already addressed or
noise, reply and resolve. To resolve:

```bash
# 1. (optional) reply — POST /pulls/{n}/comments/{comment_id}/replies
gh api repos/<owner>/<repo>/pulls/<N>/comments/<COMMENT_ID>/replies \
  -f body="Teste adicionado. Obrigado pela sugestão."

# 2. resolve the thread via GraphQL
gh api graphql -f query='mutation { resolveReviewThread(input: {threadId: "<THREAD_ID>"}) {
  thread { isResolved } } }'
```

## Blocker 4 — remote branch force-pushed/squashed (push rejected "fetch first")

When pushing a follow-up commit and getting `! [rejected] ... (fetch first)`, the remote branch was
force-pushed or squash-rebased since your last fetch — your local commit sits on a stale base.

```bash
git fetch origin <branch>
git log --oneline HEAD..origin/<branch>          # commits you don't have
git log --oneline -3 HEAD                        # find your old base SHA
git rebase --onto origin/<branch> <old-base-sha> # replay just your commit(s)
git push origin <branch>
```

## Verify the unblock

After fixing, the new run must go green again, then:

```bash
gh pr view <N> --repo <owner/repo> --json state,mergeable,mergeStateStatus,reviewDecision
# mergeStateStatus: CLEAN, or state: MERGED if auto-merge = done
```

Poll CI without blocking the foreground 60s clamp using the background self-terminating loop (see
the "Same background-loop pattern" pitfall in genialcare-local-dev SKILL.md).
