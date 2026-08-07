# Wiki.js Navigation GraphQL API

Schema details discovered via GraphQL introspection on Wiki.js 2.x (ghcr.io/requarks/wiki:2).

## Authentication

```graphql
mutation {
  authentication {
    login(username: "admin@wiki.local", password: "wiki-local-dev", strategy: "local") {
      jwt
    }
  }
}
```

Use the JWT as `Authorization: Bearer <token>` on subsequent requests.

## Navigation config

Set the navigation mode to `TREE` (custom tree) so `updateTree` takes effect:

```graphql
mutation($mode: NavigationMode!) {
  navigation {
    updateConfig(mode: $mode) {
      responseResult { succeeded message }
    }
  }
}
```

`NavigationMode` is an enum: `TREE` (custom) or `NONE`.

## Navigation tree

```graphql
mutation($tree: [NavigationTreeInput]!) {
  navigation {
    updateTree(tree: $tree) {
      responseResult { succeeded message }
    }
  }
}
```

### NavigationTreeInput

| Field   | Type                          | Required |
|---------|-------------------------------|----------|
| locale  | String                        | yes      |
| items   | [NavigationItemInput]         | yes      |

### NavigationItemInput

| Field            | Type     | Required | Notes |
|------------------|----------|----------|-------|
| id               | String   | yes      | Slash-separated path for hierarchy (e.g. `documentations/adrs/0001-foo`) |
| kind             | String   | yes      | `folder` or `link` |
| label            | String   | no       | Display label |
| icon             | String   | no       | Icon name |
| targetType       | String   | no       | `page` for page links |
| target           | String   | no       | Page path (matches `pages.list` path) |
| visibilityMode   | String   | no       | e.g. `all` |
| visibilityGroups | [Int]    | no       | Group IDs for restricted visibility |

## Key insight: hierarchy is encoded in the `id` field

Wiki.js infers the tree structure from the `/`-separated `id` of each item. You do NOT nest items recursively. Instead, emit a flat list where:

- `documentations` (kind: folder) creates the top-level folder
- `documentations/adrs` (kind: folder) creates a subfolder
- `documentations/adrs/0001-foo` (kind: link, target: `documentations/adrs/0001-foo`) creates a page link inside that subfolder

The order matters: folder entries must appear before their children so Wiki.js can resolve the parent.

## Listing pages

```graphql
query {
  pages {
    list(locale: "pt-br") {
      id
      path
      title
    }
  }
}
```

The `path` field is the unique page identifier and matches the `target` field in navigation items.

## Reproduction recipe

If `.wiki/setup-nav.js` is missing, recreate it with this logic:

1. Login → get JWT
2. `pages.list(locale: "pt-br")` → all pages with `{id, path, title}`
3. Sort pages by path (alphabetical, so folders naturally come first)
4. For each page, emit folder entries for every ancestor path segment not yet seen, then emit the page link itself
5. `navigation.updateConfig(mode: TREE)`
6. `navigation.updateTree(tree: [{locale: "pt-br", items: [...]}])`
