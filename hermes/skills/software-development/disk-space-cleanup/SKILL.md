---
name: disk-space-cleanup
description: Use when freeing macOS disk space ("HD cheio").
---

# Skill: Disk Space Cleanup (macOS)

Use quando o usuário pedir para liberar espaço em disco ("meu HD está quase cheio",
"procura o que dá pra limpar", "coisas grandes e pouco usadas").

Princípio central: **inventariar antes de apagar**, e **nunca apagar o que foi usado
recentemente** — o usuário tende a voltar a usar e remover é desperdício. Prefira
cache rebuildável e imagens dangling; nunca toque em volumes nomeados do Docker.

## Passo 1 — Medir o espaço real

`df -h /` mostra o volume do SO (snapshot APFS) com números enganosos. O espaço real
de dados fica no volume Data:

```bash
df -h /System/Volumes/Data   # este é o número que importa
```

`du -sh ~` costuma **estourar timeout (60s)** em homes grandes. Quebre sempre por
subdiretórios, em paralelo:

```bash
du -sh ~/* 2>/dev/null | sort -rh | head -25
du -sh ~/.* 2>/dev/null | sort -rh | head -25   # ocultos (pode demorar)
du -sh ~/Library/Caches/* 2>/dev/null | sort -rh | head -25
du -sh ~/Library/Developer/* 2>/dev/null | sort -rh | head -20
du -sh ~/Library/Application\ Support/* 2>/dev/null | sort -rh | head -20
du -sh ~/Library/Containers/* 2>/dev/null | sort -rh | head -20
du -sh ~/workspace/* 2>/dev/null | sort -rh | head -20
```

## Diagnóstico: disco "cresce e encolhe" até crashar

Sintoma: espaço usado flutua sem razão aparente e às vezes enche até o SO crashar
(kernel panic). Causa raiz típica: RAM insuficiente → compressor de memória enche
→ spill pro swap → swap cresce rápido dentro de um disco já quase cheio.

```bash
df -h /System/Volumes/Data        # espaço real no volume de dados
sysctl vm.swapusage               # swap usado/total agora
ls -lh /private/var/vm/           # só mostra sleepimage (~1GB); o swap NÃO vive aqui
vm_stat                           # pressão de memória
sysctl -n hw.memsize | awk '{printf "%.1f GB\n", $1/1024/1024/1024}'
```

Pontos-chave:

- No macOS moderno o swap vive no volume APFS dedicado **VM**
  (`/System/Volumes/VM`), NÃO no volume Data. Por isso `ls /private/var/vm/`
  só lista o `sleepimage` (~1GB). O swap real aparece em `sysctl vm.swapusage`.
- `vm_stat`: `Pages stored in compressor` × 16384 bytes = GB que o compressor
  segura. Se ≈ 2× a RAM física, a máquina está sob pressão forte e o swap vai
  crescer. Com 16GB de RAM isso é comum em dev (Docker + browsers + editors).

## Interpretando o Disk Utility ("Other Volumes")

Ao selecionar "Macintosh HD" (volume de Sistema, selado/só-leitura) no Disk
Utility, o usuário vê "Used: ~10GB" + "Other Volumes: ~472GB". **"Other
Volumes" não é swap nem algo limpável à parte** — é a soma dos volumes APFS
irmãos no mesmo container, dominada pelo volume **Data** (os arquivos reais).

Enumere os volumes e o que cada um consome:

```bash
diskutil apfs list | grep -E "Name|Capacity Consumed"
```

Volumes típicos do container: Data (a esmagadora maioria — arquivos do usuário),
System/Macintosh HD (~10-15GB selado), Preboot (~7GB), VM (swap+sleepimage,
alguns GB), Recovery (~2GB). O número que importa pra espaço é o volume **Data**.

## Passo 2 — Mapa dos maiores consumidores (macOS dev machine)

Por ordem típica de retorno:

| Alvo | Local | Segurança |
| --- | --- | --- |
| **Docker.raw** (esparso; encolhe só com TRIM após limpar órfãos) | `~/Library/Containers/com.docker.docker/Data/vms/0/data/Docker.raw` | ver seção Docker |
| **Xcode DerivedData** (build cache) | `~/Library/Developer/Xcode/DerivedData/<projeto-hash>/` | 100% seguro, rebuilda |
| **Claude VM bundle** (sandbox, fica velho) | `~/Library/Application Support/Claude/vm_bundles/` | seguro, recria |
| **Yarn cache** | `~/Library/Caches/Yarn` | seguro |
| **pypoetry** | `~/Library/Caches/pypoetry/` | só `artifacts`+`cache` (não `virtualenvs`) |
| **ms-playwright** (navegadores) | `~/Library/Caches/ms-playwright*` | seguro, re-baixa |
| **CoreSimulator** | `~/Library/Developer/CoreSimulator/` | parcial (`simctl`) |
| **Chrome/Edge profiles** | `~/Library/Application Support/Google|Microsoft Edge` | cuidado, dados de navegação |

## Passo 3 — Docker (o elefante)

`docker system df` **sub-reporta o build cache**. Numa máquina real, mostrou
"Build Cache 2.9GB" mas `docker builder prune -af` recuperou **26.68GB** — confie no
que o prune retorna, não no df.

Ordem de poda, do seguro para o destrutivo:

