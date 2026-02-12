# Claude Code Configuration

Este diretório contém as configurações globais do Claude Code, integradas ao sistema de dotfiles via [rcm](https://github.com/thoughtbot/rcm).

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

O rcm cria symlinks automáticos:
- `~/dotfiles/claude/CLAUDE.md` → `~/.claude/CLAUDE.md`
- `~/dotfiles/claude/settings.json` → `~/.claude/settings.json`
- E assim por diante...

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
   git clone git@github.com:seu-usuario/dotfiles.git ~/dotfiles
   ```

2. Execute o rcup para criar os symlinks:
   ```bash
   env RCRC=$HOME/dotfiles/rcrc rcup
   ```

3. Os arquivos de configuração do Claude estarão automaticamente em `~/.claude/`

## Atualizações

Quando você modificar configurações do Claude (adicionar commands, skills, etc), as mudanças já estarão no repositório automaticamente via symlinks. Basta fazer commit:

```bash
cd ~/dotfiles
git add claude/
git commit -m "Update Claude configurations"
git push
```

## Nota sobre Plugins

Os plugins do marketplace oficial são versionados sem o histórico git (o diretório `.git` foi removido). Se precisar atualizar, o Claude Code fará o download automaticamente e você pode commitar as mudanças.
