Mergear permissões não-commitadas do `settings.local.json` do projeto atual para o `settings.json` global (`~/.claude/settings.json`), e restaurar o arquivo local ao estado commitado.

## Passos

1. Identifique o diretório `.claude/` do projeto atual (pode ser `$CWD/.claude/settings.local.json` ou buscar no git root).

2. Rode o seguinte comando para obter a versão commitada do `settings.local.json`:
```bash
git show HEAD:.claude/settings.local.json 2>/dev/null
```
Se o arquivo não estiver commitado no git (comando falhar), significa que o arquivo inteiro é novo — todas as permissões devem ser mergeadas.

3. Compare as permissões do arquivo atual (`settings.local.json` no disco) com as da versão commitada:
   - **Permissões novas** = as que estão no disco mas NÃO estão na versão commitada
   - Ignore permissões que já existem na versão commitada

4. Leia o arquivo global `~/.claude/settings.json`.

5. Para cada permissão nova encontrada no passo 3:
   - Verifique se já existe no global (evite duplicatas)
   - Se não existir, adicione à lista `permissions.allow` do global

6. Salve o `~/.claude/settings.json` atualizado (mantendo toda a estrutura existente — model, statusLine, plugins, etc.).

7. Restaure o `settings.local.json` ao estado commitado no git:
```bash
git checkout HEAD -- .claude/settings.local.json
```
Se o arquivo não existia no git (era inteiro novo), informe o usuário mas NÃO delete o arquivo automaticamente — pergunte antes.

8. Mostre um resumo:
   - Quantas permissões novas foram adicionadas ao global
   - Liste as permissões adicionadas
   - Confirme que o `settings.local.json` foi restaurado

## Regras importantes

- **NUNCA remova** permissões existentes do global
- **NUNCA modifique** campos além de `permissions.allow` no global
- Se não houver permissões novas para mergear, informe o usuário e não faça nada
- Mantenha a lista `permissions.allow` do global ordenada alfabeticamente