```bash
docker builder prune -af        # build cache: seguro, enorme
docker container prune -f       # containers parados (não apaga volume)
docker image prune -f           # SÓ imagens dangling (<none>:<none>) — NUNCA -a aqui
# tags claramente obsoletas (2-3 anos), seletivo:
docker rmi <repo>:<tag-velha>
```

**Pitfalls críticos:**

- `docker image prune -a` removeria TODAS as imagens não usadas por container ativo —
  inclusive `core-app`, `clinical-language-models-app`, etc. que o usuário VAI reusar.
  Use `-f` (dangling only) e depois `docker rmi` seletivo nas tags velhas.
- `docker volume prune` é PERIGOSO: volumes NOMEADOS (`core_postgres`,
  `product-engineer-agent_wiki-data`, `clinical-language-models_postgres`, ...) têm
  **dados de dev reais**. Depois de remover containers parados, TODOS os volumes
  aparecem "unused" e o prune apagaria os bancos. Nunca rode `volume prune` sem antes
  listar e confirmar que só há volumes órfãos (hash-nomes anônimos).
- **`docker system df` NÃO conta logs de container órfãos — o maior vazamento oculto.**
  Um container com log sem limite (`json-file` sem `max-size`) gera um único
  `*-json.log` que pode chegar a dezenas de GB. Após `docker container prune`, o df
  mostra "Containers: 0B" mas o arquivo órfão segue em
  `/var/lib/docker/containers/<id>/<id>-json.log`. Numa sessão real: um log de
  **29.6GB** órfão mantinha o `Docker.raw` em 66GB — o usuário limpava o cache
  visível e o problema "voltava" porque esse fantasma não aparecia em lugar nenhum.
  Inspecionar o uso REAL dentro da VM (o df esconde):
  ```bash
  docker run --rm --privileged -v /:/host alpine sh -c 'du -sh /host/var/lib/docker/* | sort -rh'
  # achar o(s) log(s) gigantes:
  docker run --rm --privileged -v /:/host alpine sh -c 'find /host/var/lib/docker/containers -name "*.log" -exec du -sh {} + | sort -rh'
  # limpar os órfãos (SÓ depois de confirmar `docker ps -a` vazio):
  docker run --rm --privileged -v /:/host alpine sh -c 'rm -rf /host/var/lib/docker/containers/*'
  ```
- **`DiskSizeMiB` abaixo do uso real é ignorado silenciosamente.** Editar o
  `settings-store.json` e reiniciar aplica a MEMÓRIA da VM, mas o Docker mantém o
  limite de disco antigo se o novo valor < uso real (o UI continua mostrando o
  limite velho, sem erro). Meça o uso real na VM antes de baixar o teto.
- **Com `DiskTRIM: true` (default no Docker Desktop moderno/virtiofs), o `Docker.raw`
  ENCOLHE sozinho** depois que você libera espaço dentro da VM (observei 66GB → 37GB).
  O "nunca encolhe" vale para estados sem TRIM; o gargalo real é apagar os órfãos que
  o df esconde — o resize automático acontece em seguida.
- **Prevenção (a causa raiz recorre se não tratar):** limitar o log dos serviços no
  docker-compose para o arquivo não crescer de novo:
  ```yaml
  logging:
    driver: json-file
    options:
      max-size: "50m"
      max-file: "3"
  ```
  E reduzir a RAM da VM (`MemoryMiB`) alivia a pressão de memória → menos swap → menos
  risco de encher o disco do host até o kernel panic.

## Passo 4 — Caches de pacotes

```bash
yarn cache clean                 # yarn v1: rápido (~17s), 0B depois
# poetry 2.x: `poetry cache clear --all` FALHA ("Not enough arguments").
poetry cache list                # lista: PyPI, _default_cache, ...
poetry cache clear PyPI --all
# alternativa direta (mais rápida que o comando, que estoura timeout em cache grande):
rm -rf ~/Library/Caches/pypoetry/artifacts ~/Library/Caches/pypoetry/cache
#   → NÃO tocar em ~/Library/Caches/pypoetry/virtualenvs (ambientes ativos dos projetos)
rm -rf ~/Library/Caches/ms-playwright ~/Library/Caches/ms-playwright-go
rm -rf ~/Library/Developer/Xcode/DerivedData/<hash-do-projeto>   # rebuilda sob demanda
```

Estrutura do `pypoetry`: `artifacts` (wheels/sdists) + `cache` (http) = download
cache seguro; `virtualenvs` = ambientes virtuais criados por `poetry install`, ativos.

## Passo 5 — Docker Desktop "janela não abre" (tray preso)

Sintoma: backend/engine saudável (`docker ps` responde, `docker info` mostra Server
Version), mas a janela da UI não aparece — o app ficou preso em modo tray.

Fix (só depois de confirmar que não há containers rodando com estado importante):

```bash
osascript -e 'quit app "Docker"'          # muitas vezes NÃO encerra de verdade
killall "Docker Desktop"; sleep 2
killall com.docker.backend; sleep 2
open -a Docker
```

Verificar que a janela voltou com `computer_use` action=`list_windows` (procurar
"Images - Docker Desktop"). Containers parados e volumes/imagens persistem — é seguro.

## Ver também

- `references/docker-disk-deep-dive.md` — números reais da sessão e o raciocínio de
  inventário seletivo vs. prune agressivo.
