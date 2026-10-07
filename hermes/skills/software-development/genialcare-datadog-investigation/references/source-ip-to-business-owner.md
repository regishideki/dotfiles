# Resolving a source IP → the business owner (who/what is calling)

When you've attributed traffic to a public IP (via the access-log `custom.ip` /
`custom.remote_ip` recipe in the parent SKILL.md) and the user asks "de que empresa é esse
IP?" / "identifica o dono", the answer has two halves with very different reliability:

1. **Network ownership (weak / usually a dead end).** WHOIS + ipinfo/ip-api/ipwhois only ever
   return the cloud provider: `AS16509 Amazon.com, Inc.`, hostname
   `ec2-3-134-176-17.us-east-2.compute.amazonaws.com`, region us-east-2 (Columbus, Ohio). AWS
   does NOT publish which tenant/company rents an EC2 IP. Shodan InternetDB returns
   `{"detail":"No information available"}` when the host exposes nothing (no banner to
   fingerprint). So "what company owns this IP" is answerable at the *cloud-provider* level
   only, never the *operator* level. Say so plainly rather than implying you can look it up.

2. **Business identity (strong, and what actually answers the question).** The source IP is
   only the transport. What identifies the *owner* is the DATA the caller submits — and you can
   read that read-only from the core DB via `rails runner`. Two queries that closed a 2026-09
   case (job creating users via `POST /users.json` from `3.134.176.17`):

   ```bash
   # (a) what tenants is it onboarding into?  Map the Auth0 org_* external_id → tenant name.
   kubectl exec -n core deploy/web -i -- bash -lc "cd /app && bin/rails runner 'Tenant.where(external_id: [\"org_jTwTzOJkZPMDw7kw\",\"org_8P00Mb6wz383IJhK\"]).pluck(:external_id, :name, :id).each{|e,n,i| puts \"#{e}\t#{n}\t#{i}\"}'"

   # (b) what emails does it create?  Group by domain to see personal vs corporate.
   kubectl exec -n core deploy/web -i -- bash -lc "cd /app && bin/rails runner 'User.where(\"created_at > ?\", 24.hours.ago).order(created_at: :desc).limit(50).pluck(:email).each{|e| puts e}'"
   ```

   Result from that case: tenant `org_jTwTzOJkZPMDw7kw` = **genialcare**,
   `org_8P00Mb6wz383IJhK` = **careplus_mindplace**; and the created emails were all personal
   (`gmail.com`, `hotmail.com`, `outlook.com`, `yahoo.com.br`) — no corporate domain. Conclusion:
   an onboarding/import job provisioning END-USERS (therapists/caregivers), not a B2B API
   partner with its own credential. Combined with the intermittent `MalformedTokenError`, the
   picture is a script running on an EC2 with a token variable that's sometimes empty.

## Rails runner pitfalls (from this session)

- `group("split_part(email, '@', 2)")` and `order("count(*) desc")` with RAW string args throw
  `ActiveRecord::UnknownAttributeReference: Dangerous query method ... disallow_raw_sql!`
  (Rails 8.1). Wrap them: `group(Arel.sql("split_part(email, '@', 2)"))`,
  `order(Arel.sql("count(*) desc"))`, and in `pluck` use `Arel.sql(...)` too.
- The `bin/rails runner '...'` invokes the `eventconsumer` container by default (not the web
  container) — the output is interleaved with a flood of boot logs (Datadog config, SplitIO,
  enum-deprecation WARNs). Filter with
  `grep -vE "WARN|INFO|DEPRECATION|datadog|Split|Loaded|Starting|Posting|Enum|called from|Configuration|emulate|Defaulted"`.
- `kubectl` SA auth: `gcloud auth activate-service-account --key-file="$HOME/.config/gcloud/regis-automation-sa-key.json"`
  (use `$HOME`, not `~` — the tilde is NOT expanded inside a quoted `--key-file=~...` arg), then
  `rm -f ~/.kube/gke_gcloud_auth_plugin_cache` before the first call. Context name for core is
  `production` (`kubectl config use-context production`); pods are `web-<hash>` in namespace `core`.
