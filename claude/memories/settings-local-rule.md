# Regra: Configurações Locais do Claude

## Localização
- Configurações locais devem estar em `~/.claude/settings.local.json` (global)
- Manter `.claude/settings.local.json` nos projetos (mas não modificar)
- Claude Code usa automaticamente o global quando existe

## Motivo
- Evitar diffs constantes no git
- Preservar configurações entre diferentes worktrees
- Centralizar permissões aprovadas

## Procedimento para novos projetos

1. Verificar se existe `.claude/settings.local.json` no projeto
2. Se existir, fazer merge com o global:
   ```bash
   # Merge project settings into global
   ruby -rjson -e '
   global = File.exist?(g="~/.claude/settings.local.json") ? JSON.parse(File.read(File.expand_path(g))) : {"permissions"=>{"allow"=>[]}}
   project = JSON.parse(File.read(".claude/settings.local.json"))
   merged = (global.dig("permissions","allow")||[]) + (project.dig("permissions","allow")||[])
   global["permissions"] = {"allow" => merged.uniq.sort}
   File.write(File.expand_path(g), JSON.pretty_generate(global) + "\n")
   '
   ```
3. **NÃO deletar** o arquivo do projeto nem adicionar ao .gitignore
4. Deixar o arquivo do projeto como está
5. Claude Code vai usar o global automaticamente e não vai mais modificar o arquivo do projeto

## Data de criação
2026-02-12
