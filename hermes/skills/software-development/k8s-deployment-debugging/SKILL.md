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

## References

- `references/exec-command-pitfall.md` — Kubernetes API docs and GKE release notes on exec command behavior
