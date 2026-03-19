# Plano de Migração Vim → Neovim

## Análise de Compatibilidade

### Totalmente compatível (sem alteração necessária)

- Todos os ftplugin (`vim/ftplugin/*`) — usam apenas `setlocal`
- `vim/plugin/ctags.vim`
- `vim/pythonx/snippet_helpers.py` (Neovim usa Python3)
- Quase todos os plugins do `vimrc.bundles` — tpope/*, fzf, vim-test, ALE, coc.nvim (funciona melhor no Neovim), NERDTree, airline, gitgutter, etc.
- `tmux.conf` — navegação `grep -iq vim` funciona porque "nvim" contém "vim"
- tmuxline.vim, vim-tmux-runner, tslime.vim

### Incompatibilidades encontradas

| Item | Arquivo | Severidade | Detalhe |
|------|---------|------------|---------|
| `&t_ti` / `&t_te` | `vimrc.local:78-79` | **Alta** | Neovim não suporta variáveis de terminal `t_*`. Precisa ser substituído por `let &titlestring` |
| `&t_Co` check | `vimrc:17` | **Baixa** | Neovim sempre tem cores, condição desnecessária mas inofensiva |
| `gundo.vim` | `vimrc.bundles:74` | **Média** | Requer Python 2. Neovim só suporta Python 3. Substituir por `mundo.vim` |
| `pathogen#infect()` | `vimrc.local:88` | **Média** | Redundante com vim-plug, pode causar conflitos. Remover |
| `set nocompatible` | `vimrc.bundles:2` | **Nenhuma** | Inofensivo, Neovim ignora |
| `set shell=bash\ -l` | `vimrc.local:7` | **Baixa** | Funciona, mas login shell é mais lento |
| `clipboard=unnamed` | `vimrc.local:3` | **Baixa** | Funciona, mas Neovim prefere `unnamedplus` |

### Resumo: migração de **baixo risco**

---

## Fase 0: Backup e Rollback

O Neovim lê de `~/.config/nvim/init.vim`, **não** de `~/.vimrc`. Isso significa que o Vim original continua 100% funcional durante toda a migração.

**Rollback a qualquer momento:**

1. Remover `~/.config/nvim/`
2. Continuar usando `vim`
3. Para reverter mudanças nos arquivos: `git checkout -- vimrc.local vimrc.bundles`
4. Para remover nvim completamente: `brew uninstall neovim && rm -rf ~/.config/nvim ~/.local/share/nvim`

---

## Fase 1: Instalar Neovim

```bash
brew install neovim
```

---

## Fase 2: Criar config do Neovim apontando para os arquivos existentes

Criar `~/.config/nvim/init.vim`:

```vim
set runtimepath^=~/.vim runtimepath+=~/.vim/after
let &packpath = &runtimepath
source ~/.vimrc
```

Isso faz o Neovim usar as mesmas configs do Vim, sem duplicação.

---

## Fase 3: Corrigir incompatibilidades

### 3.1 — Terminal title para tmux (`vimrc.local`)

Substituir o bloco atual de `t_ti`/`t_te` (linhas 77-79) por:

```vim
if exists('$TMUX')
  if has('nvim')
    let &titlestring = 'nvim'
    set title
  else
    let previous_title = substitute(system("tmux display-message -p '#{pane_title}'"), '\n', '', '')
    let &t_ti = "\<Esc>]2;vim\<Esc>\\" . &t_ti
    let &t_te = "\<Esc>]2;". previous_title . "\<Esc>\\" . &t_te
  endif

  " Navegação tmux (manter como está)
  nnoremap <silent> <C-h> :call TmuxOrSplitSwitch('h', 'L')<cr>
  nnoremap <silent> <C-j> :call TmuxOrSplitSwitch('j', 'D')<cr>
  nnoremap <silent> <C-k> :call TmuxOrSplitSwitch('k', 'U')<cr>
  nnoremap <silent> <C-l> :call TmuxOrSplitSwitch('l', 'R')<cr>
endif
```

### 3.2 — Trocar gundo por mundo (`vimrc.bundles`)

```vim
" De:
Plug 'sjl/gundo.vim'
" Para:
Plug 'simnalamburt/vim-mundo'
```

E no `vimrc.local`, trocar o mapping:

```vim
" De:
nnoremap <F5> :GundoToggle<CR>
" Para:
nnoremap <F5> :MundoToggle<CR>
```

### 3.3 — Remover Pathogen (`vimrc.local`)

Remover estas linhas:

```vim
execute pathogen#infect()
syntax on
filetype plugin indent on
```

O vim-plug já cuida do gerenciamento de plugins.

### 3.4 — (Opcional) Clipboard

```vim
" De:
set clipboard=unnamed
" Para:
set clipboard=unnamedplus
```

---

## Fase 4: Instalar plugins no Neovim

```bash
# Instalar vim-plug para Neovim
curl -fLo ~/.local/share/nvim/site/autoload/plug.vim --create-dirs \
  https://raw.githubusercontent.com/junegunn/vim-plug/master/plug.vim

# Instalar plugins
nvim +PlugInstall +qall
```

---

## Fase 5: Testar

- [ ] Abrir `nvim` e verificar plugins: `:PlugStatus`
- [ ] Navegação tmux com `C-h/j/k/l` entre panes
- [ ] vim-test: `<Leader>t` e `<Leader>s`
- [ ] VtrSendLinesToRunner: `<C-f>`
- [ ] fzf: `<leader>f` e `<leader>F`
- [ ] NERDTree: `C-n` e `<leader>rr`
- [ ] coc.nvim: abrir arquivo TypeScript e verificar autocomplete
- [ ] Mundo: `<F5>`
- [ ] Copiar paths: `<leader>cf`, `<leader>cl`
- [ ] Spell check desabilitado em markdown e gitcommit

---

## Fase 6: (Opcional) Alias gradual

Quando estiver confortável, adicionar ao `aliases.local`:

```bash
alias vim='nvim'
```

---

## Resumo do Rollback

| Cenário | Ação |
|---------|------|
| Algo não funciona no nvim | Usar `vim` — nada foi alterado |
| Reverter mudanças nos arquivos | `git checkout -- vimrc.local vimrc.bundles` |
| Remover nvim completamente | `brew uninstall neovim && rm -rf ~/.config/nvim ~/.local/share/nvim` |
