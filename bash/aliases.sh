# ~/.config/bash/aliases.sh
# shellcheck shell=bash

# File listing aliases (BSD ls)
alias ls='ls -AFGhl'
alias ll='ls'

# Common typo fixes
alias brwe='brew' # "I can't type" (as noted)

# Tool enhancements
alias batp='bat -p'
alias epoch='date +%s'
alias pbat='bat -p'
alias profile='source ${HOME}/.bash_profile'
alias ps='ps -efww'
alias rgall='rg -uuu'
alias rsync='rsync -avz'

# Force pipx for global package installation (use \pip3 to bypass)
alias pip='echo "Use pipx instead: pipx install <package>" && false'
alias pip3='pipx'

# System commands
alias softboot="osascript -e 'tell app \"System Events\" to restart'"

# Homebrew update alias (uses function from functions.sh)
alias brewup='_homebrew_update'

# Git shortcuts (optional - add your own)
alias gs='git status'
alias gl='git log --oneline'
alias gp='git pull'
alias gc='git commit -m'
alias my-prs='my_prs'       # open PRs across my orgs (functions.sh)
alias my-issues='my_issues' # open issues across my orgs (functions.sh)

# Exciting ways of launching Claude Code
if [[ -f "${HOME}/.local/bin/claude-wrapper" ]]; then
  alias claude='${HOME}/.local/bin/claude-wrapper'
  alias clauded="claude --dangerously-skip-permissions"
else
  alias claude='/usr/bin/caffeinate -i ${HOME}/.local/bin/claude'
  alias clauded="claude --dangerously-skip-permissions"
fi
alias suclaude='${HOME}/.local/bin/claude'
alias suclauded="suclaude --dangerously-skip-permissions"

# Add custom aliases below
# ------------------------
alias markdownlint='markdownlint --config ${HOME}/.markdownlint.json'
alias npx-markdownlint='npx markdownlint --config ${HOME}/.markdownlint.json'
alias diskspace='df -h /System/Volumes/Data'
alias dotall='dotfiles && dotclaude'
