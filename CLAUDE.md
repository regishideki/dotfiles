# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

This is a personal dotfiles repository based on thoughtbot's dotfiles, managed with [rcm](https://github.com/thoughtbot/rcm). The repository contains configuration files for zsh, vim, tmux, git, and various development tools.

## Installation and Management

```bash
# Initial installation (sets up symlinks from repo to home directory)
env RCRC=$HOME/dotfiles/rcrc rcup

# Update symlinks after adding new files
rcup

# Initialize workspace and clone personal projects
./init.sh
```

## Architecture

**rcm-based structure**: Files in this repo are symlinked to `~/.<filename>` by rcm. The `rcrc` file configures which files to exclude and sets `~/dotfiles-local` as the override directory.

**Configuration loading order**:
- Base configs from `~/dotfiles/` are loaded first
- Local overrides from `~/dotfiles-local/` take precedence
- Files ending in `.local` (e.g., `zshrc.local`, `gitconfig.local`) contain machine-specific customizations

**zsh configuration hierarchy**:
1. Functions from `~/.zsh/functions/`
2. Configs from `~/.zsh/configs/pre/`
3. Configs from `~/.zsh/configs/`
4. Configs from `~/.zsh/configs/post/`
5. `~/.zshrc.local`
6. `~/.aliases`

**Key directories**:
- `bin/` - Custom git commands and utilities (git-create-branch, git-delete-branch, tat, etc.)
- `zsh/` - Shell functions, completions, and config modules
- `vim/` - Filetype plugins and vim utilities
- `git_template/` - Git hooks for ctags regeneration

## Useful Aliases

- `g` - git status (no args) or git command (with args)
- `b` - bundle
- `k` - kubectl
- `gs` - git status
- `sz` - source ~/.zshrc
- `aliases` - edit aliases.local
- `gitconfig` - edit gitconfig.local
