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

## Project-Specific: clinical-language-models

Deployment configs use **ytt** (Carvel). See `references/ytt-deploy-structure.md` for paths, template structure, liveness probe editing, and redeployment.

## Related References

- `references/ytt-deploy-structure.md` — ytt deploy layout for clinical-language-models
