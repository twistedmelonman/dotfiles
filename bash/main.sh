# ~/.config/bash/main.sh
#shellcheck shell=bash
# Main configuration file that sources all other modules

# Define base directory for configuration
export BASH_CONFIG_DIR="${HOME}/.config/bash"

# Load functions FIRST (needed by other modules)
if [[ -f "${BASH_CONFIG_DIR}/functions.sh" ]]; then
  source "${BASH_CONFIG_DIR}/functions.sh"
fi

# Load environment variables (depends on functions only)
# NOTE: env.sh no longer touches PATH — it filters PATH/MANPATH/INFOPATH
# out of the brew shellenv eval. path.sh is the sole PATH owner and does
# not depend on load order relative to env.sh.
if [[ -f "${BASH_CONFIG_DIR}/env.sh" ]]; then
  source "${BASH_CONFIG_DIR}/env.sh"
fi

# Load PATH configuration (depends on functions only)
if [[ -f "${BASH_CONFIG_DIR}/path.sh" ]]; then
  source "${BASH_CONFIG_DIR}/path.sh"
fi

# Load service management (depends on functions, env, and path)
if [[ -f "${BASH_CONFIG_DIR}/services.sh" ]]; then
  source "${BASH_CONFIG_DIR}/services.sh"
fi

# Load completion settings
if [[ -f "${BASH_CONFIG_DIR}/completion.sh" ]]; then
  source "${BASH_CONFIG_DIR}/completion.sh"
fi

# Load history settings
if [[ -f "${BASH_CONFIG_DIR}/history.sh" ]]; then
  source "${BASH_CONFIG_DIR}/history.sh"
fi

# Load aliases
if [[ -f "${BASH_CONFIG_DIR}/aliases.sh" ]]; then
  source "${BASH_CONFIG_DIR}/aliases.sh"
fi

# Load prompt (after functions for git integration)
if [[ -f "${BASH_CONFIG_DIR}/prompt.sh" ]]; then
  source "${BASH_CONFIG_DIR}/prompt.sh"
fi

# Additional custom configuration can be placed in this block
# -------------------------------------------------------------

# Enable case-insensitive globbing
shopt -s nocaseglob

# Correct simple directory spelling errors when using cd
shopt -s cdspell

# direnv (must load after prompt.sh, since it wraps PROMPT_COMMAND)
if command -v direnv &>/dev/null; then
  eval "$(direnv hook bash)"
fi

# iTerm2 shell integration (must load last: it appends itself to
# PROMPT_COMMAND and installs a DEBUG trap, and its own notes ask to be the
# last pre-existing PROMPT_COMMAND entry). It self-guards on $- and TERM, so
# no interactive test is needed here. iTerm2's installer writes this file to
# ${HOME} — NOT to ${HOME}/.iterm2/, which holds only the imgcat/it2* tools.
#shellcheck source=/dev/null
test -e "${HOME}/.iterm2_shell_integration.bash" \
  && source "${HOME}/.iterm2_shell_integration.bash"

# End of custom configuration

# Print startup message (comment out if not desired)
# echo "Bash configuration loaded from ${BASH_CONFIG_DIR}"
