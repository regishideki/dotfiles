# Acessando whiteboards do Confluence via API

Whiteboards do Confluence (`type=whiteboard`) não são acessíveis como páginas normais. A API REST (`getConfluencePage`) retorna 404 para whiteboards. O conteúdo visual (sticky notes, shapes, connectors) não é exposto como texto estruturado.

## Workaround

Usar `searchConfluenceUsingCql` com filtro `type=whiteboard`:

```json
{
  "cloudId": "...",
  "cql": "type=whiteboard AND space=\"SPACE_KEY\" AND title~\"termo de busca\"",
  "limit": 10
}
```

O resultado retorna um `excerpt` com o texto indexado pelo search do Confluence — tipicamente o texto dos sticky notes e shapes, truncado.

## Limitações

- O excerpt é parcial e pode vir vazio para whiteboards sem texto indexado
- A ordem/estrutura visual se perde (conectores, posicionamento, agrupamentos)
- Não há como acessar o "body" completo do whiteboard via REST API atual
- Se o excerpt estiver vazio, a única alternativa é pedir ao usuário para descrever o conteúdo

## Exemplo

```json
{
  "cloudId": "1e91fa41-0b59-4d11-9437-d2352fb6a18d",
  "cql": "type=whiteboard AND space=\"PJC\" AND title~\"Fluxo*\"",
  "limit": 10
}
```
