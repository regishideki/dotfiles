# YTT Deploy Structure — clinical-language-models

## Overview

This project uses **ytt** (Carvel) for Kubernetes manifest templating. Configs are split across environments with overlays.

## Key Paths

```
deploy/
  base/
    clinical-llm/
      manifests/
        deployment.yaml    # ytt template (worker.healthCheck.livenessProbe)
      config/
        overlays.yaml      # common overlay values
        schema.yaml        # ytt schema
  {production,staging,development}/
    clinical-llm/
      config/
        data.yaml          # environment-specific values
```

## How Liveness Probes Work

The template in `deploy/base/clinical-llm/manifests/deployment.yaml` reads:
```yaml
#@ if hasattr(worker.healthCheck, "livenessProbe"):
livenessProbe: #@ worker.healthCheck.livenessProbe
#@ end
```

The env-specific values come from `deploy/{env}/clinical-llm/config/data.yaml` under `workers.healthCheck`:
```yaml
workers:
  healthCheck:
    livenessProbe:
      exec:
        command:
        - poetry
        - run
        - celery
        - -b $(REDIS_URL)
        - inspect
        - ping
      initialDelaySeconds: 30
      periodSeconds: 30
      timeoutSeconds: 10   # was missing (k8s default = 1s)
```

## Pitfalls

- **Missing `timeoutSeconds`** — k8s defaults to 1s. Commands doing network round-trips (Redis, HTTP) need 5-10s minimum.
- **`inspect ping` on busy workers** — Celery's `inspect ping` requires broker round-trip. If the worker is processing a long task (LLM calls), the response can take seconds.
- **`failureThreshold` default is 3** — combined with 1s timeout and 30s period, the pod gets killed after ~90s of probe failures.

## Editing Liveness Probes

To change the probe, edit ONLY the `data.yaml` for the target environment. The template in `base/` should not need changes for timeout adjustments.

After editing, redeploy via kapp:
```bash
# Deploy to production (handled by CI/CD pipeline)
kapp deploy -a clinical-llm -f <(ytt -f deploy/base/ -f deploy/production/)
```
