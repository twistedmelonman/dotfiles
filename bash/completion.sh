# ~/.config/bash/completion.sh
#shellcheck shell=bash
# Tab completion configuration

# Only run in interactive shells with readline support
if ! [[ -t 1 && "$-" == *i* && -n "${PS1:-}" ]]; then
  return
fi

# Basic tab completion settings (from previous .profile)
bind "set completion-ignore-case on"
bind "set completion-map-case on"
bind "set show-all-if-ambiguous on"
bind "set menu-complete-display-prefix on"

# Set up Homebrew completion (from current profile)
if command -v brew &>/dev/null; then
  # Use timeout to prevent indefinite hangs (3s should be enough)
  HOMEBREW_PREFIX="$(_with_timeout 3 brew --prefix 2>/dev/null)"
  _brew_exit=$?
  if [[ ${_brew_exit} -ne 0 || -z "${HOMEBREW_PREFIX}" ]]; then
    # Fallback to default location if brew --prefix fails or times out
    HOMEBREW_PREFIX="$(_get_homebrew_root)"
  fi
  unset _brew_exit

  # Main bash completion script
  if [[ -r "${HOMEBREW_PREFIX}/etc/profile.d/bash_completion.sh" ]]; then
    #shellcheck source=/dev/null
    source "${HOMEBREW_PREFIX}/etc/profile.d/bash_completion.sh"
  # Individual completion scripts
  elif [[ -d "${HOMEBREW_PREFIX}/etc/bash_completion.d" ]]; then
    for COMPLETION in "${HOMEBREW_PREFIX}/etc/bash_completion.d/"*; do
      #shellcheck source=/dev/null
      [[ -r "${COMPLETION}" ]] && source "${COMPLETION}"
    done
  fi

  # Brew completion (explicit load to ensure _brew function is available)
  if [[ -f "${HOMEBREW_PREFIX}/completions/bash/brew" ]]; then
    #shellcheck source=/dev/null
    source "${HOMEBREW_PREFIX}/completions/bash/brew"
  fi

  # Git completion (from previous .profile)
  if [[ -n "${HOMEBREW_GIT_PREFIX:-}" ]] && [[ -f "${HOMEBREW_GIT_PREFIX}/etc/bash_completion.d/git-completion.bash" ]]; then
    #shellcheck source=/dev/null
    source "${HOMEBREW_GIT_PREFIX}/etc/bash_completion.d/git-completion.bash"
  fi

  # Provide brew completion for cask alias/function
  # This allows 'cask install PACKAGE' to autocomplete like 'brew install --cask PACKAGE'
  if declare -f _brew &>/dev/null; then
    _cask_complete() {
      local line=${COMP_LINE}

      # Transform 'cask' command to 'brew' for completion
      COMP_LINE=${line/cask/brew}
      COMP_WORDS[0]=brew

      # Call brew's completion function
      _brew

      return 0
    }

    # Register completion function for cask
    complete -o bashdefault -o default -F _cask_complete cask
  fi
fi

# pipx completion
if command -v register-python-argcomplete &>/dev/null; then
  eval "$(register-python-argcomplete pipx)"
fi
