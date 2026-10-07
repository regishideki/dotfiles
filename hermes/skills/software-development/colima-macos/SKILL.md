---
name: colima-macos
description: "Migrate Docker Desktop to Colima on macOS, then uninstall."
---

# Colima no macOS (substituto do Docker Desktop)

Colima é um runtime Docker leve no macOS: usa uma VM Lima baseada no
Virtualization.framework da Apple (não QEMU por padrão em Apple Silicon). Substitui o
Docker Desktop. Grátis (MIT), sem licença/telemetria, **só CLI** (sem GUI/dashboard).

Quando usar: quando o Docker Desktop está comendo CPU/RAM, ou quando se quer evitar a
licença paga do OrbStack para uso comercial.

## Migração do Docker Desktop

1. Quitar o Docker Desktop (`osascript -e 'quit app "Docker"'`).
2. Instalar:
   ```bash
   brew install colima docker docker-compose
   ```
3. **Compose v2 agora é plugin** — sem isso, `docker compose` (com espaço) falha.
   Adicionar ao `~/.docker/config.json`:
   ```json
   { "cliPluginsExtraDirs": ["/opt/homebrew/lib/docker/cli-plugins"] }
   ```
   O brew cria o symlink `/opt/homebrew/bin/docker-compose`, então o formato com hífen
   (`docker-compose`, usado por Makefiles antigos) também funciona.
4. Ligar a VM (ajuste cpu/memory conforme o host):
   ```bash
   colima start --cpu 6 --memory 8
   ```
5. Validar: `docker run --rm hello-world`.
6. **Recriar redes externas** que existiam na VM do Docker Desktop (ex.: `docker network create genial`).
7. Recriar o que vive em volumes (bancos, bundles) — eles nascem vazios no Colima.

## Gotchas de operação

- **PATH shadowing**: o Docker Desktop instala symlinks em `/usr/local/bin/` (root:
  `docker`, `docker-compose`, `kubectl`, etc.) apontando para `/Applications/Docker.app`.
  O brew instala em `/opt/homebrew/bin`. No zsh do usuário, `/opt/homebrew/bin` vem ANTES
  de `/usr/local/bin`, então o do brew vence — mas em bash/outros shells, confira
  `which -a docker`. Depois de apagar o Docker.app, esses symlinks ficam dangling.
- **Estado persiste em `colima stop`/`start`**: imagens, containers e volumes sobrevivem
  (disco da VM é persistente). Só `colima delete` apaga tudo.
- **Não liga sozinho no login** (diferente do Docker Desktop). Após reboot: `colima start`,
  ou `brew services start colima` para auto-start.
- **Volume `bundle_path` vazio em Colima novo → `Bundler::GemNotFound`**: o build instala as
  gems em `/usr/local/bundle`, mas em runtime `BUNDLE_PATH=/bundle/vendor` (volume) redireciona.
  Com o volume recém-criado e vazio, o app cai com "Could not find ... in locally installed gems".
  **Não use atalho `cp -a /usr/local/bundle/. /bundle/vendor/`** — não resolve, porque default gems
  do Ruby (`cgi`, `ostruct`, `resolv`) vivem na stdlib, não em `/usr/local/bundle`, e o bundler
  exige TODAS (inclusive as default) dentro do volume. Corrija com `docker compose run --rm app
  bundle install` (instala todas + default gems no volume). Na sequência costuma aparecer o crash
  do Solid Queue em DB vazio — rode `db:migrate` via `--entrypoint bundle` (ver `docker-troubleshoot`).
- **Memória/OOM**: suítes de teste são pesadas por natureza. O jest spawna N workers × ~1GB
  (N = nº de CPUs da VM); Rails rspec + app rodando + jest concorrentes passam de 6GB fácil.
  Mais CPUs = mais workers do jest = mais memória. Dimensione o Colima pelo RAM do host
  (ex.: 8GB num host de 16GB). Sintoma de OOM no Colima: processo `Killed` sem traceback Ruby,
  ou `docker logs` mostrando `Exited (137)`.

## Desinstalar o Docker Desktop (limpeza completa)

O grande vilão do HD é o disco da VM: **37GB** em
`~/Library/Containers/com.docker.docker`. Além dele:

| Local | O que é | precisa sudo? |
|---|---|---|
| `/Applications/Docker.app` | app (1.8GB) | não |
| `~/Library/Containers/com.docker.docker` | disco da VM (37GB) | não* |
| `~/.docker/scout` | cache Scout (1.4GB) | não |
| `~/Library/Application Support/Docker Desktop`, `Caches/com.docker.docker`, `HTTPStorages/com.docker.docker`, `Preferences/com.docker.*`, `Group Containers/group.com.docker`, `Application Scripts/group.com.docker` | artefatos do app | não |
| `/usr/local/bin/{docker,docker-compose,kubectl,...}` | symlinks root (dangling) | **sim** |
| `/Library/PrivilegedHelperTools/com.docker.vmnetd` + `/Library/LaunchDaemons/com.docker.vmnetd.plist` | helper privilegiado (LaunchDaemon) | **sim** |

\* A remoção do container deixa um `.com.apple.containermanagerd.metadata.plist` (460 bytes)
protegido pelo containermanagerd — `rm` retorna "Operation not permitted" mesmo como owner.
É irrelevante; ignore ou remova com sudo.

Sudo que resta (só depois de confirmar que tudo roda no Colima):
```bash
sudo launchctl bootout system/com.docker.vmnetd 2>/dev/null
sudo pkill -f com.docker.vmnetd 2>/dev/null
sudo rm -f /Library/PrivilegedHelperTools/com.docker.vmnetd /Library/LaunchDaemons/com.docker.vmnetd.plist
sudo rm -f /usr/local/bin/docker /usr/local/bin/docker-compose /usr/local/bin/docker-compose-v1 \
  /usr/local/bin/docker-credential-desktop /usr/local/bin/docker-credential-ecr-login \
  /usr/local/bin/docker-credential-osxkeychain /usr/local/bin/docker-index /usr/local/bin/hub-tool \
  /usr/local/bin/kubectl /usr/local/bin/kubectl.docker /usr/local/bin/vpnkit /usr/local/bin/com.docker.cli \
  /usr/local/bin/kubectl-pod-enter /usr/local/bin/kubectl-pod-enter-node \
  /usr/local/bin/kubectl-secretentry-upsert /usr/local/bin/kubectl-secretvalue-get
```

Antes de remover, corrigir o `~/.docker/config.json`:
- `"credsStore": "desktop"` → `"osxkeychain"` (e `brew install docker-credential-helper`),
  senão `docker login` quebra depois que o `docker-credential-desktop` sumir.
- `docker context rm desktop-linux` (o contexto do Docker Desktop).

## Relação com outras skills

- `docker-troubleshoot` — erros de container do projeto (Solid Queue, GemNotFound) depois que
  o runtime já está de pé. O GemNotFound por volume `bundle_path` vazio no Colima é tratado lá.
