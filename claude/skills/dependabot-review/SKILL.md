# Skill: Dependabot PR Review

Analisa os PRs abertos pelo Dependabot e os categoriza por nível de risco para o projeto.

## Processo

### 1. Listar os PRs do Dependabot

Use o GitHub CLI para buscar os PRs abertos pelo Dependabot:

```bash
gh pr list --author "app/dependabot" --json number,title,url,headRefName
```

### 2. Para cada PR, entender o que mudou

Para cada PR:

1. Identifique o nome da lib, a versão atual e a nova versão pelo título do PR (ex: `Bump rails from 7.1.3 to 7.1.4`)
2. Acesse o repositório da lib no GitHub para buscar o changelog:
   ```bash
   gh api repos/{owner}/{repo}/releases --jq '.[].body' | head -100
   ```
   Ou tente o arquivo CHANGELOG diretamente:
   ```bash
   gh api repos/{owner}/{repo}/contents/CHANGELOG.md --jq '.content' | base64 -d
   ```
3. Se o changelog for vago ou inexistente, compare os commits entre as duas versões:
   ```bash
   gh api "repos/{owner}/{repo}/compare/v{old}...v{new}" --jq '.commits[].commit.message'
   ```

### 3. Analisar o impacto no projeto

Com base no changelog/commits, faça uma busca no projeto para entender o impacto:

- Procure usos da lib no código: `grep -r "nome_da_lib" app/ lib/`
- Verifique se os métodos/APIs que o projeto usa foram alterados
- Considere se a mudança é interna (correção de bug, performance) ou pública (API, comportamento)

### 4. Categorizar o PR

Classifique cada PR em uma das três categorias:

---

#### ✅ Pode mergear sem medo

Critérios:
- Patch version bump (ex: 1.2.3 → 1.2.4)
- Apenas correções de bug sem mudança de API
- Atualização de dependências internas da lib
- Security fix sem breaking changes
- Changelog explícito dizendo que é backwards compatible

---

#### ⚠️ Melhor testar na mão antes

Critérios:
- Minor version bump (ex: 1.2.x → 1.3.0)
- Mudanças de comportamento que o projeto pode estar usando
- Deprecated warnings que o projeto pode estar ativando
- Changelog pouco descritivo ou inexistente
- Lib com uso amplo no projeto

---

#### 🚨 Quase certeza que precisa ajustar o código

Critérios:
- Major version bump (ex: 1.x → 2.0)
- Breaking changes explícitos no changelog
- Remoção de métodos/APIs que o projeto usa
- Mudança de interface que o projeto depende
- Migration guide necessária

---

### 5. Apresentar o resultado

Apresente um resumo organizado por categoria, com:

- Nome da lib e versões (atual → nova)
- Link para o PR
- Justificativa da categoria
- O que mudou (resumo do changelog)
- Se for ⚠️ ou 🚨: o que específicamente no projeto pode ser afetado

**Formato de saída:**

```
## ✅ Pode mergear sem medo

### [nome-da-lib] vX.X.X → vX.X.Y
**PR:** #123 — https://...
**O que mudou:** Correção de bug no parser de datas
**Motivo:** Patch version, sem mudança de API

---

## ⚠️ Melhor testar na mão antes

### [nome-da-lib] vX.X.X → vX.Y.0
**PR:** #124 — https://...
**O que mudou:** Novo comportamento no cache
**Motivo:** Minor bump, o projeto usa cache em app/services/...
**Testar:** Fluxo X e Y que dependem do cache

---

## 🚨 Quase certeza que precisa ajustar o código

### [nome-da-lib] vX.X.X → vY.0.0
**PR:** #125 — https://...
**O que mudou:** API completamente reformulada
**Motivo:** Major bump com breaking changes. O projeto usa o método `foo` que foi removido em app/...
**O que ajustar:** Substituir chamadas de `foo` por `bar` conforme migration guide
```
