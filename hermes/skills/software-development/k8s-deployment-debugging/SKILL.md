---
name: k8s-deployment-debugging
description: "Debug K8s pod restarts, probe failures, rollout issues."
version: 1.0.0
author: regishattori
license: MIT
platforms: [linux, macos]
metadata:
  hermes:
    tags: [kubernetes, k8s, debugging, deployment, pod, probe, ops]
    related_skills: [systematic-debugging]
---

# Kubernetes Deployment Debugging

Systematic investigation of Kubernetes deployment issues: pod restarts, probe failures, resource pressure, and rollout problems.

## When to Use

Use when investigating:
- Pods stuck in CrashLoopBackOff or high restart counts
- Liveness/readiness probe failures
- OOMKilled pods
- Deployments failing to roll out
- Image pull or DNS resolution errors in-cluster

## Investigation Workflow

### Phase 1: Gather Pod State

Start with the pod description — it gives restart count, exit codes, probe config, and events:

```bash
kubectl describe pod POD_NAME -n NAMESPACE
```

Key fields to check:
- **Restart Count** — magnitude of the problem
- **Last State / Exit Code** — 137 = SIGKILL (OOM or probe kill), 1 = app error, 0 = clean exit
- **Liveness/Readiness probe config** — timeoutSeconds, periodSeconds, failureThreshold
- **Events** — probe failure messages often contain the actual error
- **Resources** — requests vs limits, check for OOM patterns

### Phase 2: Check Logs

```bash
# Current container
kubectl logs POD_NAME -n NAMESPACE --tail=100

# Previous crashed container (if restarted)
kubectl logs POD_NAME -n NAMESPACE --previous --tail=100
```

### Phase 3: Identify When It Started — ReplicaSet History

Pod restart loops often coincide with a deployment change or cluster upgrade. Track the timeline:

```bash
# List all ReplicaSets to see deployment history with ages and images
kubectl get replicaset -n NAMESPACE -l app=APP_LABEL -o wide

# Check probe config on old vs current ReplicaSet
kubectl get replicaset OLD_RS -n NAMESPACE -o json | \
  jq '.spec.template.spec.containers[].livenessProbe'
```

**Correlate the ReplicaSet age with:**
1. Git history — what was deployed when?
2. Cloud provider release notes — was there a node/cluster upgrade?
3. Image tags — did the container image change?

```bash
# Git log between old and new deployment images
git log OLD_COMMIT..NEW_COMMIT --oneline

# Check node ages and versions (upgrades)
kubectl get nodes -o wide
```

### Phase 4: Test Probes In-Container

When probe failures are the issue, reproduce the probe manually inside the container:

```bash
# Reproduce EXACTLY what the probe runs
kubectl exec POD_NAME -n NAMESPACE -- <probe command>

# With shell expansion (probes use exec, not shell)
kubectl exec POD_NAME -n NAMESPACE -- sh -c '<probe command with $VARS>'

# Without shell expansion (how exec.command actually runs)
kubectl exec POD_NAME -n NAMESPACE -- <probe command with literal $(VARS)>
```

## Common Pitfalls

### exec.command does NOT use a shell

Kubernetes `exec.command` probes are exec'd directly — no shell, no variable expansion. `$(VAR)`, `$VAR`, pipes, and redirects are passed literally.

**Wrong:**
```yaml
livenessProbe:
  exec:
    command:
    - celery
    - -b $(REDIS_URL)   # literal string, not expanded
    - inspect
    - ping
```

**Right:**
```yaml
livenessProbe:
  exec:
    command:
    - /bin/sh
    - -c
    - celery -b $REDIS_URL inspect ping  # shell expands $REDIS_URL
```

