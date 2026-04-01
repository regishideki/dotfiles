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
      1_to_10.txt
      11_to_20.txt
      ...
```

Use a data de hoje no formato `yyyyMMdd` (ex: `20260331`).
Os nomes dos arquivos seguem o padrão `{initial}_to_{final}.txt` baseado no range de casos processados.

## Fluxo de execucao

Para cada ambiente solicitado, execute os seguintes passos:

### 1. Preparacao

```bash
kubectx {env}
```

### 2. Obter pods

Liste todos os pods web disponiveis para usar em paralelo:

```bash
kubectl get pods --no-headers -n core -o custom-columns=":metadata.name" --field-selector=status.phase=Running | grep web
```

Valide que os pods foram encontrados antes de continuar. Guarde pelo menos 3 pods para execucao em paralelo.

### 3. Copiar rake file para os pods

Copie o rake file para **todos** os pods que serao usados:

```bash
kubectl cp "lib/tasks/process_pei_track_by_clinical_case.rake" "core/{podId}:lib/tasks/process_pei_track_by_clinical_case.rake" -n core
```

### 4. Executar em batches paralelos

**IMPORTANTE**: Nao execute o rake sem os argumentos `initial` e `final`. Sempre use batches de 10 casos por vez para evitar problemas com buffering de output e deploys que matam os pods.

Para cada tenant, crie a pasta de output e execute **3 batches em paralelo** (um por pod diferente):

```bash
mkdir -p custom_gitignore/pei_track_calculation/{yyyyMMdd}/{env}/{tenant}

# Rodar 3 ranges em paralelo, cada um em um pod diferente:
kubectl exec "{pod1}" -n core -- rake "pei_track:process_all[{tenant},1,10]" 2>&1 | tee custom_gitignore/pei_track_calculation/{yyyyMMdd}/{env}/{tenant}/1_to_10.txt
kubectl exec "{pod2}" -n core -- rake "pei_track:process_all[{tenant},11,20]" 2>&1 | tee custom_gitignore/pei_track_calculation/{yyyyMMdd}/{env}/{tenant}/11_to_20.txt
kubectl exec "{pod3}" -n core -- rake "pei_track:process_all[{tenant},21,30]" 2>&1 | tee custom_gitignore/pei_track_calculation/{yyyyMMdd}/{env}/{tenant}/21_to_30.txt
```

Regras:
- **Nunca use `-it`** (modo interativo) — causa problemas com execucao em background
- **Nunca redirecione com `>`** para arquivo — use `2>&1 | tee` para evitar problemas de buffering
- Use `2>&1 | tee` para capturar stdout e stderr no arquivo e tambem ver o output
- Execute os 3 comandos em paralelo (um por pod) usando tool calls paralelas
- Quando os 3 terminarem, avance para os proximos 3 ranges (31-40, 41-50, 51-60, etc.)
- Continue incrementando ate que um batch retorne `Total clinical cases to process: 0`

### 5. Verificar resultado

Apos cada batch, verifique no output:
- Se completou com sucesso (procure por "FINISHED PEI TRACK PROCESSING")
- Quantos casos foram processados (`Processed: X/Y`)
- Se `Total clinical cases to process: 0`, significa que nao ha mais casos nesse range

### 6. Retry (se necessario)

Se um batch falhou (ex: pod reciclado por deploy):
1. Verifique se os pods mudaram: `kubectl get pods -n core | grep web`
2. Se os pods mudaram, copie o rake file para os novos pods
3. Re-execute o mesmo range no novo pod

### 7. Detectar fim do processamento

Quando um batch retornar `Total clinical cases to process: 0`, significa que nao ha mais casos nesse range.
Continue executando ranges ate que **3 batches consecutivos** retornem 0 casos — isso indica que nao ha mais casos a processar.

### 8. Resumo

Ao final de todas as execucoes, apresente um resumo com:
- Ambientes processados
- Tenants processados
- Total de casos processados
- Ranges executados
- Erros encontrados (se houver)

## Notas importantes

- Sempre pergunte ao usuario quais ambientes ele deseja processar antes de comecar
- Use `timeout: 600000` (10 min) para cada batch de 10 casos
- Execute **ate 3 batches em paralelo**, cada um em um pod diferente
- Se o pod nao for encontrado ou o kubectl falhar, informe o usuario e pergunte como proceder
- Se o usuario passar um offset manualmente, use-o ao inves de comecar do inicio
- Deploys podem reciclar pods a qualquer momento — sempre verifique se o pod ainda existe antes de executar
