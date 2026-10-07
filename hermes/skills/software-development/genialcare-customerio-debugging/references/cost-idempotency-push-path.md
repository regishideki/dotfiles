# Customer.io — modelo de custo, idempotência e caminho do push (core/mobile)

> Notas consolidadas a partir da investigação da feature "push recorrente de combinados"
> (user story `documentations/user_stories/20260915-push-recorrente-combinados/`), dos docs
> `core/documentations/features/customer-io-session-objects/doc.md`,
> `core/documentations/features/communication-notifications/customer-io.md` e ADR 0013
> (`core/documentations/adrs/0013-usar-customer-io-objects-como-modelo-de-orquestracao-de-notificacoes.md`).

## Modelo de custo (High Watermark) — a regra que governa qualquer feature nova

- O plano inclui **500 objects** grátis; acima disso, overage ~$0,009/object. **People + Objects somam juntos** nesse teto.
- Cobrança por **High Watermark**: vale o **pico de objects que existiram simultaneamente em algum momento do mês**, não o total acumulado nem o saldo no fim do mês.
- **Excluir um object NÃO reduz o custo do mês em que ele foi criado** (só ajuda o mês seguinte). Cancelar rápido dentro do mesmo mês não economiza.
- **Events são baratos e NÃO contam como objects.** Campanhas/journeys disparadas por events não criam objects.
- **Push e in-app são ILIMITADOS em todos os planos** (`customer.io/pricing`): não há cobrança por mensagem de push. Emails ~1M/mês (Essentials); SMS/WhatsApp são por mensagem. Consequência direta: um lembrete recorrente por push (events + campanha) tem **custo incremental ZERO**, independente do volume — o único risco de custo é modelar algo como object.
- O vazamento histórico foi de objects `session` (~23k) criados sem necessidade → fatura de ~$595 (vs ~$150 habituais).

**Regra prática para feature nova:** preferir **events + campanha** sempre que possível; só modelar como object quando há estado/ciclo de vida que o customer.io precisa orquestrar (ADR 0013: ofertas). Um lembrete recorrente "até completar" pode ser feito com events + job no core, SEM objects.

## Primitivos (mastigado)

- **People** — a pessoa (cuidador/terapeuta). Atributos persistentes. Identificada por email (ou `id`).
- **Events** — ações pontuais ("o que aconteceu"). Sem ciclo de vida (não editáveis). Baratos. Disparam campanhas/journeys.
- **Objects** — entidades com ciclo de vida (sessão, oferta). Caros (contam no teto). Upsert/delete via Track API v2.
- **Campaign** — dispara 1 mensagem por gatilho (evento/segmento/data).
- **Journey** — workflow multi-passo (gatilho → msg → wait → branch → ...). O bloco "Wait Until" suporta delays + condições And/Or.

## Idempotência do `track_event` (trava o "repetir")

`CustomerIo::Client#track_event` (core) tem idempotência sobre `infra_push_notifications` (model `CustomerIo::PushNotification`):

- Chave única: `(tenant_id, user_id, event_id, event_name)`.
- `event_id = event.id = resource_id` (ex.: o `agreement_id` do combinado, NÃO um UUID por disparo).
- Re-emitir o MESMO event name + event_id NÃO envia de novo (dedup silencioso).

**Consequência para lembrete recorrente:** não dá para simplesmente re-emitir `agreement_created`. Precisa de:

- event name NOVO (ex.: `agreement_reminder`) + `event_id` único por período (ex.: `"#{agreement_id}:#{semana}"`), OU
- `check_idempotency: false` (param do `track_event`; usado por cron/batch).

## Caminho do push (quem entrega o quê)

- **`Notification::NotifyUsers#notify`** (core): (1) escreve no **Firestore** → vira notificação **in-app** (sino do app, lida por `mobile/src/integrations/firebase/clinical/firestore/collections/useNotifications.tsx`); (2) se `with_push?`, chama `SendPushNotificationToUser`, que usa FCM **SÓ para `device_platform: BROWSER`** (web do clinical-panel). **NÃO chega no celular.**
- **Push de sistema no celular** = só via **customer.io**: o device token FCM é registrado no customer.io via `add_device` (feito pelo `CreateOrUpdate` use case quando o app manda o token via `createOrUpdateUserDevice` → core). A campanha do customer.io escuta o event e empurra o push.

**Roteamento no app:** o push do customer.io chega via FCM e o app só lê `data.deeplink` (`mobile/src/integrations/firebase/mobile/messaging/subscription.ts`). NÃO há roteamento por `type`/`event_name` no push (isso existe só no NotificationCenter in-app, via Firestore). Não há deeplink configurado para a lista de combinados incompletos nem para `AgreementPreview`.

**Adicionar deeplink é seguro:** o React Navigation (`linking.ts`) recebe a URL e, se o path não casa com nenhuma rota (app desatualizado sem a rota nova), cai na tela inicial (home) **sem crash** — fallback silencioso. Ou seja, deeplink novo é progressivo: app atualizado abre o alvo, desatualizado abre a home.

