# Onde mora o loop de recorrência — job no core vs. jornada/segmento no customer.io

Framework de decisão para qualquer notificação **recorrente/condicional** no customer.io (ex.: "lembra toda semana até completar"). O critério central NÃO é custo em dólar (que é baixo em todas as variantes): é **quem guarda o estado**.

## O insight central

Uma **jornada (journey) guarda estado** no customer.io — pessoas ficam "em espera" no meio do wait. Consequência: **mudar a regra não atualiza retroativamente quem já está in-flight**; elas continuam na configuração antiga até saírem (ou você dar `force_exit`). Cada mudança de regra vira uma **operação de migração** (mapear subjects, force_exit, conviver versão antiga+nova).

Um **job no core é stateless** — lê o banco do zero a cada rodada. Mudou a regra (um `where` a mais), vale para todo mundo na próxima execução. Sem migração, sem estado pra reconciliar.

## As três opções

| | A — job no core | B — jornada com loop | C — objetos + segmento |
|---|---|---|---|
| Onde fica o loop | `recurring.yml` + scope Rails | `conditional_wait` + `create_event` re-emit + `restart_mode: rematch` | broadcast recorrente → segmento |
| Estado no customer.io | nenhum (só evento → push) | alto (subjects em espera) | objetos (clinical_case/agreement) |
| Mudar regra (pausa, churn, cuidador principal, cadência) | editar `where`/config → vale já | **migrar subjects** (force_exit) | editar o **segmento** → vale já |
| Parar quando completa | consulta `completed_at IS NULL` | precisa trackear `agreement_completed` no core | agreement object deletado → sai do segmento |
| Churn/pausa | filtro de caso ativo no scope | precisa `agreement_deleted` no churn OU deletar combinado | `clinical_case.on_hold`/`churned_at` → sai do segmento |
| Backfill dos represados | grátis (1ª execução pega tudo) | re-emitir `agreement_created` com `check_idempotency: false` | upsert dos objects |
| Custo incremental | zero | zero | ~$21/mês (2,3k objects: 797 clinical_case + ~1,5k agreement) |
| Sync permanente | nenhum | nenhum (mas precisa tracking de completude/churn) | **alto** (upsert de case/agreement/main_caregiver a cada mudança) |

## Leitura para decidir

- **A (job no core)** vence quando a cadência é **fixa** e a regra é simples ("enquanto incompleto, lembra"). Barata, stateless, debuggável. O contraponto real (argumento do time de comunicação): *qualquer* mudança de público/frequência exige código + deploy — custo de engenharia permanente.
- **B (jornada)** parece mais barata no dia 1 (não escreve job), mas cobra juros em cada mudança futura — o customer.io vira um **segundo banco de estado** que precisa ficar em sincronia com o core (completude, churn, regras). A condição de saída só funciona se o evento de completude for **trackeado no core** (verificar com `track_event` + CDP sources — não há conector Pub/Sub).
- **C (objetos + segmento)** é a resposta a "será que objetos tornam as mudanças mais fáceis?" — **sim**. Elegibilidade (cuidador principal, pausa, churn) vira **condição de segmento re-avaliada a cada envio**: mudar a regra = editar o segmento, sem migrar subjects. É o design "self-serve" mais limpo (o time de comunicação consegue administrar sem deploy). **Mas** paga o preço do **sync permanente** (~2,3k objects a manter atualizados = "segundo banco de estado") + o custo de objects, e o timing (adicionar objects durante o corte de custo gera resistência, mesmo com $ baixo).

## Fato medido (2026-09)

Custo em dólar **não** é o argumento decisivo contra objetos: `clinical_case` + `agreement` como objects ≈ **2.322 objects ≈ ~$21/mês** (overage $0,009/object). O que decide é o **sync permanente** (custo de engenharia) e o **timing** (corte de objects em andamento). A reconciliação produtiva das duas visões: **job no core agora** (barato, stateless) + **construir a camada de dados (clinical_case como object + segmentos de elegibilidade) depois**, quando a poeira do corte assentar e houver outras campanhas para reutilizar.
