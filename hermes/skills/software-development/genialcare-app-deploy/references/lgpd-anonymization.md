# Anonimização LGPD antes de publicar painel clínico

Ao publicar um painel/dashboard clínico (mesmo "interno" via Auth0), NÃO exponha PII de paciente.
O risco mais fácil de errar: **nomes de paciente embutidos em textos livres** — observações,
hipóteses, objetivos que a terapeuta escreveu — não só em campos óbvios de "nome".

## Técnica

1. **Nome de paciente em texto livre** → substituir por "a criança"/"paciente". Heurística por lista
   de nomes próprios comuns + regex de artigo/preposição: "O João", "da Maria", "do Pedro" → "a criança".
   Processar nomes compostos primeiro (`sorted(..., key=len, reverse=True)`). Nomes raros escapam —
   manter a lista fácil de estender. A gramática fica levemente imperfeita ("do cuidador a criança");
   o objetivo é remover o identificador, não gramática perfeita.

2. **Nome de profissional (terapeuta/OG)** → reduzir a "Primeiro Nome + inicial"
   ("Sabrina Basquera" → "Sabrina B."). **NÃO usar email**: é PII *mais* sensível (identificador único
   de contato, alvo de phishing) e não anonimiza — só troca um identificador por outro pior.

3. **Número de caso** → manter. É como a equipe reconhece o caso; número sem nome é
   pseudo-anonimização razoável para público interno.

4. Publicar SÓ o HTML anonimizado. Os CSVs/JSONs locais (com PII completa) ficam fora do versionamento
   e fora do deploy.

## Onde anonimizar

No **gerador** (que monta o `data_json` do HTML), NÃO nos CSVs de entrada. Atenção a **múltiplas
fontes** do mesmo campo: se o nome do profissional vem de mais de uma fonte (ex. a fonte principal
`A` e um JSON auxiliar tipo `_casa_og.json`), anonimizar em TODAS — senão o agrupamento quebra: o
nome completo vira uma chave/OG separada do "Primeiro Nome + inicial", duplicando o agrupamento.

## Verificação pós-geração

Extrair o `data_json` do HTML e conferir que (a) nenhum nome de paciente aparece, (b) as chaves de
agrupamento (OG) são só "Primeiro Nome + inicial" e não duplicam, (c) a contagem de casos não mudou.

## O que versionar no git (dados vs código)

Separar o que merece ir pro git do que fica fora (dado de painel costuma ter os dois):
- **Vai pro git**: código + dados **anonimizados e leves** + o **histórico de tendência** (snapshot
  por rodada, só métricas agregadas por OG — pequeno, SEM PII). O histórico é o que alimenta os
  indicadores "▲ +N vs. última" e o sparkline de tendência; sem ele a tela mostra "sem histórico
  ainda" e a primeira rodada fica sem seta. Se perder o histórico, as tendências somem até acumular
  de novo.
- **NÃO vai pro git**: os CSVs/JSONs **brutos com PII** (nome de paciente + nome completo) e os
  dados **grandes regeneráveis** (checagens, avaliações — a fonte da verdade é o BigQuery, não o
  snapshot local). Commitar 10s de MB de dados por rodada estoura o repo (git não é storage de dado).

Quando versionar: só após rodada bem-sucedida; nunca commitar dado incompleto. Se a pessoa que
opera não é dev, escreva a regra "o que/quando salvar" na documentação (não assuma que ela sabe).
