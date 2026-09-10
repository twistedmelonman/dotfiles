# ~/.config/bash/prompt.sh
#shellcheck shell=bash
# Shell prompt configuration using liquidprompt

# Check if liquidprompt is installed via Homebrew
if [[ -f /opt/homebrew/share/liquidprompt ]]; then
  # Source liquidprompt
  # Configuration is loaded from ~/.config/liquidpromptrc
  # Not source=/opt/homebrew/share/liquidprompt: that path exists only on a
  # Homebrew Mac, so shellcheck resolves it here and fails on the Linux CI
  # runner, where the file is absent.
  # shellcheck source=/dev/null
  source /opt/homebrew/share/liquidprompt
else
  # Fallback to simple prompt if liquidprompt not installed
  # Define color codes
  COLOR_RESET="\[\033[00m\]"
  COLOR_RED="\[\033[31m\]"

  # Capture exit status in PROMPT_COMMAND
  _prompt_exit_status() {
    local exit_code=$?
    if [[ ${exit_code} -ne 0 ]]; then
      PROMPT_EXIT_CODE="${exit_code}"
    else
      PROMPT_EXIT_CODE=""
    fi
  }

  # Add to PROMPT_COMMAND
  PROMPT_COMMAND+=("_prompt_exit_status")

  # Simple fallback prompt: exit code in red, prompt symbol
  export PS1="${COLOR_RED}\${PROMPT_EXIT_CODE:+[\${PROMPT_EXIT_CODE}] }${COLOR_RESET}\$ "
fi
