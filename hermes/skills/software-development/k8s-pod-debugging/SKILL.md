---
name: k8s-pod-debugging
description: "Debug K8s pod restarts, OOMKills, and liveness probe loops."
version: 1.0.0
platforms: [linux, macos]
metadata:
  hermes:
    tags: [kubernetes, k8s, debugging, pods, restarts, liveness-probe, CrashLoopBackOff, OOMKill]
    related_skills: [systematic-debugging, docker-troubleshoot]
---

# Kubernetes Pod Debugging

Investigate pod failures systematically: restarts, CrashLoopBackOff, OOMKills, and liveness probe loops. Works with any k8s cluster (GKE, EKS, AKS, kind).

## When to Use

- Pod showing high restart count
- Pod stuck in CrashLoopBackOff
- Pod being killed repeatedly by liveness probe
- Suspected OOMKill (exit code 137)
- Any pod in non-Ready / non-Running state

## Investigation Workflow

Execute in this order. Each step feeds the next.

### Step 1: `kubectl describe pod` — the single most important command

```bash
kubectl describe pod <pod-name> -n <namespace>
```

Key sections to read:

| Section | What to look for |
|---------|-----------------|
| `State` / `Last State` | `Reason` (Error, OOMKilled, Completed), `Exit Code` |
| `Restart Count` | High = restart loop. Compute restart rate: count ÷ pod age. |
| `Liveness` / `Readiness` | Probe command, `timeoutSeconds`, `failureThreshold`, `periodSeconds` |
| `Limits` / `Requests` | memory, cpu — compare requests vs limits |
| `Events` | Most recent events at the BOTTOM. Look for `Killing`, `Unhealthy`, `BackOff`, `OOMKilling`. |

### Step 2: Check ReplicaSet history — when did restarts begin?

```bash
kubectl get replicaset -n <namespace> -l app=<app-label> -o wide
```

Look at the image tags (`main-<hash>`) across ReplicaSets. Find which ReplicaSet/deployment first showed the issue. Then cross-reference:

1. **Git history** — did the probe config or app code change between the stable and problematic deployments?
2. **Node age** (`kubectl get nodes -o wide`) — were nodes upgraded/recreated around the same time? A containerd/kubelet version change can alter exec probe behavior (see Advanced section below).

This tells you whether the root cause is a config change, code change, or infrastructure change.

### Step 3: Interpret exit codes

| Exit Code | Meaning | Likely Cause |
|-----------|---------|-------------|
| 0 | Success | Normal exit (rare for long-running pods) |
| 1 | General error | Application error — check logs |
| 137 | SIGKILL (128+9) | **OOMKill** (kernel) OR **kubelet kill after liveness probe failure** OR **preStop hook timeout**. Check `Reason` in describe. |
| 143 | SIGTERM (128+15) | Graceful termination (normal on scale-down/deploy) |

**Exit 137 is NOT always OOM.** If memory usage is low (check `kubectl top`), the SIGKILL came from the kubelet after the liveness probe failed and terminationGracePeriodSeconds expired.

### Step 4: `kubectl top pod` — live resource usage

```bash
kubectl top pod <pod-name> -n <namespace>
```

Compare against `Limits` from describe:
- Memory near limit → OOMKill likely
- Memory far below limit → not OOM — probe timeout or app crash
- CPU near limit → throttling, not killing (CPU is compressible)

### Step 5: `kubectl logs` — check previous instance

```bash
# Current container logs
kubectl logs <pod-name> -n <namespace> --tail=100

# Logs from PREVIOUS crashed container (CRITICAL for restart loops)
kubectl logs <pod-name> -n <namespace> --previous --tail=100
```

`--previous` is essential — the current container just started, so its logs show startup. The previous container's logs show what happened before the crash.

### Step 6: Check events timeline

```bash
kubectl get events -n <namespace> --field-selector involvedObject.name=<pod-name> --sort-by='.lastTimestamp'
```

Reconstruct the sequence: `Pulling → Started → Unhealthy → Killing → BackOff → Pulling → ...`

### Step 7: Check deployment/replicaset config

```bash
kubectl get deployment <deploy-name> -n <namespace> -o yaml
```

Verify liveness/readiness probe config, resource limits, and args match expectations.

## Common Patterns

### Pattern 1: Liveness probe timeout loop

**Symptoms:**
- High restart count, regular interval (~every N minutes)
- Events: `Liveness probe failed: command timed out`, `Killing: failed liveness probe`
- Exit code 137
- Memory usage low (not OOM)

**Root cause:** `timeoutSeconds` too low for the probe command. Default is 1s — insufficient for commands that do network round-trips (e.g., `celery inspect ping`, `redis-cli ping`, HTTP health checks to slow endpoints).

**Fix:** Increase `timeoutSeconds` (10s is a safe default for most probes). Also consider increasing `failureThreshold` (3→5) for extra tolerance.

**Pitfall:** A too-short timeout can MASK the real error. When `timeoutSeconds=1`, k8s kills the probe process before it produces any error output. Events show only "command timed out" — not the actual traceback. If you increase the timeout and suddenly see a different error (DNS failure, connection refused, etc.), the probe was always broken — you just revealed the real cause. See Pattern 4 for the common case of unexpanded shell variables.

### Pattern 2: OOMKill

