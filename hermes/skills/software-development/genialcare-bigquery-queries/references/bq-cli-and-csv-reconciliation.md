# BQ CLI gotchas + CSV↔system reconciliation (de-para)

## `bq query --format=csv` trunca silenciosamente em 100 linhas

`bq query --format=csv` SEM `--max_rows` trunca a saída em 100 linhas por padrão, **sem
nenhum aviso de truncamento na saída**. Com `ORDER BY`, as linhas cortadas são as do fim do
ordenamento — o que pode esconder exatamente os registros que você procura (ex: um subdomínio
inteiro de objetivos ficou de fora de uma contagem e só apareceu ao subir o limite).

Regra: quando a saída importa para contagem/comparação, passe `--max_rows=500` (ou mais) e
confirme totais com um `select count(*)` isolado. Não confie numa contagem feita em cima de
uma saída truncada sem ter verificado o limite.

## Dataset em location diferente

Nem todos os datasets do projeto `supervision-production-8f1v` estão na mesma location.
`datakernel` (ex: tabela `tenants`) não fica em `us-east1` como `intervention`/`assessment` —
um JOIN cross-dataset pode dar:
`Not found: Dataset supervision-production-8f1v:datakernel was not found in location us-east1`.
Se só precisa dos dados de um tenant, prefira filtrar por `tenant_id` direto (via subquery)
em vez de fazer JOIN com `datakernel.tenants`.

## Reconciliação CSV ↔ sistema (de-para)

Quando o objetivo é casar um CSV/planilha exportado com as estruturas reais do sistema:

- **Corrija a FONTE (planilha), não o CSV derivado.** Se patchear o CSV no repo, a planilha
  de origem continua errada e a próxima exportação traz o erro de volta. Liste as correções
  necessárias e deixe o usuário editar a planilha; depois revise a re-exportação. É o padrão
  que este usuário pede explicitamente.
- **Detecte células malformadas** (itens colados numa linha só, em vez de quebra de linha):
  escaneie cada célula contando ocorrências dos prefixos de item numa mesma linha. `>= 2`
  prefixos na mesma linha = célula malformada. Prefixos típicos de avaliação de Fono:
  `Bandeiras Vermelhas:`, `Avaliação - Imitação:`, `CAA:`, `Comunicação Expressiva:`,
  `Motricidade Orofacial:`.
- **Resíduo de separador**: ao quebrar itens colados, sobra o caractere que os separava
  (`.` ou `;`) grudado no fim do primeiro item. Valide com `item.strip().endswith('.')` /
  `endswith(';')`.
- **Corrija o CSV para casar com o texto EXATO do sistema** — incluindo typos do cadastro,
  ponto final sobrando etc. — porque o match exato do de-para depende disso. Confirme o texto
  real via `bq query` ANTES de editar; não assuma pela leitura anterior (a descrição pode ter
  sido reescrita entre snapshots/migrações).
- **Cheque snapshots antigos antes de concluir "não existe".** Um objetivo "ausente" no
  protocolo atual pode ter existido num protocolo anterior e sido descartado numa migração
  (ex: `producao-fono-objetivos.json` de uma iniciativa de migração). Isso muda a decisão:
  reinserir = reverter remoção, não criar do zero.
