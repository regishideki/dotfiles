# gcloud / GKE authentication mechanisms (reauth vs ADC vs SA key)

Why some credentials "expire fast" and others don't. This is the single most
common source of "I need you to log in again" friction in GenialCare work.

## The three credential flavors (and what each is good for)

| Flavor | Created by | Client OAuth | Used by | Refresh behaviour |
|---|---|---|---|---|
| `gcloud auth login` | interactive CLI | "Google Cloud SDK" | `gcloud` CLI, `gsutil`, `kubectl`/GKE | access token ~1h; **suffers "reauth"** (see below) |
| ADC | `gcloud auth application-default login` | a `764086051850-*.apps.googleusercontent.com` client | `google.auth` libs (Python `bq`/`google.cloud`, some SDKs) | **silent refresh** — no reauth challenge |
| Service-account key | `gcloud iam service-accounts keys create` | n/a (JWT private key) | anything after `gcloud auth activate-service-account --key-file=...` | **durable** — only expires if the key is rotated/revoked |

## What "Reauthentication failed" actually means

`ERROR: (gcloud...config-helper) There was a problem refreshing your current auth tokens: Reauthentication failed. cannot prompt during non-interactive execution.`

This is **NOT** the ~1h access token just expiring. It is Google's Workspace
**session policy** forcing a password re-auth ("reauth", surfaced in newer
errors as `invalid_rapt`). The legacy `oauth2client` flow used by `gsutil` and
`gcloud` CLI hits a `reauth` challenge it can't satisfy non-interactively.

Key consequence: **`gcloud auth login` expires fast on GenialCare accounts**
because of this session policy, not because the token lifetime is short. The
fix for "don't make me log in every time" is almost always a **service-account
key**, not re-running `gcloud auth login`.

## kubectl / GKE does NOT use ADC

`kubectl` on a GKE context authenticates via the `gke-gcloud-auth-plugin`
(see `kubectl config view --minify` → `users[].user.exec.command`), which calls
`gcloud config config-helper` → which reads the `gcloud auth login` token. So:

- ADC fixing `gsutil`/BQ does **nothing** for `kubectl`.
- A service-account key activated via `gcloud auth activate-service-account`
  **does** fix `kubectl` (the plugin reads the active account, SA or not) —
  BUT a stale cached token overrides the active account until cleared (see
  "token cache trap" below).

So the ADC trick that solved a deploy-via-Python problem is a *different
mechanism* from kubectl auth — don't conflate them.

## The gke-gcloud-auth-plugin token cache trap

After `gcloud auth activate-service-account --key-file=...` followed by
`gcloud config set account <human>`, `kubectl` can STILL act as the OLD
identity. Root cause: the plugin caches the access token in
`~/.kube/gke_gcloud_auth_plugin_cache` (fields `current_context`,
`access_token`, `token_expiry`); the cache wins over the active account.

Diagnostic signature that nails it (took a long back-and-forth to find):
- `gcloud config config-helper --format=json` returns the NEW account's token,
  but `kubectl get pods ...` reports `Forbidden ... User "OLD-SA@..."` — the
  plugin and config-helper disagree.
- Token prefix differs: `ya29.c.…` = service-account (JWT) token, `ya29.a0…` =
  user (OAuth) token. Seeing `ya29.c.` when you expected the user account means
  a stale SA token is being served from cache.

Fix: `rm ~/.kube/gke_gcloud_auth_plugin_cache` (safe — it's just a token cache,
regenerated on the next kubectl call). Then re-run the plugin and confirm the
prefix flipped back to `ya29.a0`.

To confirm whose token any credential source is emitting, decode it:
`curl -s "https://oauth2.googleapis.com/tokeninfo?access_token=$T"` → `.email`.

Related: `gcloud auth revoke <sa-email>` does NOT kill an already-issued SA
token (warns "service account tokens cannot be revoked") — clear the cache
file, don't rely on revoke. The plugin is a Go binary that resolves
credentials via the ADC library / `config-helper`, not the plain `gcloud`
PATH, so a `gcloud` PATH wrapper won't intercept it (useful to know if you
try to trace what it executes).

## Two independent permission layers (a SA has no single "permission")

A service account reaches two disjoint things:

1. **GCP IAM** (on the project) — BQ, GCS, GKE, Cloud SQL, etc. Granted via
   `roles/bigquery.*`, `roles/storage.*`, `roles/container.*`, …
