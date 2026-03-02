# Skill: Docker Troubleshoot

Use esta skill quando o projeto não estiver funcionando corretamente no Docker — containers subindo com erro, jobs falhando, app inacessível, ou qualquer comportamento inesperado após iniciar o ambiente.

## Passo 1: Verificar os logs

Primeiro, identifique o erro nos logs:

```bash
make logs
```

Procure por mensagens de erro nas primeiras linhas. Com base no erro encontrado, siga o caso correspondente abaixo.

---

## Casos Conhecidos

### Caso 1: Tabelas do Solid Queue não existem

**Sintoma nos logs:**

```
PG::UndefinedTable: ERROR: relation "solid_queue_recurring_tasks" does not exist
```

(ou qualquer outra tabela `solid_queue_*`)

**Causa:** As tabelas do Solid Queue não foram criadas corretamente no banco de dados, o que ocorre eventualmente ao iniciar o projeto do zero.

**Solução:**

1. Entre no container **sem iniciar o servidor**:

```bash
docker-compose run --entrypoint /bin/bash app
```

2. Dentro do container, resete o banco:

```bash
rails db:reset
```

3. Saia do container (`exit`) e, fora dele, rode:

```bash
make migrate
make up
```

4. Verifique os logs novamente para confirmar que o problema foi resolvido:

```bash
make logs
```

---

### Caso 2: Gems não encontradas no bundle

**Sintoma nos logs:**

```
Bundler::GemNotFound: Could not find <gem-name> in locally installed gems
```

**Causa:** O volume Docker `bundle_path` ficou desatualizado após atualização do `Gemfile.lock` ou recriação do ambiente. As gems precisam ser reinstaladas no volume.

**Solução:**

1. Reinstale as gems dentro do container sem iniciar o servidor:

```bash
docker-compose run --entrypoint /bin/bash app -c "bundle install"
```

2. Suba o ambiente normalmente:

```bash
make up
```

3. Verifique os logs:

```bash
make logs
```

> **Observação:** Se após instalar as gems o erro do Solid Queue aparecer (Caso 1), execute o fix do Caso 1 na sequência.

---

## Adicionando novos casos

Se encontrar um novo problema recorrente com o Docker, adicione aqui um novo caso seguindo o padrão:

- **Sintoma nos logs**: trecho exato do erro
- **Causa**: explicação breve do motivo
- **Solução**: passo a passo para resolver
