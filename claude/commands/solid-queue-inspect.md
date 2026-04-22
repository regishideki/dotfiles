Analise os jobs no Solid Queue em produção. Detecte o modo a partir dos ARGUMENTS:
- Se ARGUMENTS contiver "bloqueado", "blocked" ou "block" → modo **bloqueados**
- Caso contrário → modo **falhas** (padrão)

---

## Modo: Falhas

Rode:

```bash
echo "SELECT j.class_name, f.error::jsonb->>'exception_class' AS exception_class, f.error::jsonb->>'message' AS message, f.created_at FROM solid_queue_failed_executions f JOIN solid_queue_jobs j ON j.id = f.job_id ORDER BY j.class_name, f.created_at DESC;" | kubectl pod enter production core web psql '$DATABASE_URL' 2>&1
```

Com o resultado, agrupe por `class_name` e apresente:
- Nome do Job
- Total de falhas
- Exceção mais comum (`exception_class`)
- Mensagem de erro (`message`)

Ordene do mais recorrente para o menos recorrente.

---

## Modo: Bloqueados

Rode:

```bash
echo "SELECT j.class_name, b.concurrency_key, b.queue_name, COUNT(*) AS blocked_count, MIN(b.created_at) AS oldest, MAX(b.created_at) AS newest FROM solid_queue_blocked_executions b JOIN solid_queue_jobs j ON j.id = b.job_id GROUP BY j.class_name, b.concurrency_key, b.queue_name ORDER BY blocked_count DESC;" | kubectl pod enter production core web psql '$DATABASE_URL' 2>&1
```

Com o resultado, agrupe por `class_name` somando `blocked_count` e apresente:
- Nome do Job
- Total bloqueados (soma de todas as chaves de concorrência)
- Quantidade de chaves de concorrência distintas
- Fila (`queue_name`)
- Timestamp do mais antigo (`oldest`)
- Observação: se a chave de concorrência for global (sem UUID/ID) ou por recurso

Ordene do mais bloqueado para o menos bloqueado. Destaque padrões relevantes (chave global vs. por tenant, concentração em uma fila, etc.).

---

Ao final, apresente um resumo em tabela Markdown com os totais por job, do mais crítico ao menos crítico. Não inclua numeração nos itens.
