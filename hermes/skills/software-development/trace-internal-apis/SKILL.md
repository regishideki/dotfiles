---
name: trace-internal-apis
description: Trace internal service signatures before calling them.
---

# trace-internal-apis

Internal services in this monolith (facades under `app/public/`, infra adapters
under `app/infra/`, use case steps) frequently have:

- Non-obvious keyword argument names (`json_schema_name` not `schema`, `key_type`
  not `type`, `resource_id` not `id`).
- Closed sets of accepted string values (schema names, model types, statuses)
  that are NOT documented anywhere except in call sites and enum definitions.
- Defaults supplied by facades that hide the real constructor of the infra class.

Guessing these from memory produces code that looks right but fails at runtime
with `ArgumentError` or silent wrong behavior. Always trace before writing.

## When to load this skill

- You are writing a snippet, use case, job, or rake task that calls an internal
  service you did not just read in this session.
- The user names an internal service ("the clinical-llm thing", "the text to json
  service") without giving you the method signature.
- A method takes a string argument whose valid values are not obvious from the
  name alone.

## Procedure

1. **Find the class definition.** `search_files` for `class <Name>` or
   `module <Name>` (target=content). Read the file — get the exact method name,
   keyword args, and defaults.

   If the user only named a facade (e.g. `ClinicalLlmFacade`), read the facade
   first: it often constructs the real infra class (`ClinicalLlm::TextToJsonSchema.new`)
   and exposes it via a method (`text_to_json_schema_service`). Follow that to
   the infra class to get the real signature.

2. **Enumerate accepted string values.** If a parameter looks enum-like
   (`json_schema_name:`, `model_type:`, `status:`, `topic_id:`), do NOT invent a
   value. Search the codebase for all call sites:

   ```
   search_files pattern="json_schema_name:" target=content
   ```

   Collect every distinct value. Prefer values from production code
   (`app/concepts/`, `app/infra/`) over values that only appear in `spec/`
   fixtures — spec-only values are often throwaway strings chosen arbitrarily.

3. **Cross-check enum definitions.** For typed enums (e.g. `model_type:`), find
   the enum class (`Enum::ClinicalLlm::ModelTypes`) and use its constants
   (`::Enum::ClinicalLlm::ModelTypes::GEMINI_2_5_FLASH_LITE`) rather than raw
   strings, matching how production code calls it.

4. **Present options when ambiguous.** If more than one valid value exists and
   the user's intent doesn't make the choice obvious, list the options and let
   the user pick. Do not silently choose. Example: "for anotação, the relevant
   schemas are `INTERVENTION_NOTE`, `CHILD_PROGRESSION_NOTE` — which one?"

5. **Write the call matching production style.** Mirror how the nearest
   production call site invokes the service — same arg order, same constant
   form (e.g. `::Enum::...` vs bare string), same facade vs direct class
   instantiation. Consistency with neighbours matters more than brevity.

## Pitfalls

- **Don't trust the facade alone.** A facade method like
  `text_to_json_schema_service` returns `ClinicalLlm::TextToJsonSchema.new` —
  the facade tells you nothing about the method's args. Always read the infra
  class it returns.
- **Don't reuse spec fixture values.** Specs sometimes pass arbitrary strings
  (`"ABA_NOTE"`) that are not real production schemas. Filter call-site results
  to `app/` paths.
- **Don't conflate similar param names.** `key:` vs `key_type:` vs `resource_id:`
  serve different purposes (correlation key vs entity type vs event routing).
  Read the method body to see how each is used if unsure.
- **Don't skip the enum constant.** If production code passes
  `::Enum::ClinicalLlm::ModelTypes::GEMINI_2_5_FLASH_LITE`, pass the same
  constant — not the string `"GEMINI_2_5_FLASH_LITE"`. The service may validate
  with `.include?` against the enum's `.all` list.
