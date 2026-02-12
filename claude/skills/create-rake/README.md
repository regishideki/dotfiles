# Skill: Create Rake Tasks

Esta skill fornece um guia completo para criar rake tasks seguindo os padrões estabelecidos no projeto Genial.

## 📚 Estrutura da Skill

### 1. **SKILL.md** - Guia Principal
Documentação completa com:
- Quando usar rake tasks
- Estrutura básica
- Componentes essenciais
- Padrões avançados (DRY_RUN, BYPASS_ERRORS, Transactions)
- Exemplos completos
- Boas práticas
- Anti-patterns

### 2. **examples.md** - Biblioteca de Exemplos
10 exemplos práticos cobrindo:
- Migração simples
- Importação CSV
- Operações em lote
- Migrations complexas
- UseCases
- Multi-tenant
- Relatórios
- Correção de dados
- Argumentos múltiplos
- Processamento em batches

### 3. **checklist.md** - Checklist Rápido
Checklist passo-a-passo para criar rake tasks:
- Estrutura básica
- Setup inicial
- Controles opcionais
- Processamento
- Error handling
- Summary
- Decision tree
- Template completo

## 🎯 Como Usar

### Para criar uma nova rake task:

1. **Determine o tipo de operação:**
   - Consulte o "Decision Tree" no checklist.md
   - Decida se precisa de DRY_RUN, BYPASS_ERRORS, TRANSACTION

2. **Escolha um exemplo similar:**
   - Veja examples.md e encontre o caso mais próximo
   - Use como base para sua implementação

3. **Siga o checklist:**
   - Use checklist.md durante a implementação
   - Marque cada item conforme completa

4. **Consulte os padrões:**
   - Veja SKILL.md para detalhes de padrões específicos
   - Especialmente as seções sobre Transactions e UseCases

## 📖 Referência Rápida

### Quando usar DRY_RUN?
```
✅ Operação destrutiva (delete, update em massa)
✅ Operação crítica (financeiro, contratos)
❌ Operação facilmente reversível
```

### Quando usar BYPASS_ERRORS?
```
✅ Validações complexas
✅ Ambientes não produtivos
✅ Quando progresso parcial é válido
❌ Produção sem análise prévia
```

### Quando usar TRANSACTION?
```
✅ Deve ser tudo-ou-nada
✅ Múltiplos registros relacionados
✅ Dados críticos
❌ Progresso parcial é OK
❌ Milhares de registros independentes
```

### UseCase em Transaction?
```ruby
# ❌ ERRADO
ActiveRecord::Base.transaction do
  ctx = UseCase.call(params: {})
  # ctx.success? == false NÃO FAZ ROLLBACK
end

# ✅ CORRETO
ActiveRecord::Base.transaction do
  ctx = UseCase.call(params: {})
  unless ctx.success?
    raise StandardError, ctx[:errors].map { |e| e[:message] }.join(", ")
  end
end
```

## 🔍 Índice de Exemplos

1. **Migração Simples** - Backfill de campos
2. **Importação CSV** - Ler e processar CSV
3. **Operação em Lote** - Atualização com DRY_RUN
4. **Migração Complexa** - Com transaction e validação
5. **UseCase** - Cancelamento via UseCase
6. **Multi-Tenant** - Processar todos os tenants
7. **Relatório** - Gerar CSV de inconsistências
8. **Correção** - Fix de dados com dry-run
9. **Argumentos** - Múltiplos parâmetros
10. **Batches** - Processar em lotes

## 💡 Dicas Importantes

1. **Sempre teste em dry-run primeiro**
2. **UseCases em transactions requerem exception manual**
3. **Nem toda operação precisa de transaction**
4. **Acumule erros, não imprima durante processamento**
5. **Sempre inclua summary ao final**
6. **Use `User.system_user` ao invés de hardcoded user_id**

## 🚀 Template Rápido

```bash
# Criar nova rake task
touch lib/tasks/namespace/task_name.rake

# Estrutura básica
namespace :namespace do
  desc "Description"
  task task_name: :environment do
    puts "========== STARTED =========="
    # Implementation
    puts "========== FINISHED =========="
  end
end

# Com controles completos
task :name, [:confirmation, :bypass_errors] => :environment do |_, args|
  confirmation = args[:confirmation] == "true"
  bypass_errors = args[:bypass_errors] == "true"
  # Implementation
end
```

## 📝 Padrões de Progresso

```ruby
print "."  # Sucesso
print "e"  # Erro (minúsculo)
print "F"  # Falha (maiúsculo)
print "U"  # Would update (dry-run)
```

## 🎓 Aprendizado Progressivo

### Nível 1 - Básico
- Leia: Estrutura Básica (SKILL.md)
- Exemplo: #1 - Migração Simples
- Pratique: Criar rake task simples sem controles

### Nível 2 - Intermediário
- Leia: Padrões Avançados - DRY_RUN (SKILL.md)
- Exemplo: #3 - Operação em Lote
- Pratique: Adicionar dry-run a uma task

### Nível 3 - Avançado
- Leia: Transactions e UseCases (SKILL.md)
- Exemplo: #4 - Migração Complexa
- Pratique: Migration com transaction e bypass_errors

### Nível 4 - Expert
- Leia: Anti-patterns (SKILL.md)
- Exemplo: #5 - UseCase em Transaction
- Pratique: Revisar e refatorar rake tasks existentes

## 📞 Quando em Dúvida

1. Consulte checklist.md para decisões rápidas
2. Procure exemplo similar em examples.md
3. Leia detalhes em SKILL.md
4. Use o template completo no checklist.md

## ✅ Checklist Final

Antes de commitar sua rake task:

- [ ] Segue a estrutura básica
- [ ] Tem descrição clara
- [ ] Usa User.system_user
- [ ] Tem progress indicators
- [ ] Acumula erros
- [ ] Tem summary ao final
- [ ] DRY_RUN se destrutiva
- [ ] BYPASS_ERRORS se complexa
- [ ] Transaction se necessário
- [ ] Testada em dry-run
- [ ] Testada em dev/staging