## Job recorrente no core (padrão para lembrete)

`config/recurring.yml` + `ExecuteRecurringJobWithTenant` + `target_class`. Precedente de "lembrar coisa incompleta/vencida": `Notifications::NotifyUncompletedExpiredSessionsJob` → use case `Intervention::Sessions::UseCases::Notifications::NotifyUncompletedExpiredSessions` (scope `uncompleted_sessions_by_type`).

## Fluxo do push de Combinado (agreement_created) — ponto a ponto

1. `Agreements::UseCases::Create`/`CreateCopm` persiste o `Clinical::Agreement` e emite `AgreementCreated` (`parental_orientation.agreement.v1`).
2. Sub `core-agreement-created-notification-sub` → `Agreements::UseCases::Notifications::NotifyAgreementCreated` (via `ExecuteUseCaseJob`).
3. Para cada caregiver: `Notification::NotifyUsers` (Firestore in-app) + `customer_io.identify` + `customer_io.track_event(AgreementCreated)`.
4. Campanha no customer.io escuta `agreement_created` → push mobile (uma vez).

Eventos de completude (`agreement_completed` etc.) existem no tópico mas **não são trackeados no customer.io** — relevante se alguém quiser uma Journey que "pare" na completude.

## Volume de combinados (BQ) — onde estimar antes de projetar

`clinical_agreements` NÃO está no datakernel (onde vivem `clinical_cases`/`sessions`); está em **`supervision-production-8f1v.parentaltraining.clinical_agreements`**. Colunas úteis: `id`, `clinical_case_id`, `specific_type` (STI), `internal_title`, `completed_at`, `created_at`, `tenant_id`, `due_date`. Não há coluna `native_form_type` no BQ (só no DB) — para identificar COPM use `specific_type = 'Clinical::Agreements::NativeForm'` OU `internal_title = 'Formulário/COPM'`. `completed_at IS NULL` = incompleto. Medida de "novos por semana" = `COUNTIF(completed_at IS NULL) WHERE created_at >= NOW()-30d`.

**Filtrar por caso ativo:** para lembrete, não notificar família de caso encerrado/churn/pausa — juntar com o padrão `queries/utils/active-clinical-cases.sql` (real_case + `status='ongoing'` + disciplina ativa + `churned_at IS NULL` + `on_hold IS NOT TRUE`). Isso derruba o backlog de incompletos em ~2/3 (ex.: combinados 4.814 → 1.525 em casos ativos). O filtro equivalente precisa existir no scope Rails do job (não só `completed_at IS NULL`).

## Destinatários: todos os cuidadores vs. cuidador principal

`NotifyAgreementCreated` notifica **TODOS** os cuidadores do caso: `agreement.clinical_case.caregivers.map(&:user).compact`. Se a feature pedir só o **cuidador principal**, não precisa cruzar o domínio operacional na mão — já existe:

- `Documents::Services::MainCaregiverResolver.call(clinical_case)` (`app/services/documents/services/main_caregiver_resolver.rb`) — pega `family.main_caregiver` via a facade pública `Facades::FamilyFacade` (`packs/operational/app/public/facades/family_facade.rb`), casa com `clinical_case.caregivers` por `user_id`, e faz **fallback** pro primeiro caregiver com user.
- `main_caregiver` vive em `Operational::People::Family#main_caregiver` (coluna `operational_people_families.main_caregiver`, migração `20240904015033`) e é `null: true` — por isso o fallback é necessário.

Trade-off de produto: "só o principal" reduz ruído (1 push vs N), mas se quem de fato preenche é outro cuidador (ex.: o pai responde o COPM, a mãe é a principal), o lembrete não alcança quem age. Validar com PM.

## Backfill dos "represados" (registros antigos incompletos)

Num lembrete por **jornada no customer.io** (gatilho `agreement_created`), os combinados antigos já tiveram o `agreement_created` emitido uma vez — a jornada não re-dispara sozinha. O backfill precisa, **para cada combinado incompleto de caso ativo**, replicar o loop por cuidador do `NotifyAgreementCreated`:

1. `clinical_case.caregivers.map(&:user).compact` — **NÃO** "um evento por combinado" (senão só 1 cuidador recebe).
2. `customer_io.identify(user)` antes do `track_event`.
3. `track_event(user, AgreementCreated, check_idempotency: false)` — sem isso o re-envio é deduplicado.
4. Contexto de tenant (`track_event` levanta `MissingTenantError` sem `tenant_id`) + batching (evitar rate limit).

Contraste com a **opção job no core**: o job consulta `completed_at IS NULL` a cada rodada → backfill grátis (primeira execução já pega os represados) e "parar" automático. A jornada exige o backfill + o tracking de `agreement_completed` no core (para conseguir parar) — dois trabalhos extras que o job não precisa.
