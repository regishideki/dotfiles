Execute o processamento completo de PEI Tracks via kubectl nos ambientes e tenants configurados.

## Configuracao

- **Rake file**: `lib/tasks/process_pei_track_by_clinical_case.rake`
- **Rake task**: `pei_track:process_all`
- **Ambientes**: `production`, `staging`, `development` (pergunte ao usuario quais ambientes rodar se nao for especificado)
- **Tenants**: `genialcare`, `careplus_mindplace` (pergunte ao usuário quais tenants rodar se não especificado)
- **Pasta de output**: `custom_gitignore/pei_track_calculation/{yyyyMMdd}` (relativa ao diretorio do projeto atual)

## Estrutura de pastas de output

```
custom_gitignore/pei_track_calculation/{yyyyMMdd}/
  {env}/
    {tenant}/
      output-1.txt
      output-2.txt  (em caso de retry com offset)
```

Use a data de hoje no formato `yyyyMMdd` (ex: `20260331`).

## Fluxo de execucao

Para cada ambiente solicitado, execute os seguintes passos:

### 1. Preparacao

```bash
kubectx {env}
```

### 2. Obter pod

```bash
podId=$(kubectl get pods --no-headers -n core -o custom-columns=":metadata.name" --field-selector=status.phase=Running | grep web | head -n 1)
```

Valide que o pod foi encontrado antes de continuar.

### 3. Copiar rake file para o pod

```bash
kubectl cp "lib/tasks/process_pei_track_by_clinical_case.rake" "core/${podId}:lib/tasks/process_pei_track_by_clinical_case.rake" -n core
```

### 4. Executar para cada tenant

Para cada tenant, crie a pasta de output e execute:

```bash
mkdir -p custom_gitignore/pei_track_calculation/{yyyyMMdd}/{env}/{tenant}
kubectl exec -it "${podId}" -n core -- rake "pei_track:process_all[{tenant}]" > custom_gitignore/pei_track_calculation/{yyyyMMdd}/{env}/{tenant}/output-1.txt 2>&1
```

### 5. Verificar resultado

Apos cada execucao, leia o arquivo de output para verificar:
- Se completou com sucesso (procure por "FINISHED PEI TRACK PROCESSING")
- Se parou no meio, identifique o numero do ultimo caso processado no output

### 6. Retry com offset (se necessario)

Se a execucao parou no meio:
1. Identifique o numero do ultimo caso clínico processado no output (o ultimo `[numero]` antes da interrupcao)
2. O offset deve ser o numero do ultimo caso + 1
3. Execute novamente com o offset, incrementando o numero da tentativa no nome do arquivo:

```bash
kubectl exec -it "${podId}" -n core -- rake "pei_track:process_all[{tenant},{offset}]" > custom_gitignore/pei_track_calculation/{yyyyMMdd}/{env}/{tenant}/output-2.txt 2>&1
```

4. Repita ate que o processamento finalize com sucesso ou o usuario decida parar

### 7. Resumo

Ao final de todas as execucoes, apresente um resumo com:
- Ambientes processados
- Tenants processados
- Status de cada execucao (sucesso, falha parcial com retry, etc.)
- Numero de tentativas por tenant
- Erros encontrados (se houver)

## Notas importantes

- Sempre pergunte ao usuario quais ambientes ele deseja processar antes de comecar
- O processo pode demorar bastante — use `timeout: 1800000` (30 min) no bash e, se necessario, execute com `run_in_background`
- Se o pod nao for encontrado ou o kubectl falhar, informe o usuario e pergunte como proceder
- Nao execute em paralelo no mesmo ambiente — processe um tenant por vez
- Se o usuario passar um offset manualmente, use-o ao inves de comecar do inicio
