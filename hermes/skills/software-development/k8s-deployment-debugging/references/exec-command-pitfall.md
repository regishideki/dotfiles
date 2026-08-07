# Exec Command Shell Expansion Pitfall

## Kubernetes API — ExecAction (authoritative)

Source: https://kubernetes.io/docs/reference/generated/kubernetes-api/v1.36/#execaction-v1-core

> Command is the command line to execute inside the container, the working directory for the command is root ('/') in the container's filesystem. **The command is simply exec'd, it is not run inside a shell, so traditional shell instructions ('|', etc) won't work. To use a shell, you need to explicitly call out to that shell.** Exit status of 0 is treated as live/healthy and non-zero is unhealthy.

## GKE Release Notes — containerd upgrade

Source: https://cloud.google.com/kubernetes-engine/docs/release-notes

> **containerd 2.1:** GKE nodes are now upgraded to containerd 2.1. This release includes performance improvements such as faster image downloads.
>
> **Windows containerd 2.1:** GKE Windows nodes will use containerd 2.1 in 1.35, upgraded from containerd 1.7 in GKE 1.34.

## containerd 2.0 Migration Guide

Source: https://github.com/containerd/containerd/blob/main/docs/containerd-2.0.md

Key changes in containerd 2.0:
- CRI plugin moved from legacy CRI server to sandbox controller
- NRI enabled by default
- CDI enabled by default
- Image verifier plugins

Note: The containerd 2.0 changelog does not explicitly mention exec probe behavior changes, but the major rewrite from 1.7 → 2.x changed the CRI exec path significantly.

## Reproducing the Issue

To test whether a probe command is being shell-expanded:

```bash
# Test WITH shell expansion (what the fix looks like)
kubectl exec POD -n NS -- sh -c 'celery -b $REDIS_URL inspect ping'

# Test WITHOUT shell expansion (what the broken probe does)
kubectl exec POD -n NS -- celery -b '$(REDIS_URL)' inspect ping
```

The first should connect to Redis (may show "No nodes replied" if worker is busy, which is fine).
The second will fail with `socket.gaierror: [Errno -2] Name or service not known` — confirming the variable is not expanded.
