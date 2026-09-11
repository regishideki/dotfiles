# Celery heartbeat-file liveness probe (avoids reimport + broker round-trip)

Full worked example from a production fix where `celery -A app.tasks inspect ping` cost
28-30s per probe call (heavy app import chain — Vertex AI SDK, langchain, sqlalchemy)
and blew a 10s `timeoutSeconds`, causing a restart loop even though the worker was healthy.

This is the HARDENED version, after validating the initial implementation against Celery's own
docs and the community `celery-live` package (see "Prior art" section below) — it adds `requires`
and `stop()` cleanup that the first version (which passed its own unit tests fine) was missing.

## 1. Bootstep module (`app/tasks/heartbeat.py`)

```python
"""Lightweight liveness heartbeat for the Celery worker.

Instead of relying on `celery inspect ping` (which spawns a brand-new Python
process that re-imports the whole app on every probe tick), the worker itself
writes its current timestamp to a file on a fixed interval via a Celery
bootstep. The k8s liveness probe just checks the file's mtime with a plain
shell command — near-instant, no risk of false positive while the worker is
busy with long-running tasks.

This mirrors the pattern documented by Celery itself for using `worker.timer`
(see the `DeadlockDetection` bootstep example at
https://docs.celeryq.dev/en/stable/userguide/extending.html#timer) and the
same approach used by the community `celery-live` package
(https://github.com/MrWeeble/celery-live), which independently arrived at the
same file-heartbeat + bootstep design.
"""
import os
import time

from celery import bootsteps

HEARTBEAT_FILE = os.getenv("CELERY_HEARTBEAT_FILE", "/tmp/celery_heartbeat")
HEARTBEAT_INTERVAL_SECONDS = int(os.getenv("CELERY_HEARTBEAT_INTERVAL_SECONDS", "15"))


class HeartbeatStep(bootsteps.StartStopStep):
    """Writes HEARTBEAT_FILE with the current timestamp every
    HEARTBEAT_INTERVAL_SECONDS, using Celery's own timer so it keeps running
    even while the worker is busy processing tasks.

    Requires the Timer bootstep explicitly (per Celery's documented pattern
    for using `worker.timer`), so the worker guarantees `worker.timer` is
    initialized before our `start` runs.

    Removes HEARTBEAT_FILE on `stop`, which the Worker blueprint calls on
    shutdown (see Celery's Extending/Bootsteps docs): this way, if the
    worker is stopped gracefully (e.g. SIGTERM handled), the liveness probe
    fails immediately instead of waiting for the heartbeat to go stale.
    """

    requires = {'celery.worker.components:Timer'}

    def start(self, parent):
        def write_heartbeat():
            with open(HEARTBEAT_FILE, "w", encoding="utf-8") as heartbeat_file:
                heartbeat_file.write(str(time.time()))

        write_heartbeat()
        parent.timer.call_repeatedly(HEARTBEAT_INTERVAL_SECONDS, write_heartbeat)

    def stop(self, parent):
        if os.path.exists(HEARTBEAT_FILE):
            os.remove(HEARTBEAT_FILE)
```

Note the `start(self, parent)` / `stop(self, parent)` signature — pylint's `arguments-renamed` check
fires if you name the parameter `worker` instead of `parent`, since that's the base class's parameter
name in `celery.bootsteps.StartStopStep`.

## 2. Registration in the Celery app module

```python
from .heartbeat import HeartbeatStep
# ... app = Celery(...) / app.conf.update(...) as usual ...
app.steps['worker'].add(HeartbeatStep)
```

## 3. Kubernetes probe YAML

```yaml
livenessProbe:
  exec:
    command:
    - /bin/sh
    - -c
    - find /tmp/celery_heartbeat -mmin -1 | grep -q .
  initialDelaySeconds: 30
  periodSeconds: 30
  timeoutSeconds: 10
```

