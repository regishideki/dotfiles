# Multi-tenant "NOT FOUND" 404 diagnosis (GenialCare core)

When a frontend error is a Rails `Couldn't find <Model> with [WHERE "...".tenant_id = $1
AND "...".id = $2]` (404 / code `NOT_FOUND`), the record usually still exists — it lives in a
DIFFERENT tenant than the one the user's request was scoped to. Do NOT conclude "deleted" or
"data loss" until you run the cross-tenant check below.

## Data-model facts

- `User has_many :tenants, through: :tenants_users` (join table `tenants_users`, model
  `TenantsUser`). A user can belong to multiple tenants.
- `Tenant` fields: `name`, `display_name`, `external_id` (Auth0 `org_*` value), `genial?`
  (true when `name == "genialcare"`).
- Known tenant UUIDs (id, not external_id):
  - genialcare          = `6f8da042-2dd1-4872-a613-84d371bde78c`
  - careplus_mindplace  = `a4d02a8c-4c27-41b6-80ac-3401f3964e34`
- Session model: `General::Sessions::Session` (table `general_sessions`) — columns
  `status`, `cancelled_at`, `tenant_id`, `clinical_case_id`. It is NOT soft-deleted (no
  `discarded_at`); a completed session simply keeps `status='completed'` + `cancelled_at=nil`.
- Tenant resolution: `core/app/controllers/concerns/secured.rb`,
  `get_current_tenant_from_user_session` resolves in priority order:
  `org_id` (Auth0 org claim in the session) → `X-TENANT-ID` header → `X-TENANT-NAME` header →
  `params[:tenant_id]` → `params[:tenant_name]`, each mapped to `Tenant.external_id` / `name`.

## Rails runner recipe (read-only)

Write a script and pipe it in — do NOT rely on the terminal tool's captured stdout for large
output; the Split SDK shutdown noise pollutes it. Redirect to a file and `grep` the interesting
lines.

```bash
kubectl exec -i -n core web-<pod> -- bin/rails runner - < /tmp/x.rb 2>/dev/null > /tmp/out.txt
```

Script template:

```ruby
EMAIL     = "user@example.com"
S_ID_404  = "<record that 404'd>"
S_ID_OK   = "<sibling record the user DID access, from RUM @type:view trail>"

def tname(tid)
  (t = Tenant.find_by(id: tid)) ? "#{t.name} (#{tid})" : "UNKNOWN #{tid}"
end

u = User.find_by(email: EMAIL)
puts "tenants: #{u.tenants.map(&:name).inspect}"

ActsAsTenant.without_tenant do
  [S_ID_404, S_ID_OK].each do |sid|
    s = General::Sessions::Session.unscoped.find_by(id: sid)
    if s
      puts "#{sid} => tenant=#{tname(s.tenant_id)} status=#{s.status} case=#{s.clinical_case_id}"
    else
      puts "#{sid} => NOT FOUND anywhere"
    end
  end
end
```

The `S_ID_OK` sibling is the decisive evidence: if the 404'd record is `genialcare` and the
record that *worked* is `careplus_mindplace`, the user was authenticated as `careplus_mindplace`
at the time, and the `WHERE tenant_id = careplus AND id = <genialcare session>` correctly
returned nothing.

## RUM navigation-path reconstruction

- `@type:view @usr.email:<email>` sorted by timestamp = the navigation trail (`view_name` =
  React Router screen path, e.g. `/panel/clinical-cases/?/sessions/?/details`).
- The first view's `referrer` reveals the entry point:
  - Auth0 callback (`/?code=…&state=…`) → the user opened a deep link while logged out
    (external link/bookmark/notification, NOT in-panel navigation).
  - a `/panel/...` URL → in-app navigation.
- Recurring error with the SAME entity id + SAME user across multiple days = a stale saved
  link / home-screen shortcut / recurring notification, not a fresh bug or fresh navigation.

## Conclusion framing

This is correct tenant isolation — the backend behaves as designed; there is no data loss and
no code bug. The fix, if any, is UX: the frontend should tell a multi-tenant user "this record
belongs to another tenant" (or switch org) instead of the generic "Erro ao carregar …" fallback
(e.g. `clinical-panel/src/pages/Sessions/Details/Details.tsx:76`), unless product decides to
implement automatic org switching.