2. **Kubernetes RBAC** (inside the cluster) — what `kubectl` can do. Granted via
   `Role`/`RoleBinding` or `ClusterRole`/`ClusterRoleBinding`.

Being able to `gcloud` something does not imply `kubectl` access and vice versa.
For read-only monitoring access you typically need BOTH:
`roles/container.viewer` (IAM) AND a `view`/custom ClusterRoleBinding (RBAC).

**`kubectl exec` is a SEPARATE grant — `view` does NOT cover it.** A SA with
`container.viewer` + a `view` ClusterRoleBinding can `get`/`list` pods but will
still hit `Forbidden ... cannot create resource "pods/exec"` on `kubectl exec`,
because exec needs the `pods/exec` subresource with verb `create`. This bites
exactly when you try `psql`/`pg_dump`/Solid Queue inspection inside a pod. To
allow it (namespaced, least privilege):

```bash
kubectl create role <sa>-exec -n <ns> --verb=create --resource=pods/exec
kubectl create rolebinding <sa>-exec -n <ns> --role=<sa>-exec \
  --user=<sa>@<proj>.iam.gserviceaccount.com
```

It is a `create`-shaped verb on a sensitive capability (arbitrary command
execution in the container) — scope it to the namespace and treat in-pod
commands as read-only by default (confirm with the user before anything
mutating).

## Diagnostic signatures

- `Reauthentication failed` → the active user credential hit reauth. Re-login
  (temporary) or switch to a SA key (permanent).
- `Forbidden: ... cannot list resource "pods" ... requires ["container.pods.list"]`
  → you authenticated fine (token accepted) but lack IAM role and/or RBAC. This
  is a **permission** problem, not an auth problem — don't re-login.
- `iam.serviceAccounts.create denied on resource .../projects/<p>` → the active
  credential has no IAM grant on that project; you cannot create/grant SAs
  cross-project with it.
- Bucket owner project (to grant `storage.objectViewer` on the RIGHT project):
  a bucket's name is NOT its project. Resolve via
  `curl -s -H "Authorization: Bearer $(gcloud auth print-access-token)" "https://storage.googleapis.com/storage/v1/b/<bucket>?fields=projectNumber"`
  then map the `projectNumber` to a `projectId` (the number appears in that
  project's IAM service-account suffixes, e.g. `...@<proj>.iam.gserviceaccount.com`).

## The SA-creation catch-22 (why you still need one manual login)

To create a SA and grant IAM on project P you need a credential with
`iam.serviceAccounts.create` + `resourcemanager.projects.setIamPolicy` on P.
A service account from a *different* project (e.g. `core-development-hy78`) has
no grant on P and will get `Permission denied`. So when the human's own token
has also expired, there is no non-interactive path left: they must run
`gcloud auth login` ONCE, after which the durable SA key can be created and the
problem is gone for good.

## Recommended durable setup (read-only automation)

Create ONE service account (e.g. `hermes-agent` in the target project) with
read-only scope, never `roles/owner`/`roles/editor`/`roles/iam.*` (those let it
create more SAs = privilege escalation). Typical bundle:

```bash
gcloud iam service-accounts create hermes-agent \
  --project=<target> --display-name="hermes automation (read-only)"

gcloud projects add-iam-policy-binding <target> \
  --member="serviceAccount:hermes-agent@<target>.iam.gserviceaccount.com" \
  --role="roles/container.viewer"            # GKE read

gcloud iam service-accounts keys create ~/hermes-agent-sa-key.json \
  --iam-account="hermes-agent@<target>.iam.gserviceaccount.com"

# RBAC (run once with a credential that already has cluster access):
kubectl create clusterrolebinding hermes-agent-view \
  --clusterrole=view --user=hermes-agent@<target>.iam.gserviceaccount.com
```

Then switch per-session without touching the human account:

```bash
gcloud auth activate-service-account --key-file="$HOME/hermes-agent-sa-key.json"
# ... work ...
gcloud config set account regis@genialcare.com.br   # back to human account
```

**Tilde pitfall:** `--key-file=~/path` does NOT expand `~` — tilde expands only at
the START of a word, not after `=`. Use `$HOME`. A silent failure here (activate
errors, and if you `>/dev/null` it you won't see it) makes it *look* like the SA
became active when the human account is still in force — your subsequent
"successful" kubectl/bq calls were actually running as the human. Always verify
after activating: `gcloud config get-value account`.

Add BQ/GCS roles only as actually needed (`bigquery.jobUser` + dataset
`dataViewer`, `storage.objectViewer`), not upfront.
