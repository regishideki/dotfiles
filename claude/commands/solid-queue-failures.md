Rode o seguinte comando para buscar os jobs com falha no Solid Queue:

```bash
echo "SELECT * FROM solid_queue_failed_executions;" | kubectl pod enter production core web psql '$DATABASE_URL'
```

Com o resultado, agrupe os jobs por UseCase/Job (baseado no campo `class_name` ou equivalente), mostrando:
- Nome do Job/UseCase
- Quantidade de falhas
- Mensagem de erro (campo `error` ou `exception_message`), se houver

Apresente de forma clara e organizada, do mais recorrente para o menos recorrente.
