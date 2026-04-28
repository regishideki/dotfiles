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
2. Acesse o repositório da lib no GitHub para buscar **todas as releases entre a versão atual e a nova** — não apenas o diff entre as duas pontas. Por exemplo, se o bump é de `2.1.0 → 2.4.0`, leia os changelogs de `2.2.0`, `2.3.0` e `2.4.0` individualmente:
   ```bash
   gh api repos/{owner}/{repo}/releases --jq '.[].body' | head -200
   ```
   Ou tente o arquivo CHANGELOG diretamente:
   ```bash
   gh api repos/{owner}/{repo}/contents/CHANGELOG.md --jq '.content' | base64 -d
   ```
   Filtre pelo intervalo de versões relevante — versões anteriores à atual não interessam.
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

**A categorização deve ser guiada pelo conteúdo real do changelog**, não pelo tipo de versão. Major/minor/patch são apenas sinais de alerta iniciais — o changelog é a fonte de verdade.

Classifique cada PR em uma das três categorias:

---

#### ✅ Pode mergear sem medo

Critérios (baseados no changelog):
- Apenas correções de bug sem mudança de comportamento existente
- Novas features adicionadas sem alterar APIs já existentes
- Atualização de dependências internas da lib
- Security fix sem breaking changes
- Changelog explícito confirmando compatibilidade retroativa
- Nenhuma das mudanças toca APIs/métodos que o projeto usa

> Minor bumps podem cair aqui se o changelog mostrar só adição de features sem alterar comportamento existente.

---

#### ⚠️ Melhor testar na mão antes

Critérios (baseados no changelog):
- Mudanças de comportamento em funcionalidades que o projeto usa
- Deprecated warnings ativados em APIs que o projeto usa
- Changelog vago, incompleto ou inexistente (não dá pra ter certeza)
- Lib com uso muito amplo no projeto (alto risco de impacto indireto)
- Alterações em defaults que podem afetar o projeto

---

#### 🚨 Quase certeza que precisa ajustar o código

Critérios (baseados no changelog):
- Breaking changes explícitos no changelog
- Remoção de métodos/APIs que o projeto usa
- Mudança de interface ou contrato que o projeto depende
- Migration guide necessária
- Major bump com alterações substanciais no comportamento

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