**Symptoms:**
- Exit code 137
- Reason: `OOMKilled`
- Memory usage near or at limit
- Events mention OOMKilling

**Fix:** Increase `memory.limits` OR fix memory leak in application.

### Pattern 3: CrashLoopBackOff from app error

**Symptoms:**
- Exit code 1
- Reason: `Error`
- Logs show exception/panic on startup

**Fix:** Debug the application error. Use `--previous` logs.

### Pattern 4: Shell variable in exec.command not expanded

**Symptoms:**
- Probe command uses `$(VAR_NAME)` or `${VAR_NAME}`
- Events show `Unhealthy` with traceback containing `socket.gaierror: [Errno -2] Name or service not known`
- OR probe always times out, restart loop infinite
- Worker IS running and processing tasks (it's not a worker crash)

**Root cause:** Kubernetes `exec.command` does NOT invoke a shell. Each array element is passed directly via execve(). The string `$(REDIS_URL)` is passed LITERALLY — Celery/AMQP tries to resolve it as a hostname → DNS failure.

See `references/probe-shell-var-not-expanded.md` for the exact error traceback and reproduction recipe.

**Why it can hide:** A too-short `timeoutSeconds` (e.g. 1s) kills the probe process before it produces the traceback. Events show only "command timed out" — not the real error. Increasing the timeout reveals the DNS failure. But the probe was always broken.

**Why it can masquerade as working:** Older containerd/Docker-shim versions sometimes ran exec probes through `/bin/sh -c`, which expanded shell variables. After a node upgrade (e.g., GKE 1.35 + containerd 2.1.7), the new runtime exec's the command directly — no shell. A probe with `$(VAR)` that expanded fine for months will suddenly pass the literal string. Check node age/version against when restarts began.

**Detection — the definitive test:**
```bash
# This WILL fail (no shell expansion, same as exec.command):
kubectl exec <pod> -n <ns> -- poetry run celery -b '$(REDIS_URL)' inspect ping

# This WILL work (shell expands $REDIS_URL):
kubectl exec <pod> -n <ns> -- sh -c 'poetry run celery -b $REDIS_URL inspect ping'
```

**Fix:** Wrap the probe command in a shell:
```yaml
livenessProbe:
  exec:
    command:
    - /bin/sh
    - -c
    - poetry run celery -b $REDIS_URL inspect ping
```

Or if possible, use a dependency-free health check (e.g., `pgrep -f "celery worker"`).

## Pattern 5: `celery inspect ping` probe never reaches the worker (missing `-A <app>`)

**Symptoms:**
- High restart count, probe ALWAYS fails, no timing correlation to node/deploy changes
- `kubectl exec <pod> -- celery -b $REDIS_URL inspect ping` fails immediately with
  `Error: No nodes replied within time constraint` — every single time, any timeout value
- The worker process is alive and healthy (check `ps aux` in the pod, check worker logs — it's consuming tasks fine)
- Previous fixes (raising `timeoutSeconds`, wrapping in `/bin/sh -c`, quoting `$REDIS_URL`) did NOT help

**Root cause:** the probe command builds a bare/anonymous Celery instance (`celery -b <url> inspect ping`)
instead of loading the actual app module (`celery -A app.tasks -b <url> inspect ping`). If the app's Celery
config sets custom `broker_transport_options` (e.g. `global_keyprefix` for multi-tenant Redis namespacing),
the worker's control/reply pub-sub channels are prefixed, but the bare probe instance talks on unprefixed
channels. They can never see each other on Redis — no timeout fixes this, the probe is structurally broken.

**Diagnostic test:**
```bash
# Fails always, regardless of timeout — bare celery, no app config:
kubectl exec <pod> -n <ns> -- sh -c 'celery -b $REDIS_URL inspect ping --timeout=8'

# Works — loads the app's actual broker_transport_options:
kubectl exec <pod> -n <ns> -- sh -c 'celery -A <app_module> -b $REDIS_URL inspect ping --timeout=8'
```

**Fix:** add `-A <app_module>` (e.g. `-A app.tasks`) to the probe command so it loads the same Celery app
config (global_keyprefix, queues, etc.) as the running worker.

**Lesson:** when previous probe fixes (timeout, shell wrapping, quoting) don't resolve a 100%-failure-rate
probe, suspect the probe isn't even the same logical Celery app as the worker — check `broker_transport_options`
in the app's Celery setup file for anything (keyprefix, custom routing) that a bare `-b <url>` invocation won't pick up.

### Follow-up hardening: target the probe at the local worker with `-d`

Once `-A <app_module>` makes the probe reach the right Celery app, `celery inspect ping` still broadcasts
to **every** worker replica by default and waits for any/all replies. With `replicas: 1` this is harmless,
but the moment replicas > 1 it becomes a correctness and cost problem: one pod's liveness probe can get a
`pong` from a *different* pod's worker, masking that its own local worker is actually dead — plus every
probe tick fans out load to the broker across all workers instead of just checking locally.

**Fix:** direct the probe at the worker running in that specific pod via `-d "celery@$HOSTNAME"` (Celery
node names default to `celery@<hostname>`, and `$HOSTNAME` inside the pod resolves to the pod name):

```bash
poetry run celery -A app.tasks -b "$REDIS_URL" inspect ping -d "celery@$HOSTNAME"
```

Verify the real nodename first (don't assume `celery@$HOSTNAME` — check `kubectl logs <pod> | grep celery@`
for the exact string the worker registered under, e.g. `celery@celery-6d47d69cc9-c2gwt v5.4.0 ready`).

This was raised by a `gemini-code-assist` PR review comment — treat "probe broadcasts to all workers instead
of targeting local" as a standard review point to apply proactively when adding/fixing any `celery inspect`-based
liveness probe, even at replicas=1, since it's a latent bug that only bites when replicas scale up.

## Pattern 6: Liveness probe times out because the probe process itself is slow to start (heavy import chain), not because of network/DNS/app-identity issues

**Symptoms:**
- Worker is demonstrably healthy — logs show `celery@<node> ready.` and real tasks received/succeeded
- Probe command (e.g. `celery -A app.module inspect ping -d "celery@$HOSTNAME"`) is otherwise CORRECT
  (right app module, right target node) — Patterns 4 and 5 are already ruled out
- Restart loop persists anyway, at a roughly fixed interval matching `periodSeconds * failureThreshold`
- Manually running the exact probe command via `kubectl exec` DOES eventually succeed and print `pong` —
  but takes far longer than `timeoutSeconds` (e.g. measured 28-30s against a 10s timeout)
- `kubectl describe pod` events show `Liveness probe failed: command timed out: "..." timed out after <N>s`
  (a timeout message, not an application-level error)

**Root cause:** each probe invocation is a brand-new OS process/interpreter (no shared state with the
running worker). If the CLI entrypoint (`celery -A <app_module> ...`) triggers import of the *whole*
application package on startup — ORM models, ML/cloud SDKs (Vertex AI, boto3, etc.), LLM client libraries
(langchain), tracing agents — that import cost is paid AGAIN on every single probe tick, from cold start,
even though the long-running worker process already paid it once at boot. Heavy SDKs (e.g.
`google.cloud.aiplatform`) can alone cost 10-15s of import time. Combine with CPU limits shared against the
already-running worker's forked children (cgroup throttling: check `nr_throttled`/`throttled_usec` in
`/sys/fs/cgroup/cpu.stat` inside the pod) and total probe latency can exceed 30s.

**Diagnostic — measure the real cost, don't guess:**
```bash
# Wall-clock time of the actual probe command as configured:
kubectl exec <pod> -n <ns> -- sh -c '
  START=$(date +%s%N)
  <exact probe command from kubectl describe pod Liveness line>
  END=$(date +%s%N)
  echo "duration_ms=$(( (END-START)/1000000 ))"
'

# Break down WHERE the time goes — import of the app's Celery/entrypoint module:
kubectl exec <pod> -n <ns> -- sh -c \
  '<python-bin-path> -X importtime -c "import <app_module>"' 2>&1 | sort -t"|" -k2 -rn | head -20

# Check CPU throttling (shared limit with the live worker's child processes):
kubectl exec <pod> -n <ns> -- sh -c 'cat /sys/fs/cgroup/cpu.stat'
```

**Fix (mitigation, ship first):** raise `timeoutSeconds` to comfortably exceed the measured worst-case
duration (e.g. measured ~30s -> set 45s), and raise `periodSeconds`/`initialDelaySeconds` proportionally so
probe executions don't overlap. This stops the bleeding without touching app code — safe to ship immediately.

**Fix (proper, follow-up):** don't invoke the full CLI entrypoint as the probe. Options, roughly in order of\neffort: (a) a dedicated lightweight probe script that only opens a raw connection to the broker (skips\nloading ORM/ML/SDK imports entirely), (b) a heartbeat file the long-running worker touches periodically and\nthe probe just `stat`s, (c) an HTTP health endpoint exposed by a lightweight sidecar/thread inside the\nworker process itself instead of spawning a new process per check. Don't block the immediate production fix\non building this — ship the timeout increase first, track the deeper fix separately.\n\n**Shipped recipe for (b), Celery specifically — heartbeat-file probe (no reimport, no broker round-trip):**\n\nA Celery `bootstep` writes the current timestamp to a file on a fixed interval, using the worker's own\ntimer (so it runs independent of and in parallel with task processing — no false positive when the worker\nis busy on a long task, unlike `inspect ping` which waits on the control bus). The liveness probe becomes a\nplain `find`/`stat` check — no Python interpreter startup, no app import, no Redis round-trip, effectively\ninstant. See `references/celery-heartbeat-probe.md` for the full worked example (bootstep code, Celery app\nregistration, k8s probe YAML, and the exact test pattern used to validate it against a mocked worker timer).\n\n**Before shipping a novel/reviewer-suggested bootstep pattern, validate it against upstream prior art —\ndon't ship the first version that passes your own tests.** After writing the initial heartbeat bootstep\n(triggered by a `gemini-code-assist` review comment) and getting it green in CI, a direct user question —\n\"is this actually safe? does Celery's own docs support this?\" — prompted a documentation/prior-art pass that\nfound TWO real gaps the first version had missed:\n1. Celery's own `Extending/Bootsteps` docs (`docs.celeryq.dev/.../extending.html#timer`) show every example\n   bootstep that touches `worker.timer` declaring `requires = {'celery.worker.components:Timer'}`. Without\n   it, bootstep init order relative to the Timer component is not guaranteed by the API (it happened to work\n   by luck of current internal ordering).\n2. The community's `celery-live` package (github.com/MrWeeble/celery-live, itself based on a public blog\n   post) implements the identical file-heartbeat + bootstep pattern **and** removes the heartbeat file in\n   `stop()` — which the Worker blueprint calls on graceful shutdown. Without that, a gracefully-stopped\n   worker (SIGTERM handled) leaves a stale-but-still-fresh-looking heartbeat file on disk, so the probe can\n   report OK for up to one heartbeat interval after the worker actually stopped serving.\n   Searching `github.com/celery/celery/issues/4079` (an 8+ year community thread) also independently confirmed\n   the CPU/latency complaints about `inspect ping` under Kubernetes that motivated the whole fix.\n\n**Takeaway:** when you implement a fix for a reviewer's concern that has no first-party \"here's the supported\nway\" doc for your exact case, spend 10 minutes searching (a) the library's own extension/plugin docs for the\ncanonical example, and (b) GitHub for prior art solving the identical problem, BEFORE calling the fix done.\nThe canonical example usually encodes constraints (like `requires=`) that aren't obvious from just making your\nown unit test pass. Cite the sources in the PR description — it upgrades \"trust me\" review-comment fixes into\nverifiable ones.\n\n**Pitfall — `find <file> -mmin -N` alone never fails the probe.** `find` prints matching paths but exits\n0 whether or not anything matched (it only fails on a real error, e.g. path doesn't exist... and even a\nmissing path only causes a non-zero exit as a side effect of the error, not because of \"no match\"). A\nliveness probe command of just `find /tmp/heartbeat -mmin -1` will PASS even when the heartbeat file is\nstale, silently defeating the whole check. Always pipe through something that turns \"no output\" into a\nreal failing exit code: `find /tmp/heartbeat -mmin -1 | grep -q .` (exit 0 only if `find` printed the path,\ni.e. the file is fresh; exit 1 if stale or missing). Verify both branches manually before shipping:\n```bash\ntouch /tmp/heartbeat && find /tmp/heartbeat -mmin -1 | grep -q .; echo $?   # expect 0 (fresh)\ntouch -d \"2 minutes ago\" /tmp/heartbeat && find /tmp/heartbeat -mmin -1 | grep -q .; echo $?   # expect 1 (stale)\n```

**Lesson:** when a probe is provably correct (right app, right target, right connectivity) and the worker is
healthy, but restarts persist, measure the probe's own wall-clock cost before assuming another logic bug.
`command timed out` in the k8s event (as opposed to an app-level error message) is the tell that you're
fighting a race against `timeoutSeconds`, not a broken command.

## Pitfall: keep the PR description in sync as the fix evolves through review

When a review comment (bot or human) causes you to change approach mid-PR — not a small tweak, but
swapping the underlying mechanism (e.g. "increase timeout" -> "replace the probe design entirely") —
update the PR body (`gh pr edit N --body "..."`) to describe the FINAL state. Don't leave the
description describing v1 of the fix while the branch has already moved to v2/v3 after addressing
feedback; a reviewer/approver who only reads the description should see what's actually being merged.

When the accepted suggestion is a non-trivial design change and there's no obvious "this is the
officially supported way" doc for your exact case, research before declaring it done: check the
library's own extension/plugin docs for the canonical example, and search GitHub/community prior art
for others solving the identical problem. Cite those sources in the PR description — it upgrades a
"trust me, I addressed the review comment" fix into a verifiable one, and canonical examples often
reveal required details (extra parameters, cleanup on shutdown) that passing your own unit test alone
won't catch. See `references/celery-heartbeat-probe.md`'s "Prior art" section for a worked example
where this research pass caught two real gaps (missing `requires=`, missing shutdown cleanup) in an
implementation that was already green in CI.

## Pitfall: verify the fix actually landed on the target branch before declaring victory

After identifying a probe root cause and committing a fix locally, don't assume it shipped just because
an earlier PR for the same symptom shows as merged. If the repo auto-deletes head branches after merge
(common GitHub default) and you kept committing follow-up fixes to that branch AFTER opening the PR (e.g.
addressing a review comment in one more commit you never pushed), the branch can vanish on merge while your
extra local commit is still just sitting in your local repo, never pushed, never in the PR that merged.

**Always re-verify empirically before reporting a fix as live:**
```bash
git diff origin/main -- <affected files>   # non-empty = the fix is NOT on main yet
kubectl exec <pod> -n <ns> -- sh -c '<the exact probe command from the live deployment>'  # reproduce live
kubectl describe pod <pod> -n <ns> | grep -A3 Events   # restart count still climbing = not fixed
```
A pod's actual `Liveness` command in `kubectl describe pod` is ground truth — compare it token-for-token
against your intended fix (e.g. missing `-A app.tasks` even though the shell-wrapping and quoting fixes
did land). Don't infer from "PR merged" or "CI green" that every intended change is present.

**Recovering an orphaned local fix commit** (branch deleted, commit never pushed):
```bash
git checkout -b <new-branch-name> <orphaned-sha>
git rebase origin/main
git push -u origin <new-branch-name>
gh pr create --base main --head <new-branch-name> --title "..." --body "..."
```

## Advanced: When the probe used to work and suddenly doesn't

A probe that ran fine for months may start failing after a cluster infrastructure change — even when the pod config and app code are identical.

### Suspect: node upgrade changed containerd exec behavior

Look at node age and version:

```bash
kubectl get nodes -o wide
```

If nodes were **recreated recently** (same timeframe as when restarts started) and the kubelet/containerd version changed, the `exec.command` behavior may have changed:

- **Old containerd** (e.g., pre-2.x, or Docker-shim era): sometimes ran exec probes through `/bin/sh -c`, which expanded `$(VAR)` and `${VAR}`.
- **New containerd** (e.g., 2.1.7+ on GKE 1.35): strictly exec's the command array directly — no shell, no variable expansion.

This means a probe with `$(REDIS_URL)` that expanded fine for years will suddenly pass the literal string, causing DNS failures or hangs.

### Timeline analysis

To confirm a node upgrade as the trigger:

1. Check **ReplicaSet history** to find when restarts began:
   ```bash
   kubectl get replicaset -n <ns> -l app=<app> -o wide
   ```
2. Compare image tags (`main-<hash>`) across ReplicaSets to find the deployment that first showed high restarts.
3. Cross-reference with `git log` to confirm no probe config changes between stable and problematic deployments.
4. Check node creation time against the pod start time — if they align within hours, the node upgrade is the likely trigger.

## Pitfall: "restarts stopped" is not the same claim as "the worker is doing its job"

After fixing a liveness-probe restart loop, a user who was burned by past "trust me it's fixed" answers
will often ask a version of "but are tasks actually running?" — don't just re-confirm restart count is 0.
That only proves the probe stopped killing the pod; it says nothing about whether the consumer is actually
pulling and completing work. Absence of task log lines can mean either "broken" or "just no traffic right
now" — you must disambiguate, not assume the charitable case.

Verification steps, in order:
```bash
# 1. Restart count + age (already done, proves probe stopped killing it)
kubectl get pod <pod> -n <ns>

# 2. Worker actually connected and ready (not stuck retrying broker connection)
kubectl logs <pod> -n <ns> -c <container> | grep -i "ready\.\|Connected to redis\|concurrency"

# 3. Real task activity — the only real proof of "doing its job"
kubectl logs <pod> -n <ns> -c <container> | grep -iE "Task .*(received|succeeded|failed)"

# 4. If logs show nothing (could be zero traffic, not broken) — actively probe liveness of the consumer:
kubectl exec <pod> -n <ns> -c <container> -- sh -c \
  'poetry run celery -A <app_module> -b "$REDIS_URL" inspect active -d "celery@$HOSTNAME"'
# "- empty -" + "1 node online" = consumer alive and connected, just no active tasks right now.
# Timeout/no response = consumer genuinely not listening, despite passing liveness probe.
```
A `retry:` line followed by `succeeded` in task logs (e.g. a transient 404 from object storage) is a
GOOD sign, not a red flag — it shows the task pipeline's own retry logic working, distinct from the
k8s-level pod restart problem you were fixing. Don't conflate "one task retried" with "the fix didn't work".

### When the user's "it's still broken" evidence comes from a DOWNSTREAM system, not the pod itself

A user who was burned by the original outage may re-verify by querying a system one or more hops away
from the worker — e.g. a Rails console on a *different* service, checking a status-tracking table
(`AsyncRequest`/job-status/outbox table) that the worker updates asynchronously via pub/sub or a
callback. If they report "I ran the same count query twice and the numbers didn't change" as proof the
fix didn't work, do NOT just re-check the pod. That table's pending/stuck rows may be **historical
residue from the outage window itself** — rows whose originating task was lost mid-crash (message
acked-then-lost, or the worker died before publishing the completion event) and that will NEVER
transition state on their own, fix or no fix, because nothing in the current system knows they exist
anymore. A stable "stuck count" across two checks taken minutes apart is expected for a residue-only
backlog; it does not mean new work is stuck too.

**Disambiguate residue-from-outage vs. currently-broken with a time-bucketed breakdown, not a single count:**
```ruby
# Rails console / rails runner — group by day or hour to see WHEN the stuck rows were created
AsyncRequest.where("created_at >= ?", some_date).group(:status).group(Arel.sql("date_trunc('day', created_at)")).count

# Any created TODAY / in the last N hours still stuck? That's the number that actually matters.
AsyncRequest.where(status: "pending").where("created_at >= ?", Time.current - 2.hours).count

# Is the historical backlog being drained (proves the worker IS processing it, just slowly/in order)?
AsyncRequest.order(created_at: :desc).limit(10).pluck(:created_at, :status, :finished_at)
# finished_at values landing AFTER the fix's deploy time, on rows created BEFORE it, prove the worker
# picked the backlog back up — even though the pending TOTAL looks unchanged (new pending offset old ones clearing).
```

**Mechanism check — WHY rows from the outage window are unrecoverable (Celery + Redis default ack timing):**

If the worker is Celery-on-Redis and the app's `Celery(...)`/`app.conf.update(...)` does NOT set
`task_acks_late=True` (grep the app's celery setup module for it — absence is the default, silent),
the broker acks (removes) a message from its queue **as soon as it's delivered to the worker**, not
after the task finishes. During a liveness-probe restart loop, the kubelet SIGKILLs the container
mid-task on every failed probe cycle. Any task "in flight" at that moment is gone for good: already
acked (won't be redelivered), but never finished (never ran its completion callback / never published
its "done" event to whatever downstream system tracks status). This is precisely why a status-tracking
table on another service can show a spike of permanently-stuck "pending" rows dated exactly to the
outage window — it is not a bug in that other service, and no amount of "wait longer" fixes it.

Confirm the app doesn't already opt out of this behavior before asserting it as root cause:
```bash
grep -n "task_acks_late\|task_reject_on_worker_lost\|acks_late" <celery_app_setup_file>
# absent/false => confirms default ack-early is in effect => explains the permanently-orphaned rows
```

**Follow-up hardening (separate from the probe fix, worth flagging to the user as a distinct follow-up):**
add `task_acks_late=True` and `task_reject_on_worker_lost=True` to the Celery app config. This makes the
broker redeliver a task if the worker dies mid-execution (message only acked after the task actually
completes), preventing silent task loss on ANY future crash — not just liveness-probe loops. Tradeoff:
tasks must be idempotent/safe-to-retry, since a task that dies just before finishing will now re-run
from the top on another worker.

**Cross-check directly against the broker to settle it independently of the app-level table:**
```bash
kubectl exec <pod> -n <ns> -c <container> -- sh -c '
poetry run python3 -c "
import redis, os
r = redis.from_url(os.environ[\"REDIS_URL\"])
prefix = \"<app>:<env>\"  # match the app's resolved_redis_key_prefix / global_keyprefix
for q in [\"high\", \"default\", \"low\"]:
    print(q, r.llen(f\"{prefix}:{q}\"))
# Also check for messages stuck IN-FLIGHT (delivered to a worker, not yet acked) —
# distinct from queued-but-undelivered. Celery's Redis transport tracks these here:
print(\"unacked:\", r.hlen(f\"{prefix}:unacked\"))
print(\"unacked_index:\", r.zcard(f\"{prefix}:unacked_index\"))
"'
```
All queues at 0 (or draining over repeated checks) AND unacked/unacked_index at 0 = broker has no backlog
and nothing stuck mid-delivery; anything still "pending" in the app's own DB table is a bookkeeping/residue
problem in that OTHER service, not a sign the worker/probe fix is incomplete. Report both findings
distinctly: "pod-level fix confirmed (0 restarts, queues empty, tasks completing)" is a separate claim from
"N historical rows in table X are permanently orphaned and need a separate cleanup/backfill job" — don't
let the second finding cast doubt on the first.

**Implemented example of the `task_acks_late` + `task_reject_on_worker_lost` follow-up hardening** (not just
recommended — shipped, tested, and deployed to a real cluster to confirm no regression) is in
`references/celery-heartbeat-probe.md` under "Task-loss hardening". It includes the exact `app.conf.update(...)`
diff with rationale comments, the regression test that asserts both flags are `True` on the built Celery app,
and the tradeoff note (a task that crashes its own worker process, e.g. segfault, can now be redelivered and
re-run — only safe when tasks are already idempotent/retry-safe via `autoretry_for`/`max_retries`, as they
were here).

**Pitfall — inline `rails runner "<ruby with interpolated quotes>"` over kubectl exec breaks on escaping.**
When cross-checking an app-level status table (like `AsyncRequest`) from a Rails console pod to corroborate
what the broker-side check shows, avoid building the Ruby one-liner as a shell-quoted inline string passed
through `kubectl exec ... -- bash -c "bundle exec rails runner \"...\""` — nested quotes around SQL literals
(e.g. `Date.new(...)`, string args to `Arel.sql(...)`) reliably break across the extra layer of shell escaping.
Instead, write the script to a local file, copy it in, then run it as a file:
```bash
cat > /tmp/check.rb <<'EOF'
ActsAsTenant.current_tenant = Tenant.find_genial_tenant
data = Model.where("created_at >= ?", Date.new(2026,8,14))
            .group(:status).group(Arel.sql("date_trunc('day', created_at)")).count
data.sort.each { |k, v| puts "#{k[1]} | #{k[0]} | #{v}" }
EOF
kubectl cp /tmp/check.rb <ns>/<rails-console-pod>:/tmp/check.rb -c <container>
kubectl exec -n <ns> <rails-console-pod> -c <container> -- bash -c 'cd /app 2>/dev/null; bundle exec rails runner /tmp/check.rb'
```
This sidesteps quoting entirely and is trivially reusable for any follow-up query in the same investigation.

## Pitfall: a console/pod prompt or context label naming an environment is not proof you're actually there

A Rails console (or any REPL) prompt like `core(prod)>` reflects how that console process was
launched/labeled — it does NOT reliably prove you're connected to the production database or that any
service call from within it reaches the production backend. A pod running in a `development` Kubernetes
context/namespace can still be started with a prompt/profile name of `prod` (e.g. because it shares a
Rails environment config file, or the console image/profile wasn't customized per-cluster). If a user
reports "eu rodei em prod e funcionou" but your own live investigation shows the production pod is still
running the OLD broken dependency versions, do not conclude the user is wrong or that the bug is
non-deterministic — ask directly which `kubectl config`/namespace/cluster context they actually ran
against, or check whether that console pod's outbound calls are configured to hit a different
environment's backend (e.g. `clinical-llm` API base URL) than the console's own prompt label suggests.
This cost multiple tool calls in one session (re-pulling images, trying to reproduce a "prod" failure
that didn't exist) before the user clarified: "o pod de dev roda com profile de prod, então fica
parecendo que rodei em prod, mas o meu último teste foi em development." Ask this disambiguating
question BEFORE spending tool calls trying to reconcile a contradiction — a contradiction between "user
says it worked in X" and "X's live pods don't have the fix" is a strong signal the environment identity
itself needs to be confirmed, not that something inexplicable happened.

## Verification technique: reproduce a third-party SDK's internal constructor call directly, without a full round-trip

When a bug is inside a third-party SDK's internal object construction (e.g. `Runner.__init__()` called
by a wrapper class like `AdkApp`, itself called deep inside a `stream_query()`/`run()` method), you don't
need to exercise the full call chain (real LLM call, real network round-trip, real auth) to prove a
dependency-version fix resolved it — that full path can hang for 60-90s on auth/network alone, wasting
time on retries. Instead, call just enough of the SDK's public API to trigger the SAME internal
constructor call and check for the specific exception class:

```python
from google.adk.agents import Agent
from vertexai.preview.reasoning_engines import AdkApp

agent = Agent(name="smoke_test_agent", model="gemini-2.0-flash", instruction="test")
app = AdkApp(agent=agent)
app.set_up()   # this alone builds the internal Runner(auto_create_session=True, ...) —
               # the exact code path that raised TypeError before the fix — with no LLM call needed
print("set_up() succeeded")
```

This isolates "did the fix resolve the constructor signature mismatch" from "does the network/auth path
work", and runs in under a second instead of timing out on a real agent invocation. Use this pattern
whenever the reported bug is a `TypeError`/`unexpected keyword argument` from SDK-internal object
construction — find the shallowest public entrypoint that reaches that same construction path.

## Pitfall: disambiguate overloaded terms before chasing the wrong system

Once a session has spent a long stretch deep in one specific meaning of an overloaded noun — "jobs",
"pending", "queue", "requests" — do NOT assume a later user message meaning the same thing when they
reuse that word. Concretely: after a long stretch of creating/removing Hermes `cronjob` monitoring jobs
for a PR-review workflow, a user saying "eu tentei reenviar 2 jobs que foram dropados" was NOT talking
about Hermes cron jobs at all — they meant manually resubmitting `AsyncRequest` rows via a Rails console
command (a completely different "job" concept, from the SAME investigation's earlier root-cause finding
about lost Celery tasks). Burning several tool calls (querying `~/.hermes/cron/executions.db`, listing
cron jobs, inspecting scheduler state) chasing the wrong referent before the user has to say "acho que
estamos falando de coisas diferentes" is a real failure mode — it happened twice in one session. When a
referent is ambiguous and about to trigger an expensive-feeling investigation (multiple tool calls, DB
queries), ask a one-line disambiguating question FIRST instead of picking whichever context is freshest
in your own working memory.

## Pitfall: after answering the literal question, stop — don't cascade into adjacent investigations uninvited

Once you've confirmed the specific thing the user asked about (e.g. "is this exact error message real
and reproducible"), report it and let the user decide the next step. Don't unilaterally keep pulling
every thread visible from there — checking whether a related dependency is also stale, whether the
Dockerfile's build process causes version drift, whether the same bug exists on `main`, etc. — unless
asked. A user saying "cara, acho que você está indo longe demais" means confirming the ask and stopping
WAS the correct scope; each individual follow-on step can be technically sound and still be scope creep.
When you notice yourself opening a new investigation thread beyond the literal ask, pause and offer it
as a question ("quer que eu confirme se isso também acontece no main?") instead of just doing it. This
applies doubly right after a `systematic-debugging`-style root-cause session already delivered its
answer — the instinct to "since I'm already here, let me also check X" is exactly the moment to stop.

## Pattern 7: a bug "appears" with no corresponding code change — suspect non-reproducible Docker builds (`poetry update`/`npm update`/unpinned installs in the Dockerfile)

**Symptoms:**
- A runtime error (e.g. `TypeError`/`unexpected keyword argument` deep inside a third-party SDK) shows up
  today, but the SAME container image tag rebuilt from the SAME `pyproject.toml`/`package.json` worked fine
  days/weeks ago, with **zero commits touching dependencies, lockfiles, or the failing code path** in between.
- `git log --since=<when it worked> -- pyproject.toml poetry.lock` (or `package-lock.json`) is empty.
- The error is inside a vendored/third-party library's internals, not application code you wrote.
- A merge/deploy that "shouldn't" have touched dependencies (e.g. a k8s probe fix, a comment-only commit)
  is incorrectly suspected first — because it's the most recent change, not because it's causally connected.

**Root cause:** the `Dockerfile` runs `poetry update` (or equivalent: `npm update`, `pip install -U`,
anything that re-resolves instead of installing from a committed lockfile) before installing. This means
**every single image build silently re-resolves to whatever the latest compatible versions are AT BUILD TIME**,
completely ignoring the committed `poetry.lock`/`package-lock.json`. Two builds of the identical source tree,
days apart, can and will produce different installed dependency versions with no diff to point at — because
the diff lives in an upstream package registry's release history, not in your repo.

This is exactly how a two-package interop break happens invisibly: package A (e.g. `google-cloud-aiplatform`)
calls an internal API of package B (e.g. `google-adk`) with a keyword argument that only exists starting at
some version of B; B is pinned exact in `pyproject.toml` but A has a loose range (`^1.38.0`); a new release of
A lands in the registry between two unrelated container builds and starts calling that argument — B never
changed, but the pairing broke.

**Diagnostic — don't trust `poetry show <single-package>` for cross-build comparison, it can read a cached/misleading "required by" line. Pull the FULL dependency tree from both images and diff:**
```bash
# Full show from the OLD (working) image
docker pull --platform linux/amd64 <registry>/<image>:<old-tag>
docker run --rm --platform linux/amd64 <registry>/<image>:<old-tag> poetry show > /tmp/old_deps.txt

# Full show from the CURRENT (broken) image, e.g. via kubectl exec on the live pod
kubectl exec -n <ns> <pod> -c <container> -- sh -c 'poetry show' > /tmp/new_deps.txt

diff /tmp/old_deps.txt /tmp/new_deps.txt   # look for version bumps in packages that call into each other
```
An isolated `poetry show <package-name>` for the same package on both images can print an IDENTICAL version
number even when the full `poetry show` diff reveals a real version difference elsewhere in the tree — always
diff the complete list, not a targeted lookup, when hunting for silent build-time drift.

**Fix (immediate, unblocks the user):** identify the two incompatible versions from the diff, pin the
range in `pyproject.toml` tightly enough that they can't drift apart again (e.g. `google-cloud-aiplatform
= "1.111.0"` exact, or a range known-compatible with the pinned sibling package), run `poetry lock`, commit
the updated lockfile.

**Fix (root cause, separate follow-up — don't silently bundle into the immediate pin-fix PR without calling
it out):** change the `Dockerfile` from `poetry update && poetry install ...` to just `poetry install
--no-root --sync` (or `poetry install --sync` without `--no-root` if appropriate) so builds actually respect
the committed lockfile. This is the real fix for "why did this happen at all", but it's a bigger blast-radius
change (every dependency in the project stops silently auto-updating on each build) — flag it as a distinct
recommendation, don't fold it into a hotfix PR the user didn't ask for. See the `systematic-debugging`
scope-creep pitfall: confirm+fix the immediate breakage, then OFFER the Dockerfile fix as a question rather
than just doing it.

## Project-Specific: clinical-language-models

Deployment configs use **ytt** (Carvel). See `references/ytt-deploy-structure.md` for paths, template structure, liveness probe editing, and redeployment.

The `Dockerfile` runs `poetry update` before `poetry install --no-root --sync` — this project is a live
example of Pattern 7 above (a `google-cloud-aiplatform`/`google-adk` version-pairing break appeared between
two builds of `main` with no dependency-touching commits in between, confirmed by pulling and diffing both
image tags' full `poetry show` output).

## Related References

- `references/ytt-deploy-structure.md` — ytt deploy layout for clinical-language-models

## Pattern: validate a probe/deploy fix against a real (non-prod) cluster before letting the user publicize the PR

If the repo has a low-stakes environment (development/staging) with an auto-deploy pipeline wired to
a branch (e.g. push-to-`development` triggers a GitHub Actions workflow that builds+deploys), and the
user asks to confirm a fix "before I share the PR" — don't just trust CI green + local docker-compose
tests. Merge the fix branch into that environment's branch, push, and watch the REAL pod in that
cluster:

```bash
git checkout development && git pull origin development
git merge origin/<fix-branch> --no-edit   # ideally fast-forward, confirms the fix branch is already in sync with main
git push origin development               # triggers the environment's deploy workflow

# poll the triggered workflow run to completion
gh run list --branch development --limit 3 --json databaseId,status,conclusion
for i in $(seq 1 20); do
  S=$(gh run view <run_id> --json status,conclusion)
  echo "$S"; echo "$S" | grep -q '"status":"completed"' && break
  sleep 15
done

# then watch the actual pod, not just describe once — restart count over several minutes is the real signal
kubectl config use-context <env>
kubectl get pods -n <ns> -l app=<app>            # note pod age + restart count
sleep 120 && kubectl get pods -n <ns> -l app=<app>  # restart count still 0 after minutes = real signal
kubectl get events -n <ns> --field-selector involvedObject.name=<pod> --sort-by='.lastTimestamp'
```

A single `kubectl get pods` right after deploy only proves the pod started — it does NOT prove the
liveness probe passes. Wait multiple probe periods (`periodSeconds * a few cycles`) and re-check
restart count and events for `Unhealthy`/`Killing`/`BackOff` before reporting the fix as validated.
This is a stronger claim than "tests pass" or "CI green" — it's the actual failure mode reproduced
and shown resolved on real infrastructure.

**If a review comment lands a follow-up commit on the same branch after you already validated once**
(e.g. `gemini-code-assist` catches a real bug/inaccuracy days later, or you push a fix for a comment),
don't assume the earlier live validation still covers the new commit. Config-only tweaks (e.g. fixing a
code comment, a docstring, a log message) don't need a fresh dev-cluster re-deploy — `make lint` +
`make test` + a diff review are enough. But if the follow-up commit changes actual runtime behavior
(a new flag, a changed probe command, a new bootstep), re-merge into the dev/staging branch and re-watch
the pod for several probe periods again — the same one-`get-pods`-is-not-enough rule applies to every
runtime-affecting commit, not just the first one in a PR.
