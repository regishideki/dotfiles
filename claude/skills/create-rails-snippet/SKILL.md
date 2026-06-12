---
name: create-rails-snippet
description: >
  Creates or updates a Rails console snippet in custom_gitignore/snippets/.
  Use whenever the user asks to create a snippet, add a script for the Rails console,
  save a query for later use, or register a command to run in `rails c`. Also use when
  the user describes a debug/inspection/data-fix task and wants it saved as a reusable
  snippet. Automatically picks the right subfolder, reads existing snippets for style,
  and writes the file.
---

# create-rails-snippet

Snippets are Ruby files intended to be copy-pasted or `load`ed into `rails console`.
They live in `custom_gitignore/snippets/` (gitignored) and are organized by domain.

## Step 1 — Discover the structure

List `custom_gitignore/snippets/` to see the existing subfolders and top-level files.

## Step 2 — Choose the right location

Match the user's intent to the closest existing subfolder:

| Subfolder | Use for |
|---|---|
| `assessments/` | Speech therapy, OT, vineland, or any assessment registry/sub-assessment |
| `sessions/` | General sessions, checkin/checkout, scheduling, session queries |
| `clinical_cases/` | ClinicalCase, disciplines, agreements, workloads |
| `people/` | Clinicians, caregivers, collaborators, children |
| `pei_track/` | PEI, module progress, library objectives |
| `clinical_guidance/` | Clinical guidance entities |
| `insights/` | Analytics, reports, data queries |
| `integrations/` | External service calls, Pub/Sub, Firestore |
| `audios/` | Audio files, recordings |
| `dev/` | Dev/staging-only utilities, data cleanup, seed helpers |

If a subfolder doesn't exist yet and no existing one is a good match, create it.

For top-level files: `snippets.rb` (general Ruby), `snippets.sh` (shell), `snippets.sql` (SQL).

## Step 3 — Read 1–2 existing snippets from the chosen subfolder for style

This is important: snippets have a consistent, recognizable style. Read before writing.

Key conventions observed across the codebase:

- **First line**: a comment describing the purpose of the file or section (pt-BR or English, match the file's existing language).
- **Tenant setup**: `ActsAsTenant.current_tenant = Tenant.find_genial_tenant` — include this whenever querying tenant-scoped models.
- **Output**: use `puts` for data you want visible in the console. Use `pp` for complex objects.
- **Safe navigation**: use `&.` when a chain might return `nil`.
- **Sections**: a single file can contain multiple independent code blocks, each preceded by a `# comment` header. Blocks are separated by a blank line.
- **No `rails runner` wrapper** — snippets are raw Ruby for the console, not standalone scripts.
- **Use case calls**: call use cases directly when the intent is to mutate data, not via controller-level wrappers.
- **Iterate with `.each` + `puts`** when inspecting multiple records.

## Step 4 — Decide: create a new file or append to an existing one?

- If a file with a closely related topic already exists in the subfolder, **append a new section** to it (with a comment header).
- If no related file exists, or the topic is distinct enough to warrant its own file, **create a new file**.

When appending, read the existing file first and add the new block at the bottom.

## Step 5 — Write the snippet

Follow the style from Step 3. Keep it focused: the snippet should do exactly what the user asked, nothing more.

If the user mentioned specific case numbers, clinician emails, or other concrete identifiers, use them.

After writing, confirm the file path to the user so they know where to find it.