[Kubernetes API reference](https://kubernetes.io/docs/reference/generated/kubernetes-api/v1.36/#execaction-v1-core):
> "The command is simply exec'd, it is not run inside a shell, so traditional shell instructions ('|', etc) won't work. To use a shell, you need to explicitly call out to that shell."

### Containerd version matters

GKE 1.35 upgraded containerd from 1.7 to 2.1. Older containerd versions sometimes ran probes through a shell implicitly — probes that "worked for months" can break after a node upgrade even though they were always technically incorrect.

Check the cloud provider release notes when investigating sudden probe failures on previously stable deployments. [GKE release notes](https://cloud.google.com/kubernetes-engine/docs/release-notes).

### liveness probe timeout too tight

`celery inspect ping` (and similar broker-dependent probes) can take multiple seconds when the worker is busy. A `timeoutSeconds: 1` will kill the probe before it produces useful error output, masking the real problem.

Set `timeoutSeconds: 10` minimum for broker-dependent probes, then investigate the actual error revealed.

### `celery inspect ping` reimports the whole app on every tick

A probe that shells out to `celery -A app.tasks inspect ping` spawns a brand-new
Python process each time, which re-imports the entire app module tree
(Vertex AI SDK, langchain, sqlalchemy, etc.) before it can answer. Measure it:

```bash
kubectl exec POD -n NS -- sh -c '
  START=$(date +%s%N)
  <the exact probe command>
  END=$(date +%s%N)
  echo "duration_ms=$(( (END-START)/1000000 ))"
'
```

If this duration approaches or exceeds `timeoutSeconds`, the kubelet kills the
probe on timeout — not because the worker is unhealthy, but because checking
health costs more than the CPU budget allows. Confirm with
`/sys/fs/cgroup/cpu.stat` (`nr_throttled`, `throttled_usec`) to rule out CPU
throttling compounding the slow import.

**Fix pattern that avoids the whole class of problem:** don't shell out to the
app's CLI for liveness at all. Add a Celery `bootsteps.StartStopStep` that
writes a heartbeat file with a timestamp on a periodic timer (via
`worker.timer.call_repeatedly`, which requires declaring
`requires = {'celery.worker.components:Timer'}` on the step so Timer is
guaranteed initialized first), and clears it in `stop()` so a graceful
shutdown is caught immediately rather than waiting for the file to go stale.
The probe then becomes a plain `find /tmp/heartbeat_file -mmin -1 | grep -q .`
— note the `| grep -q .`, because `find` alone always exits 0 whether or not
it matched anything; only the grep on its output turns "stale/missing" into a
real non-zero exit. This is validated prior art, not a one-off idea — see
`github.com/MrWeeble/celery-live` for an equivalent implementation including
the same `requires=Timer` guard.

### Celery ack-timing masks task loss on worker crash, independent of the probe

Fixing the probe (so the pod stops restarting) does NOT automatically recover
tasks that were silently dropped *while* the pod was crash-looping. Celery's
default behavior acks a task message the moment it's delivered to the worker,
*before* execution — if the worker process dies mid-task (OOM, SIGKILL from a
failed probe, node eviction), the message is already gone from the broker and
the task vanishes with no error, no retry, nothing. This is a **separate**
root cause from any probe misconfiguration and needs its own fix:

```python
app.conf.update(
    task_acks_late=True,             # ack after execution, not before
    task_reject_on_worker_lost=True, # re-queue if the executing process dies
)
```

Both are required together — per Celery's own docs, `task_reject_on_worker_lost`
is necessary *even with* `task_acks_late` enabled, because acks_late alone
still acks on abrupt process death. **Caveat to call out in the PR/comment
when adding this pair:** these settings do NOT protect against a task that
itself crashes the worker process repeatedly (segfault, OOM every attempt) —
`autoretry_for`/`max_retries` only count retries raised as an in-process
exception (`self.request.retries`); that counter never increments if the
process dies before raising/handling anything, so a genuine poison-pill task
can loop redelivery indefinitely. Document explicitly why that risk is
accepted (e.g. "no task here is known to crash its own worker; these settings
target *external* kills unrelated to task logic").

When investigating why some async requests succeeded and others got stuck
`pending` across an incident window, distinguish two independent failure
mechanisms rather than assuming one explains everything: (1) probe
misconfiguration causing repeated restarts, and (2) ack-timing causing
in-flight task loss during those restarts. A request can be `pending` forever
even after mechanism (1) is fixed, because of (2) — reprocessing it manually
(replaying the original request payload) is the way to confirm whether the
stuck state is due to lost-task residue vs. an ongoing bug.

### Dockerfile `poetry update` before `poetry install` silently drifts prod dependencies

If a Dockerfile runs `poetry update` before `poetry install --sync`, every
image build re-resolves dependency versions against current PyPI, ignoring
the committed `poetry.lock` entirely. This means the *exact* dependency
versions running in production can change between builds with **zero
corresponding commit** — including builds triggered by PRs that never touched
`pyproject.toml`/`poetry.lock` (e.g. an unrelated k8s config change). Symptom:
a library that "should be pinned" (e.g. an exact-versioned dep like
`google-adk = "1.13.0"`) starts throwing `TypeError`/`unexpected keyword
argument` from a *different*, loosely-ranged co-dependency (e.g.
`google-cloud-aiplatform = "^1.38.0"`) whose newer release now calls the
pinned lib with an argument it doesn't support yet.

To confirm this is the cause (not a code regression from the current PR): pull
the *previous* production image tag and diff `poetry show` (full listing, not
a single-package grep — `poetry show <pkg>` can show a cached/stale value)
against the current one. If versions differ despite no lockfile-touching
commit between the two builds, `poetry update` is the culprit.

**Fix:** remove `poetry update` from the Dockerfile; keep only
`poetry install --no-root --sync`, which respects the lock. Future dependency
bumps then require an explicit `poetry lock` + committing the resulting
`poetry.lock`, making changes reviewable in PRs instead of silently drifting.
Bumping one package to fix an incompatibility can cascade into loosening
version constraints on other packages (e.g. bumping an agent SDK forces a
web-framework bump because of a transitive ASGI-library floor) — resolve
these with `poetry lock` iteratively (loosen the pin causing the conflict,
re-run `poetry lock`, repeat) rather than guessing exact versions by hand.

**When a reviewer (human or bot) suggests switching an exact pin to a caret
range (`^`) for "safety", test it before applying — don't assume caret is
strictly safer.** A caret on a `0.x.y` version is patch-locked by poetry/semver
convention (`^0.115.14` == `>=0.115.14,<0.116.0`), which can be *tighter* than
the range you just loosened to fix the very conflict under discussion. Apply
the suggested constraint change in isolation, run `poetry lock`, and read the
result: if it fails with an "is incompatible with" message, that part of the
suggestion is wrong and you now have the exact error text to cite back to the
reviewer. Accept/reject each part of a multi-package suggestion independently
— e.g. `^` may be fine on the package actually being bumped (widens future
patch/minor updates without re-touching `pyproject.toml`) while being wrong on
an unrelated package whose current wide-open range is load-bearing for the fix.

## References

- `references/exec-command-pitfall.md` — Kubernetes API docs and GKE release notes on exec command behavior
