# Instruções Globais

## Permissões de Comandos

- Sempre que um novo comando Bash for aprovado pelo usuário durante uma sessão, adicione-o imediatamente ao arquivo `~/.claude/settings.json` (configuração global), na lista `permissions.allow`.
- Nunca deixe comandos aprovados apenas no `settings.local.json` do projeto — a configuração global é a fonte de verdade.
- Use o padrão curinga `Bash(comando:*)` sempre que possível para cobrir variações do mesmo comando.

## Testes

- Sempre que modificar uma implementação, verificar e atualizar os testes relacionados quando necessário.
