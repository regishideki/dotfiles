# New machine configuration
- install chrome, dropbox
- generate a ssh key to add to github (https://help.github.com/articles/generating-an-ssh-key)
- sudo apt-get install git vim docker docker-compose
- install vim with clipboard (for more details: http://vimcasts.org/blog/2013/11/getting-vim-with-clipboard-support/)
  - if in Ubuntu: apt-get install vim-gnome
  - if MacOS: brew install vim 
- install [vim-plug](https://github.com/junegunn/vim-plug) and [pathogen](https://github.com/tpope/vim-pathogen)
  - if MacOS install brew
- install rvm, tmux (funciona no 3.3a)
- install zsh + oh-my-zsh https://github.com/robbyrussell/oh-my-zsh and use zsh as default shell
- install https://github.com/sindresorhus/pure
- install https://github.com/jonmosco/kube-tmux to show kube context

- run init.sh to clone repositories
- use this repo to config other dotfiles(instructions on how to install rcm is in the section below)
  - take care when installing vim-plug. ~/.vim/autoload/plug.vim file must be readable without `sudo`
- install fzf and rg: https://medium.com/@crashybang/supercharge-vim-with-fzf-and-ripgrep-d4661fc853d2
- install ultisnips + vim-snippets

if in macOS, install
- https://robots.thoughtbot.com/tmux-copy-paste-on-os-x-a-better-future

- install and configure kubernetes

- remap caps lock (https://askubuntu.com/questions/177824/remapping-caps-lock-to-control-and-escape-not-the-usual-way/228379)
sudo apt-get install xcape
in zshrc.local there are already those lines of code:
/usr/bin/setxkbmap -option 'caps:ctrl_modifier'
/usr/bin/xcape -e 'Caps_Lock=Escape' -t 100
those commands will work this way: if you press Ctrl twice, it will act like Esc. If you hold, it will act like Ctrl:

install emacs
- install emacs-plus: https://github.com/d12frosted/homebrew-emacs-plus (last version installed = 27)
  - it will be installed on /usr/local/opt/emacs-plus@27
  - add the /bin folder to path:
    export PATH=$PATH:/usr/local/opt/emacs-plus@27
- install doom-emacs (there are some dependencies): https://github.com/d12frosted/homebrew-emacs-plus
  - add to the path:
    export PATH=$PATH:~/.emacs.d/bin
- if you want to use org-roam
  - install graphviz to see the graphs
    brew install graphviz

- Install copilot.vim plugin

thoughtbot dotfiles
===================

![prompt](http://images.thoughtbot.com/thoughtbot-dotfiles-prompt.png)

Requirements
------------

Set zsh as your login shell:

    chsh -s $(which zsh)

Install
-------

Clone onto your laptop:

    git clone git://github.com/thoughtbot/dotfiles.git ~/dotfiles

(Or, [fork and keep your fork
updated](http://robots.thoughtbot.com/keeping-a-github-fork-updated)).

Install [rcm](https://github.com/thoughtbot/rcm):

    brew tap thoughtbot/formulae
    brew install rcm

Install the dotfiles:

    env RCRC=$HOME/dotfiles/rcrc rcup

After the initial installation, you can run `rcup` without the one-time variable
`RCRC` being set (`rcup` will symlink the repo's `rcrc` to `~/.rcrc` for future
runs of `rcup`). [See
example](https://github.com/thoughtbot/dotfiles/blob/master/rcrc).

This command will create symlinks for config files in your home directory.
Setting the `RCRC` environment variable tells `rcup` to use standard
configuration options:

* Exclude the `README.md` and `LICENSE` files, which are part of
  the `dotfiles` repository but do not need to be symlinked in.
* Give precedence to personal overrides which by default are placed in
  `~/dotfiles-local`
* Please configure the `rcrc` file if you'd like to make personal
  overrides in a different directory

You can safely run `rcup` multiple times to update:

    rcup

You should run `rcup` after pulling a new version of the repository to symlink
any new files in the repository.

Make your own customizations
----------------------------

Create a directory for your personal customizations: 

    mkdir ~/dotfiles-local

Put your customizations in `~/dotfiles-local` appended with `.local`:

* `~/dotfiles-local/aliases.local`
* `~/dotfiles-local/git_template.local/*`
* `~/dotfiles-local/gitconfig.local`
* `~/dotfiles-local/psqlrc.local` (we supply a blank `.psqlrc.local` to prevent `psql` from
  throwing an error, but you should overwrite the file with your own copy)
* `~/dotfiles-local/tmux.conf.local`
* `~/dotfiles-local/vimrc.local`
* `~/dotfiles-local/vimrc.bundles.local`
* `~/dotfiles-local/zshrc.local`
* `~/dotfiles-local/zsh/configs/*`

For example, your `~/dotfiles-local/aliases.local` might look like this:

    # Productivity
    alias todo='$EDITOR ~/.todo'

Your `~/dotfiles-local/gitconfig.local` might look like this:

    [alias]
      l = log --pretty=colored
    [pretty]
      colored = format:%Cred%h%Creset %s %Cgreen(%cr) %C(bold blue)%an%Creset
    [user]
      name = Dan Croak
      email = dan@thoughtbot.com

Your `~/dotfiles-local/vimrc.local` might look like this:

    " Color scheme
    colorscheme github
    highlight NonText guibg=#060606
    highlight Folded  guibg=#0A0A0A guifg=#9090D0

If you don't wish to install a vim plugin from the default set of vim plugins in
`.vimrc.bundles`, you can ignore the plugin by calling it out with `UnPlug` in
your `~/.vimrc.bundles.local`.

    " Don't install vim-scripts/tComment
    UnPlug 'tComment'

`UnPlug` can be used to install your own fork of a plugin or to install a shared
plugin with different custom options.

    " Only load vim-coffee-script if a Coffeescript buffer is created
    UnPlug 'vim-coffee-script'
    Plug 'kchmck/vim-coffee-script', { 'for': 'coffee' }

    " Use a personal fork of vim-run-interactive
    UnPlug 'vim-run-interactive'
    Plug '$HOME/plugins/vim-run-interactive'

To extend your `git` hooks, create executable scripts in
`~/dotfiles-local/git_template.local/hooks/*` files.

Your `~/dotfiles-local/zshrc.local` might look like this:

    # load pyenv if available
    if which pyenv &>/dev/null ; then
      eval "$(pyenv init -)"
    fi

Your `~/dotfiles-local/vimrc.bundles.local` might look like this:

    Plug 'Lokaltog/vim-powerline'
    Plug 'stephenmckinney/vim-solarized-powerline'

zsh Configurations
------------------

Additional zsh configuration can go under the `~/dotfiles-local/zsh/configs` directory. This
has two special subdirectories: `pre` for files that must be loaded first, and
`post` for files that must be loaded last.

For example, `~/dotfiles-local/zsh/configs/pre/virtualenv` makes use of various shell
features which may be affected by your settings, so load it first:

    # Load the virtualenv wrapper
    . /usr/local/bin/virtualenvwrapper.sh

Setting a key binding can happen in `~/dotfiles-local/zsh/configs/keys`:

    # Grep anywhere with ^G
    bindkey -s '^G' ' | grep '

Some changes, like `chpwd`, must happen in `~/dotfiles-local/zsh/configs/post/chpwd`:

    # Show the entries in a directory whenever you cd in
    function chpwd {
      ls
    }

This directory is handy for combining dotfiles from multiple teams; one team
can add the `virtualenv` file, another `keys`, and a third `chpwd`.

The `~/dotfiles-local/zshrc.local` is loaded after `~/dotfiles-local/zsh/configs`.

vim Configurations
------------------

Similarly to the zsh configuration directory as described above, vim
automatically loads all files in the `~/dotfiles-local/vim/plugin` directory. This does not
have the same `pre` or `post` subdirectory support that our `zshrc` has.

This is an example `~/dotfiles-local/vim/plugin/c.vim`. It is loaded every time vim starts,
regardless of the file name:

    # Indent C programs according to BSD style(9)
    set cinoptions=:0,t0,+4,(4
    autocmd BufNewFile,BufRead *.[ch] setlocal sw=0 ts=8 noet

What's in it?
-------------

[vim](http://www.vim.org/) configuration:

* [Ctrl-P](https://github.com/kien/ctrlp.vim) for fuzzy file/buffer/tag finding.
* [Rails.vim](https://github.com/tpope/vim-rails) for enhanced navigation of
  Rails file structure via `gf` and `:A` (alternate), `:Rextract` partials,
  `:Rinvert` migrations, etc.
* Run many kinds of tests [from vim]([https://github.com/janko-m/vim-test)
* Set `<leader>` to a single space.
* Switch between the last two files with space-space.
* Syntax highlighting for Markdown, HTML, JavaScript, Ruby, Go, Elixir, more.
* Use [Ag](https://github.com/ggreer/the_silver_searcher) instead of Grep when
  available.
* Map `<leader>ct` to re-index [Exuberant Ctags](http://ctags.sourceforge.net/).
* Use [vim-mkdir](https://github.com/pbrisbin/vim-mkdir) for automatically
  creating non-existing directories before writing the buffer.
* Use [vim-plug](https://github.com/junegunn/vim-plug) to manage plugins.

[tmux](http://robots.thoughtbot.com/a-tmux-crash-course)
configuration:

* Improve color resolution.
* Remove administrative debris (session name, hostname, time) in status bar.
* Set prefix to `Ctrl+s`
* Soften status bar color from harsh green to light gray.

[git](http://git-scm.com/) configuration:

* Adds a `create-branch` alias to create feature branches.
* Adds a `delete-branch` alias to delete feature branches.
* Adds a `merge-branch` alias to merge feature branches into master.
* Adds an `up` alias to fetch and rebase `origin/master` into the feature
  branch. Use `git up -i` for interactive rebases.
* Adds `post-{checkout,commit,merge}` hooks to re-index your ctags.
* Adds `pre-commit` and `prepare-commit-msg` stubs that delegate to your local
  config.

[Ruby](https://www.ruby-lang.org/en/) configuration:

* Add trusted binstubs to the `PATH`.
* Load rbenv into the shell, adding shims onto our `PATH`.

Shell aliases and scripts:

* `b` for `bundle`.
* `g` with no arguments is `git status` and with arguments acts like `git`.
* `migrate` for `rake db:migrate && rake db:rollback && rake db:migrate`.
* `mcd` to make a directory and change into it.
* `replace foo bar **/*.rb` to find and replace within a given list of files.
* `tat` to attach to tmux session named the same as the current directory.
* `v` for `$VISUAL`.

Thanks
------

Thank you, [contributors](https://github.com/thoughtbot/dotfiles/contributors)!
Also, thank you to Corey Haines, Gary Bernhardt, and others for sharing your
dotfiles and other shell scripts from which we derived inspiration for items
in this project.

License
-------

dotfiles is copyright © 2009-2017 thoughtbot. It is free software, and may be
redistributed under the terms specified in the [`LICENSE`] file.

[`LICENSE`]: /LICENSE

About thoughtbot
----------------

![thoughtbot](http://presskit.thoughtbot.com/images/thoughtbot-logo-for-readmes.svg)

dotfiles is maintained and funded by thoughtbot, inc.
The names and logos for thoughtbot are trademarks of thoughtbot, inc.

We love open source software!
See [our other projects][community].
We are [available for hire][hire].

[community]: https://thoughtbot.com/community?utm_source=github
[hire]: https://thoughtbot.com/hire-us?utm_source=github