(Original `-A app.tasks inspect ping`-based timeouts of 45s/60s/60s could be reverted back to
sane 10s/30s/30s once switched to this probe — it's essentially instant.)

**Pitfall:** `find /tmp/celery_heartbeat -mmin -1` ALONE never fails the probe — `find` exits 0
whether or not it printed anything. You must pipe through `grep -q .` to turn "no output" (stale or
missing file) into a real non-zero exit code. Verify both directions manually:
```bash
touch /tmp/heartbeat && find /tmp/heartbeat -mmin -1 | grep -q .; echo $?          # expect 0 (fresh)
touch -d "2 minutes ago" /tmp/heartbeat && find /tmp/heartbeat -mmin -1 | grep -q .; echo $?  # expect 1 (stale)
```

## 4. Test pattern (mock the worker's timer, don't spin up a real Celery worker)

```python
import time
from unittest.mock import MagicMock

from app.tasks import heartbeat as heartbeat_module
from app.tasks.heartbeat import HEARTBEAT_INTERVAL_SECONDS, HeartbeatStep


def test_heartbeat_step_requires_timer_bootstep():
    # Per Celery's documented pattern for bootsteps that use `worker.timer`,
    # the step must declare this so the Timer bootstep is guaranteed to be
    # initialized before our `start` runs.
    assert HeartbeatStep.requires == {'celery.worker.components:Timer'}


def test_heartbeat_step_writes_file_on_start(tmp_path, monkeypatch):
    heartbeat_file = tmp_path / "celery_heartbeat"
    monkeypatch.setattr(heartbeat_module, "HEARTBEAT_FILE", str(heartbeat_file))

    worker = MagicMock()
    step = HeartbeatStep(worker)

    before = time.time()
    step.start(worker)
    after = time.time()

    assert heartbeat_file.exists()
    written_timestamp = float(heartbeat_file.read_text())
    assert before <= written_timestamp <= after


def test_heartbeat_step_schedules_periodic_write(tmp_path, monkeypatch):
    heartbeat_file = tmp_path / "celery_heartbeat"
    monkeypatch.setattr(heartbeat_module, "HEARTBEAT_FILE", str(heartbeat_file))

    worker = MagicMock()
    step = HeartbeatStep(worker)
    step.start(worker)

    worker.timer.call_repeatedly.assert_called_once()
    interval_arg, callback_arg = worker.timer.call_repeatedly.call_args[0]
    assert interval_arg == HEARTBEAT_INTERVAL_SECONDS

    first_write = heartbeat_file.read_text()
    time.sleep(0.01)
    callback_arg()
    second_write = heartbeat_file.read_text()

    assert float(second_write) >= float(first_write)


def test_heartbeat_step_removes_file_on_stop(tmp_path, monkeypatch):
    heartbeat_file = tmp_path / "celery_heartbeat"
    monkeypatch.setattr(heartbeat_module, "HEARTBEAT_FILE", str(heartbeat_file))

    worker = MagicMock()
    step = HeartbeatStep(worker)
    step.start(worker)
    assert heartbeat_file.exists()

    step.stop(worker)

    assert not heartbeat_file.exists()


def test_heartbeat_step_stop_is_safe_when_file_missing(tmp_path, monkeypatch):
    heartbeat_file = tmp_path / "celery_heartbeat"
    monkeypatch.setattr(heartbeat_module, "HEARTBEAT_FILE", str(heartbeat_file))

    worker = MagicMock()
    step = HeartbeatStep(worker)

    # stop() before start() (file never created) must not raise.
    step.stop(worker)
```

## 5. Live validation recipe (run before trusting the fix)

```bash
# Start the worker, confirm the heartbeat file appears almost immediately —
# even before the worker finishes connecting to the broker:
docker compose run --rm -e ENVIRONMENT=test app sh -c '
  poetry run celery -A app.tasks worker -l INFO -Q high,default,low > /tmp/celery_worker.log 2>&1 &
  CELERY_PID=$!
  sleep 8
  ls -la /tmp/celery_heartbeat; cat /tmp/celery_heartbeat
  find /tmp/celery_heartbeat -mmin -1 | grep -q .; echo "probe_exit=$?"
  kill $CELERY_PID
'

# Confirm the probe correctly FAILS on a stale heartbeat:
touch -d "2 minutes ago" /tmp/celery_heartbeat
find /tmp/celery_heartbeat -mmin -1 | grep -q .; echo "stale_probe_exit=$?"   # expect 1
```

## Why this beats just raising `timeoutSeconds`

Raising the timeout (Pattern 6's quick mitigation) stops the restart loop but leaves two problems
unaddressed, both raised in a real `gemini-code-assist` PR review: (1) CPU/time is still wasted on
every probe tick reimporting the whole app, and (2) if the probe ever does something that waits on
worker state (like `inspect ping`), a worker busy on a long task can look "dead" even though it's
fine — a false positive. The heartbeat-file approach is decoupled from both the import cost and the
task queue, so neither problem exists.

## Prior art — validate against these before trusting a novel bootstep pattern

A direct user question ("is this actually safe? does Celery support this?") after the first version
shipped green tests led to this research pass, which found the two gaps fixed above (`requires=` and
`stop()` cleanup):

1. **Celery's own docs**: https://docs.celeryq.dev/en/stable/userguide/extending.html#timer — the
   `DeadlockDetection` example bootstep is the canonical reference for any bootstep using
   `worker.timer.call_repeatedly`. It declares `requires = {'celery.worker.components:Timer'}`.
2. **github.com/celery/celery/issues/4079** — 8+ year community thread on exactly this problem
   (`celery inspect ping` CPU/latency issues under Kubernetes, false positives under load). Useful
   for confirming you're not the first to hit this, and for citing in a PR description as evidence
   the concern is real and well-documented, not hypothetical.
3. **github.com/MrWeeble/celery-live** (based on
   https://medium.com/ambient-innovation/health-checks-for-celery-in-kubernetes-cf3274a3e106) —
   community package implementing the identical file-heartbeat + bootstep pattern, confirms both the
   overall design and specifically the `stop()`-removes-file behavior.

## Task-loss hardening: `task_acks_late` + `task_reject_on_worker_lost`

Fixing the probe (heartbeat file or otherwise) stops the RESTART LOOP, but it does not undo damage
already done by past restarts, and does not prevent task loss on any FUTURE crash (OOM, node eviction,
`kubectl delete pod`, etc.) — those are a separate, orthogonal risk that also needs fixing.

**Why tasks get silently lost on worker crash, by default:** Celery's Redis transport, without extra
config, acks (removes) a task message from the broker as soon as it's DELIVERED to a worker process —
not after the task finishes. If that worker process is killed mid-task (which is exactly what a failing
liveness probe does, repeatedly, during a restart loop), the message is already gone from Redis. The
task never completes, never runs its result callback / never publishes whatever "done" event a
downstream consumer is waiting on, and there is no automatic retry or redelivery — it just vanishes.

This is provable independently of application logs by tracing what a downstream consumer expected: e.g.
a status-tracking table (`AsyncRequest`, job-status, outbox pattern) in another service that this
worker updates asynchronously via a completion event. Rows created during the outage window get stuck
forever in "pending" — not because anything is currently broken, but because the originating task was
lost in a past crash and nothing in the system today has any way to know it needs to be retried. See the
SKILL.md's "downstream system" pitfall section for how to disambiguate this residue from an active bug.

**Fix — two flags, both required (one alone is not enough):**

```python
app.conf.update(
    # ... existing config (queues, routes, broker_transport_options, etc.) ...
    worker_prefetch_multiplier=1,
    # Without these two, Celery acks a task message as soon as it's delivered to the
    # worker (before execution). If the worker process is killed mid-task (OOM, SIGKILL
    # from a failed liveness probe, node eviction), the message is already gone from Redis
    # and the task is silently lost - no retry, no error, nothing.
    # task_acks_late moves the ack to after task completion; task_reject_on_worker_lost
    # additionally re-queues the message (instead of dropping it) if the worker process
    # executing it is killed/lost. Per Celery's own docs, task_reject_on_worker_lost is
    # required IN ADDITION to task_acks_late - acks_late alone still acks a task whose
    # worker process abruptly dies.
    # Tradeoff: a task that crashes the worker itself (e.g. segfault) can now be
    # redelivered and re-executed - only safe if all tasks are already idempotent/retry-safe.
    task_acks_late=True,
    task_reject_on_worker_lost=True,
)
```

Source: https://docs.celeryq.dev/en/stable/userguide/configuration.html — `task_acks_late` ("Default:
Disabled... task messages will be acknowledged after the task has been executed, not right before, the
default behavior") and `task_reject_on_worker_lost` ("Default: Disabled. Even if task_acks_late is
enabled, the worker will acknowledge tasks when the worker process executing them abruptly exits...
Setting this to true allows the message to be re-queued instead").

**Regression test — assert the built Celery app actually has both flags set** (don't just eyeball the
config diff; a typo or merge conflict can silently drop one):

```python
def test_celery_acks_late_and_rejects_on_worker_lost(monkeypatch):
    set_required_settings_env(monkeypatch)  # whatever your app needs to construct Settings()
    monkeypatch.setenv("ENVIRONMENT", "test")
    sys.modules.pop("app.tasks.celery", None)
    celery_module = importlib.import_module("app.tasks.celery")
    assert celery_module.app.conf.task_acks_late is True
    assert celery_module.app.conf.task_reject_on_worker_lost is True
```

**Only safe to ship when:** every task already has bounded retry (`autoretry_for`, `max_retries`) and is
tolerant of re-execution (idempotent, or side-effect-safe on retry) — otherwise a task that crashes its
own worker mid-execution could double-apply a non-idempotent side effect on redelivery. Audit existing
`@app.task(...)` decorators for `autoretry_for=(Exception,)` + `max_retries=N` before enabling this
project-wide; if any task lacks it, add it first or scope the flags per-task instead of globally.

**Pitfall — don't claim `autoretry_for`/`max_retries` bounds the poison-pill case, they don't.** A first-draft
code comment on this diff said the redelivery risk was "safe because tasks are already guarded by
autoretry_for/max_retries" — a `gemini-code-assist` PR review caught this as factually wrong and it's worth
getting right: `max_retries`/`autoretry_for`'s retry counter (`self.request.retries`) is **in-process state**,
incremented only when the task raises/catches an exception while the worker is still alive to run that
code path. If the worker process itself dies abruptly (segfault, OOM-killed mid-task, SIGKILL) *before*
any exception is raised or handled, that counter never increments. `task_reject_on_worker_lost` then
redelivers the message as a **brand-new delivery with the retry counter reset to zero** — there is no
upper bound on how many times this can repeat for a task that reliably kills whatever worker picks it up
("poison pill" → infinite redelivery loop). `max_retries` only bounds retries from *ordinary in-task
exceptions*; it does nothing for the worker-crash-during-execution case these two flags target.

Correct framing for the PR/code comment: the risk is accepted because *no task in this codebase is known
to crash its own worker process* (they raise normal Python exceptions, which retry via `autoretry_for` as
usual, unaffected by these two settings) — the crash scenario these flags actually defend against is an
**external** kill (liveness probe failure, OOM-killer, node eviction) hitting an arbitrary in-flight task,
which is not expected to recur for the same message. If a task's own logic *is* suspected of ever crashing
the interpreter (native extension segfault, unbounded memory growth), don't rely on this pairing alone —
add an explicit external circuit breaker (e.g. a redelivery/retry-count header check via `request.delivery_info`
or a dead-letter queue) for that specific task.
