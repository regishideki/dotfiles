!#sbin/sh

clone_from_projects() {
  workspace=$1
  shift
  github_user=$1
  shift
  projects=($@)

  cd $workspace

  echo "workspace: $workspace"
  echo "projects: $projects"
  echo "github_user: $github_user"

  for project in "${projects[@]}"
  do
    if [ -d "$workspace/$project" ]; then
      echo "Project $project already exists."
    else
      echo "cloning project $project."
      git clone "git@github.com:$github_user/$project.git"
    fi
  done
}

workspace=~/workspace
personal_workspace="$workspace/regis"

mkdir -p $personal_workspace

personal_projects=(programming-challenges presentations project_euler programming-languages)

personal_github="regishideki"

clone_from_projects $personal_workspace $personal_github $personal_projects
clone_from_projects ~/ $personal_github $config_projects

ln ~/dotfiles/zshrc.local $HOME/.zshrc.local
ln ~/dotfiles/ideavimrc $HOME/.ideavimrc
ln ~/dotfiles/genial_core/projections.json $HOME/workspace/genial/core/.projections.json

mkdir -p ~/.vim/autoload ~/.vim/bundle && \
  curl -LSso ~/.vim/autoload/pathogen.vim https://tpo.pe/pathogen.vim
mkdir -p ~/.vim/pythonx
ln ~/dotfiles/vim/pythonx/snippet_helpers.py ~/.vim/pythonx/snippet_helpers.py cd ~/dotfiles/
git clone https://github.com/easymotion/vim-easymotion ~/.vim/bundle

ln -s "$HOME/.vimrc" "$HOME/.ideavimrc"

# It is necessary to use Neoformat
yarn global add prettier

prettier_path=$(which prettier)
export PATH=$PATH:$prettier_path
