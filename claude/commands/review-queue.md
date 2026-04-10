Liste todos os PRs abertos na organização GenialCare onde você é revisor e ainda não aprovou.

## 1. Buscar PRs pendentes de review

Execute os três comandos abaixo para cobrir todas as formas de ser adicionado como revisor:

```bash
# Pedido diretamente a você
gh search prs --review-requested=@me --state=open --owner=GenialCare --json number,title,url,repository,author,isDraft --limit 100

# Pedido ao time capacidade-clinica
gh search prs --review-requested=GenialCare/capacidade-clinica --state=open --owner=GenialCare --json number,title,url,repository,author,isDraft --limit 100

# Pedido ao time genial-devs
gh search prs --review-requested=GenialCare/genial-devs --state=open --owner=GenialCare --json number,title,url,repository,author,isDraft --limit 100
```

Combine as três listas removendo duplicatas (mesmo número + mesmo repositório).

## 2. Filtrar PRs ignorados

Descarte imediatamente os PRs que se enquadrem em qualquer uma das regras abaixo:

- `isDraft == true`
- `author.login == "dependabot[bot]"` — bumps automáticos do Dependabot são sempre ignorados
- `author.login == regishideki` — não revisar PRs próprios
- Repositório `GenialCare/operational-data-looker` — PRs de teste/infraestrutura de dados, não relevantes para review

## 3. Filtrar PRs já aprovados por você

Para cada PR da lista combinada, busque as reviews:

```bash
gh pr view <number> --repo <owner/repo> --json reviews
```

**Descarte** os PRs onde já existe uma review com `author.login == "regishideki"` e `state == "APPROVED"`.

## 3. Para cada PR restante, coletar dados

```bash
# Detalhes gerais e reviews
gh pr view <number> --repo <owner/repo> --json title,url,body,author,reviews,reviewRequests,createdAt

# Comentários de review (threads de código)
gh api repos/<owner>/<repo>/pulls/<number>/comments --jq '[.[] | {id,body,user:.user.login,path,resolved:.original_position,created_at}]'

# Comentários gerais (conversation)
gh api repos/<owner>/<repo>/issues/<number>/comments --jq '[.[] | {id,body,user:.user.login,created_at}]'
```

## 4. Salvar fila em arquivo temporário

Após montar a lista final (já filtrada e ordenada), salve em `/tmp/claude-review-queue.json` no seguinte formato:

```json
[
  { "index": 1, "repo": "GenialCare/core", "number": 123 },
  { "index": 2, "repo": "GenialCare/clinical-panel", "number": 456 }
]
```

Use o índice na ordem de apresentação (prioridade definida na seção 6).

## 5. Apresentar o resumo

Para cada PR, apresente no seguinte formato (use o índice como prefixo):

---

**#1 — [Título do PR](url)** — `owner/repo#número`
- **Autor**: login do autor
- **Aberto há**: X dias
- **Aprovações**: lista de quem já aprovou (ou "Nenhuma aprovação ainda")
- **Meu status**: Aguardando minha review / Mudanças solicitadas por mim
- **Conversas comigo**: se há threads/comentários onde fui mencionado (@regishideki) ou onde comentei — indicar se estão aguardando resposta minha ou já respondidas
- **Outras conversas abertas**: threads relevantes de outros revisores que indicam pontos de atenção importantes
- **Resumo**: 1-2 linhas sobre o que o PR faz (baseado no título + body)

---

## 6. Ordenação

Apresente os PRs na seguinte ordem de prioridade:
1. PRs onde já há aprovações suficientes e só falta a minha (mais urgente)
2. PRs onde há conversas comigo ainda não respondidas
3. PRs onde há discussões ativas de outros revisores (indicam pontos polêmicos)
4. Demais PRs

Ao final, mostre um contador: **X PRs pendentes de review**.

E uma dica de uso:
> Para revisar um PR em profundidade: `/review-pr <índice>` (ex: `/review-pr 2`)
