# Claude Code Configuration

Este diretório contém as configurações globais do Claude Code, integradas ao sistema de dotfiles.

## Estrutura

```
claude/
├── .gitignore          # Ignora arquivos temporários e caches
├── CLAUDE.md           # Instruções globais do Claude
├── settings.json       # Configurações do Claude Code
├── commands/           # Comandos customizados
├── skills/             # Skills customizadas
└── plugins/            # Plugins oficiais do marketplace
```

## Como Funciona

**`~/.claude` é um symlink direto para este diretório:**
- `~/.claude/` → `~/dotfiles/claude/`

Isso significa que **qualquer arquivo criado ou modificado em `~/.claude/` já está automaticamente no git**!

✅ Você ou o Claude podem criar/modificar arquivos diretamente
✅ Tudo já fica versionado automaticamente
✅ Não precisa copiar nada manualmente
✅ O `.gitignore` cuida dos arquivos temporários

### Arquivos Versionados

- **CLAUDE.md**: Instruções globais que o Claude segue em todos os projetos
- **settings.json**: Configurações como permissões, statusLine e modelo padrão
- **commands/**: Comandos customizados (`/comando`)
- **skills/**: Skills customizadas
- **plugins/**: Plugins do marketplace oficial

### Arquivos Ignorados (via .gitignore)

Arquivos temporários e caches não são versionados:
- `cache/`, `debug/`, `history.jsonl`
- `projects/`, `plans/`, `todos/`
- `telemetry/`, `stats-cache.json`
- etc.

## Instalação em Nova Máquina

1. Clone o repositório dotfiles:
   ```bash
   git clone git@github.com:regishideki/dotfiles.git ~/dotfiles
   ```

2. Crie o symlink para a pasta claude:
   ```bash
   ln -s ~/dotfiles/claude ~/.claude
   ```

3. Execute o rcup para os outros dotfiles:
   ```bash
   env RCRC=$HOME/dotfiles/rcrc rcup
   ```

Pronto! Suas configurações do Claude estarão em `~/.claude/`

## Atualizações

Como `~/.claude` é um symlink direto para `~/dotfiles/claude/`, qualquer mudança já está no git!

```bash
cd ~/dotfiles
git status              # Ver o que mudou
git add claude/         # Adicionar mudanças
git commit -m "Update Claude configurations"
git push
```

**Exemplo prático:**
```bash
# Claude cria um novo arquivo em ~/.claude/skills/my-skill/SKILL.md
# O arquivo já está em ~/dotfiles/claude/skills/my-skill/SKILL.md
# Basta commitar!
```

## Nota sobre Plugins

Os plugins do marketplace oficial são versionados sem o histórico git (o diretório `.git` foi removido). Se precisar atualizar, o Claude Code fará o download automaticamente e você pode commitar as mudanças.
