# load custom executable functions
for function in ~/.zsh/functions/*; do
  source $function
done

# extra files in ~/.zsh/configs/pre , ~/.zsh/configs , and ~/.zsh/configs/post
# these are loaded first, second, and third, respectively.
_load_settings() {
  _dir="$1"
  if [ -d "$_dir" ]; then
    if [ -d "$_dir/pre" ]; then
      for config in "$_dir"/pre/**/*(N-.); do
        . $config
      done
    fi

    for config in "$_dir"/**/*(N-.); do
      case "$config" in
        "$_dir"/pre/*)
          :
          ;;
        "$_dir"/post/*)
          :
          ;;
        *)
          if [ -f $config ]; then
            . $config
          fi
          ;;
      esac
    done

    if [ -d "$_dir/post" ]; then
      for config in "$_dir"/post/**/*(N-.); do
        . $config
      done
    fi
  fi
}
_load_settings "$HOME/.zsh/configs"

_not_inside_tmux() { [[ -z "$TMUX" ]] }

ensure_tmux_is_running() {
  if _not_inside_tmux; then
    tat
  fi
}

ensure_tmux_is_running

# .zshrc
autoload -U promptinit; promptinit
prompt pure

# --files: List files that would be searched but do not search
# # --no-ignore: Do not respect .gitignore, etc...
# # --hidden: Search hidden files and folders
# # --follow: Follow symlinks
# # --glob: Additional conditions for search (in this case ignore everything in the .git/ folder)
export FZF_DEFAULT_COMMAND='rg --files --no-ignore --hidden --follow --glob "!.git/*"'

conflicted() {
  vim +Conflicted
}

# Local config
[[ -f ~/.zshrc.local ]] && source ~/.zshrc.local

export PATH="$PATH:$HOME/.rvm/bin" # Add RVM to PATH for scripting

# aliases
[[ -f ~/.aliases ]] && source ~/.aliases

[[ -s "$HOME/.rvm/scripts/rvm" ]] && . "$HOME/.rvm/scripts/rvm"

[ -f ~/.fzf.zsh ] && source ~/.fzf.zsh

autoload -U +X bashcompinit && bashcompinit
complete -o nospace -C /snap/vault/1822/bin/vault vault

#THIS MUST BE AT THE END OF THE FILE FOR SDKMAN TO WORK!!!
export SDKMAN_DIR="$HOME/.sdkman"
[[ -s "$HOME/.sdkman/bin/sdkman-init.sh" ]] && source "$HOME/.sdkman/bin/sdkman-init.sh"
export PATH="/opt/homebrew/opt/libpq/bin:$PATH"

PATH=~/.console-ninja/.bin:$PATH
# Added by Windsurf
export PATH="/Users/regishattori/.codeium/windsurf/bin:$PATH"
export PIPX_HOME="$HOME/.local/pipx"
export PIPX_BIN_DIR="$HOME/.local/bin"
export PATH="$HOME/.local/bin:$PATH"

# Added by Antigravity
export PATH="/Users/regishattori/.antigravity/antigravity/bin:$PATH"


