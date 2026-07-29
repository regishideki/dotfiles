---
name: solid-queue-failures
description: "Busca jobs com falha no Solid Queue em produção e agrupa por Job/UseCase, do mais recorrente para o menos."
version: 1.0.0
author: regishattori
license: MIT
platforms: [linux, macos, windows]
metadata:
  hermes:
    tags: [solid-queue, rails, production, debugging, kubectl]
    related_skills: [solid-queue-inspect]
---

# Solid Queue Failures

Busca jobs com falha no Solid Queue em produção e os agrupa por Job/UseCase.

## Query

Rode o seguinte comando para buscar os jobs com falha no Solid Queue:

```bash
echo "SELECT j.class_name, f.error::jsonb->>'exception_class' AS exception_class, f.error::jsonb->>'message' AS message, f.created_at FROM solid_queue_failed_executions f JOIN solid_queue_jobs j ON j.id = f.job_id ORDER BY j.class_name, f.created_at DESC;" | kubectl pod enter production core web psql '$DATABASE_URL' 2>&1
```

## Apresentação

Com o resultado, agrupe os jobs por UseCase/Job (baseado no campo `class_name`), mostrando:
- Nome do Job/UseCase
- Quantidade de falhas
- Mensagem de erro (`message`), se houver

Apresente de forma clara e organizada, do mais recorrente para o menos recorrente. Não inclua numeração nos itens da lista.
