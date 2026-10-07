#!/usr/bin/env python3
"""Verify PostgreSQL partial-unique-index BLOCKING + visibility behavior.

Why this exists: a past investigation (2026-09, "tela branca no formulário de
conclusão de sessão") incorrectly concluded that a race on a partial unique
index (`WHERE status = 'started'`) caused the "loser"'s `rescue RecordNotUnique
-> find_by(...)` to return nil (missing registry). This script empirically
disproves that: PostgreSQL's *speculative insertion* makes the loser's INSERT
BLOCK on the winner's uncommitted row, so the loser does not raise
RecordNotUnique until the winner COMMITS — by which point the winner's row is
committed and visible, so `find_by` returns it and the loser REUSES it.

Run before concluding a "race condition" is the root cause of a missing-row /
NULL-FK data-integrity bug on a partial unique index.

Usage: `python3 verify_unique_index_blocking.py [db=core_test] [container=core-db-1] [user=root]`

Expected output:
    A: A_COMMITTED
    B: ERROR: duplicate key value violates unique constraint ...
    B_visible_count: 1          # <-- the loser SEES the winner's committed row
    elapsed_s ~= 3.2            # <-- proves B BLOCKED on A (not immediate fail)

If `B_visible_count` is 1, the "loser finds nil" theory is wrong.
"""
import subprocess, sys, threading, time, uuid

DB = sys.argv[1] if len(sys.argv) > 1 else "core_test"
CONTAINER = sys.argv[2] if len(sys.argv) > 2 else "core-db-1"
USER = sys.argv[3] if len(sys.argv) > 3 else "root"


def psql(sql):
    return subprocess.run(
        ["docker", "exec", "-i", CONTAINER, "psql", "-U", USER, "-d", DB, "-t", "-A", "-c", sql],
        capture_output=True, text=True,
    )


case_id = str(uuid.uuid4())
psql("CREATE TABLE IF NOT EXISTS race_test (id uuid DEFAULT gen_random_uuid(), status text, case_id uuid);")
psql("DROP INDEX IF EXISTS race_test_started;")
psql("CREATE UNIQUE INDEX race_test_started ON race_test (case_id) WHERE status = 'started';")
psql("TRUNCATE race_test;")

results = {}


def conn_a():
    r = psql(
        f"BEGIN; INSERT INTO race_test (status, case_id) VALUES ('started', '{case_id}'); "
        f"SELECT pg_sleep(3); COMMIT; SELECT 'A_COMMITTED' AS marker;"
    )
    results["A"] = (r.stdout or r.stderr).strip()


def conn_b():
    time.sleep(0.5)  # let A insert first, so B must block
    r = psql(
        f"BEGIN; INSERT INTO race_test (status, case_id) VALUES ('started', '{case_id}'); "
        f"COMMIT; SELECT 'B_COMMITTED' AS marker;"
    )
    results["B"] = (r.stdout or r.stderr).strip()
    r2 = psql(f"SELECT count(*) FROM race_test WHERE case_id = '{case_id}' AND status = 'started';")
    results["B_visible_count"] = (r2.stdout or r2.stderr).strip()


ta = threading.Thread(target=conn_a)
tb = threading.Thread(target=conn_b)
t0 = time.time()
ta.start(); tb.start()
ta.join(); tb.join()
elapsed = time.time() - t0

print("=== RESULTS ===")
for k in ("A", "B", "B_visible_count"):
    print(f"{k}: {results.get(k)}")
print(f"elapsed_s={elapsed:.1f} (if ~3s, B BLOCKED on A, confirming speculative insertion)")
psql("DROP TABLE IF EXISTS race_test;")
