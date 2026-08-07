# Probe Error: Shell Variable Not Expanded

## Error Signature

When a Kubernetes `exec.command` probe passes a shell variable literally (e.g., `$(REDIS_URL)`), the key error in `kubectl describe` events is:

```
Warning  Unhealthy  ...  Liveness probe failed: Traceback (most recent call last):
  ...
  File ".../amqp/transport.py", line 175, in _connect
    entries = socket.getaddrinfo(...)
socket.gaierror: [Errno -2] Name or service not known
  ...
kombu.exceptions.OperationalError: [Errno -2] Name or service not known
```

The literal string `$(REDIS_URL)` reaches Celery's broker URL parser, which treats it as a hostname. AMQP/kombu calls `socket.getaddrinfo('$(REDIS_URL)', ...)` → DNS NXDOMAIN.

## Diagnostic Test

```bash
# Reproduce the probe's exact behavior (no shell expansion):
kubectl exec <pod> -n <ns> -- poetry run celery -b '$(REDIS_URL)' inspect ping
# → socket.gaierror: [Errno -2] Name or service not known

# With shell expansion (should work or show the REAL Redis issue):
kubectl exec <pod> -n <ns> -- sh -c 'poetry run celery -b $REDIS_URL inspect ping'
# → Error: No nodes replied within time constraint (REAL issue: inspect ping broadcast issue)
# OR → success
```

## The Masking Effect

With `timeoutSeconds: 1`, the probe process (poetry → python → celery startup → DNS attempt) exceeds 1s and is killed by k8s BEFORE the traceback is emitted. Events show only:

```
Liveness probe failed: command timed out
```

Increasing `timeoutSeconds` to 10s reveals the true error. The probe was always broken — the short timeout just hid the cause.

## Real Case: clinical-language-models (Aug 2026)

- **Pod:** `celery-*-*` in namespace `clinical-llm`
- **Probe:** `poetry run celery -b $(REDIS_URL) inspect ping`
- **642 restarts in 2 days** — every ~4.5 min
- **Timeout=1s** → events showed only "command timed out"
- **Timeout=10s** → events showed `socket.gaierror` traceback
- **Root cause:** `exec.command` doesn't expand `$(REDIS_URL)`. Celery received the literal string.
- **Why it worked before:** GKE node upgrade from older containerd to `v1.35.6-gke.1250000` + containerd `2.1.7`. Older containerd ran exec probes through `/bin/sh -c` (expanding variables); the new version exec's the command array directly.
- **Detection:** Node age (2d12h) matched pod start time (Aug 1). ReplicaSet history showed no probe config changes between stable (55d old) and problematic (6d old) deployments — confirming infrastructure change, not config change.
- **Fix:** Wrap in `/bin/sh -c 'poetry run celery -b $REDIS_URL inspect ping'`
