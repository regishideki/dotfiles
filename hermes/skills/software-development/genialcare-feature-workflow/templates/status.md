# Status — <título da feature>

**User story**: <yyyyMMdd-slug>
**Jira**: [<CARD>](https://genialcare.atlassian.net/browse/<CARD>)
**Fase atual**: <planejamento | execução | revisão | concluída>
**Última atualização**: <timestamp>

## PRs

| Repo | PR | Estado | Branch | Merge order | Observações |
|---|---|---|---|---|---|
| core | #123 | draft / ready / aprovado / mergeado | feat/xxx | 1 | — |
| clinical-panel-bff | #456 | draft | feat/yyy | 2 | — |
| clinical-panel | #789 | draft | feat/zzz | 3 | — |

## Ambiente local

| Serviço | URL | Worktree | Porta | Estado |
|---|---|---|---|---|
| core | http://localhost:3000 | (canônico) | 3000 | up/down |
| clinical-panel-bff | http://localhost:4050/graphql | (canônico) | 4050 | up/down |
| clinical-panel | http://localhost:5050 | <path do worktree> | 5050 | up/down |

> Se rodando 2+ stories em paralelo, liste cada worktree do panel com sua porta (5050/5051/5052).

## Jobs de automação

| Job | Tipo | ID | Agenda | Estado |
|---|---|---|---|---|
| varre comentários PR#123 | cronjob | <job_id> | 0 9-19 * * 1-5 | ativo/parado |
| merge PR#123 | cronjob | <job_id> | 0 9-19 * * 1-5 | ativo/parado |

## Decisões tomadas (decision log)

- <data> — <decisão não-trivial> — <por quê / fonte consultada>

## Bloqueios / pendências com o usuário

- [ ] <descrição do que está aguardando decisão do usuário>

## Definição de Pronto (DoD)

### Critérios funcionais
- [ ] <critério>

### Critérios técnicos
- [ ] <critério>

### Critérios de entrega
- [ ] PR por repo aberto, revisado e mergeado
- [ ] `todo.md` e este `status.md` atualizados
- [ ] Cleanup concluído (jobs parados, worktrees removidos, stack derrubada)
