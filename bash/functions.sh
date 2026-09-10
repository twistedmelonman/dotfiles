# ~/.config/bash/functions.sh
#shellcheck shell=bash
# Shell functions

# Command-line entry point to pre-commit linter
lint() {
  local cfg="${HOME}/.config/pre-commit/config.yaml"

  # Check if config file exists
  if [[ ! -f "${cfg}" ]]; then
    echo "Error: Pre-commit config not found at ${cfg}" >&2
    return 1
  fi

  # Check if we're in a git repository
  local in_git_repo=false
  if git rev-parse --is-inside-work-tree &>/dev/null; then
    in_git_repo=true
  fi

  if [[ $# -eq 0 ]]; then
    # No arguments → run on all files
    if [[ "${in_git_repo}" == "true" ]]; then
      pre-commit run --all-files --config "${cfg}"
      return $?
    else
      echo "Error: --all-files requires being in a git repository" >&2
      echo "Usage: lint <file1> [file2] ... (specify files when outside git repo)" >&2
      return 1
    fi
  fi

  # Arguments given → expand globs and get absolute paths
  local files=()
  shopt -s nullglob globstar
  for f in "$@"; do
    # following ${f} should NOT be quoted (SC2066)
    for g in ${f}; do
      if [[ -f "${g}" ]]; then
        # Convert to absolute path to handle temp directory operations
        files+=("$(realpath "${g}")")
      fi
    done
  done
  shopt -u nullglob globstar

  if [[ ${#files[@]} -eq 0 ]]; then
    echo "No files matched the patterns: $*" >&2
    return 1
  fi

  if [[ "${in_git_repo}" == "true" ]]; then
    # In git repo - run directly
    pre-commit run --files "${files[@]}" --config "${cfg}"
    return $?
  else
    # Not in git repo - create temporary git repo
    local temp_dir
    temp_dir=$(mktemp -d)
    local result=0
    local original_dir
    original_dir=$(pwd)

    # Cleanup function
    # Use ${var:-} for set -u safety — locals are out of scope when EXIT trap fires
    cleanup_temp_repo() {
      cd "${original_dir:-}" 2>/dev/null || true
      rm -rf "${temp_dir:-}"
      trap - EXIT # Unset trap
    }
    trap cleanup_temp_repo EXIT

    # Initialize git repo in temp directory
    cd "${temp_dir}" || {
      echo "Error: Failed to enter temp directory" >&2
      return 1
    }

    git init --quiet || {
      echo "Error: Failed to initialize git repo" >&2
      return 1
    }

    # Configure git user (required for some hooks)
    git config user.name "lint-function"
    git config user.email "lint@example.com"

    # Copy files to temp repo and create relative path mapping
    local temp_files=()
    local file_mapping=()
    for file in "${files[@]}"; do
      local basename
      basename=$(basename "${file}")
      local temp_file="${temp_dir}/${basename}"

      # Handle filename conflicts by appending numbers
      local counter=1
      while [[ -f "${temp_file}" ]]; do
        local name="${basename%.*}"
        local ext="${basename##*.}"
        if [[ "${name}" == "${basename}" ]]; then
          # No extension
          temp_file="${temp_dir}/${basename}_${counter}"
        else
          temp_file="${temp_dir}/${name}_${counter}.${ext}"
        fi
        ((counter += 1))
      done

      cp -p "${file}" "${temp_file}" || {
        echo "Error: Failed to copy ${file}" >&2
        return 1
      }

      temp_files+=("$(basename "${temp_file}")")
      file_mapping+=("${temp_file}:${file}")
    done

    # Stage files (required by some hooks)
    git add .

    # Run pre-commit on the files
    pre-commit run --files "${temp_files[@]}" --config "${cfg}" || result=$?

    # Copy modified files back to original locations
    for mapping in "${file_mapping[@]}"; do
      local temp_file="${mapping%%:*}"
      local orig_file="${mapping##*:}"

      if [[ -f "${temp_file}" && "${temp_file}" -nt "${orig_file}" ]]; then
        echo "Copying fixes back to ${orig_file}"
        cp -p "${temp_file}" "${orig_file}"
      fi
    done

    # Cleanup and return to original directory
    cleanup_temp_repo
    return "${result}"
  fi
}
# Not exported - interactive command only

# Get Homebrew root based on installation location
_get_homebrew_root() {
  if [[ -d /opt/homebrew ]]; then
    echo "/opt/homebrew"
  else
    echo "/usr/local"
  fi
}
export -f _get_homebrew_root # Exported - may be used by subscripts

# Brew cask
cask() {
  brew "$@" --cask
}
# Not exported - interactive command only

# Remove quarantine attribute from files (macOS)
vax() {
  if [[ -z "$1" ]]; then
    echo "Usage: vax <file>" >&2
    return 1
  fi

  if [[ ! -e "$1" ]]; then
    echo "Error: File not found: $1" >&2
    return 1
  fi

  xattr -v -d com.apple.quarantine "$1"
}
# Not exported - interactive command only

# History search function
# Searches bash history for specified pattern(s)
hgrep() {
  local pattern="$1"

  if [[ -z "${pattern}" ]]; then
    echo "Usage: hgrep <pattern>"
    return 1
  fi

  # Use history command and pipe to grep with highlighting
  H="$(history)"
  grep --color=auto "${pattern}" <<<"${H}"
}
# Not exported - interactive command only

# Get name of parent script into variable
_what_is_this() {
  export THIS
  THIS=$(basename "${0}" 2>/dev/null || echo "script")
}
# Not exported - internal helper

# Send notification
_notif() {
  [[ -z "$1" ]] && return 0
  MSG="$1"
  _what_is_this

  # Always echo to terminal (important for seeing progress in output)
  echo "${THIS}: ${MSG}"

  # Also send desktop notification if tools available (skipped in SSH sessions)
  if command -v terminal-notifier &>/dev/null && command -v timeout &>/dev/null; then
    echo "${MSG}" | timeout 1 terminal-notifier -title "${THIS}" 2>/dev/null
  fi
}
# Not exported - internal helper

# Kill duplicate processes
# Safely kills other instances of a named process
# Usage: _kill_clones [process_name]
#   If no argument provided, uses ${THIS} from _what_is_this
_kill_clones() {
  local process_name="${1:-${THIS}}"
  local this_pid=$$

  # Safety check: refuse to kill critical system processes
  case "${process_name}" in
    bash | sh | zsh | fish | tcsh | csh | ksh | "" | "-bash" | "-sh" | "-zsh")
      echo "Error: _kill_clones refuses to kill shell processes: '${process_name}'" >&2
      return 1
      ;;
    *)
      # Process name is safe to kill
      ;;
  esac

  # Safety check: verify we're in a script context, not interactive shell
  if [[ "${process_name}" == "-"* ]] || [[ -z "${process_name}" ]]; then
    echo "Error: _kill_clones should only be used in scripts, not interactive shells" >&2
    return 1
  fi

  # Find and kill matching processes (excluding this one)
  local killed_count=0
  while IFS= read -r pid; do
    if [[ "${pid}" != "${this_pid}" ]] && [[ -n "${pid}" ]]; then
      _notif "killing ${pid}..."
      kill "${pid}" 2>/dev/null && ((killed_count += 1))
    fi
  done < <(pgrep -fl "${process_name}" | grep -v tail | awk '{print $1}' || true)

  if [[ ${killed_count} -gt 0 ]]; then
    _notif "Killed ${killed_count} clone(s) of ${process_name}"
  fi

  return 0
}
# Not exported - internal helper

# ============================================================================
# Package Manager Update Functions
# ============================================================================
# All update functions are exported to allow independent invocation
# (e.g., "_npm_update" to update only npm, "updates" to update all)
# Each function is self-sufficient: creates log directory, rotates log, handles errors

# Log rotation handled by logrotate (configured in /opt/homebrew/etc/logrotate.d/local-state-logs)
# Runs daily at 06:25 AM via launchd service (homebrew.mxcl.logrotate)

# Write update output to log file; also echo to terminal during interactive runs
# Prevents duplicate log entries when stdout is already redirected to the log
# (e.g. via LaunchAgent StandardOutPath)
_update_log() {
  if [[ -t 1 ]]; then
    tee -a "${HOME}/.local/state/updates.out"
  else
    cat >>"${HOME}/.local/state/updates.out"
  fi
}
# Not exported - internal helper

# Detect non-interactive invocation (e.g. LaunchAgent run overnight).
# In this mode, update functions must skip anything that would prompt for
# sudo / admin credentials / TouchID, since there's no user to respond and
# pam_tid surfaces a GUI dialog that pauses the whole run until login.
# Override with UPDATES_NONINTERACTIVE=1 to force this mode from a TTY
# (useful for testing), or UPDATES_NONINTERACTIVE=0 to force interactive.
_updates_noninteractive() {
  if [[ -n "${UPDATES_NONINTERACTIVE:-}" ]]; then
    [[ "${UPDATES_NONINTERACTIVE}" == "1" ]]
    return $?
  fi
  # No controlling TTY on stdin => LaunchAgent / cron / ssh-noninteractive
  [[ ! -t 0 ]]
}
# Not exported - internal helper

# Create a temporary directory containing a `sudo` shim that fails fast with
# a clear message instead of prompting. Echoes the directory path to stdout
# for the caller to prepend to PATH and to clean up when done.
# Intended for wrapping tools (e.g. `brew upgrade`) that invoke sudo for
# specific sub-operations (cask pkg installers) so those sub-operations
# fail individually while the rest of the run proceeds.
_updates_sudo_shim() {
  local shim_dir
  shim_dir=$(mktemp -d -t updates-sudo-shim) || return 1
  cat >"${shim_dir}/sudo" <<'SHIM'
#!/bin/bash
# Injected by _updates_sudo_shim during non-interactive `updates` run.
# Refuses to prompt the user; fails fast so the parent tool skips this op.
echo "sudo blocked (non-interactive updates): $*" >&2
exit 1
SHIM
  chmod +x "${shim_dir}/sudo" || {
    rm -rf "${shim_dir}"
    return 1
  }
  echo "${shim_dir}"
}
# Not exported - internal helper

# Cleanup helper for the sudo shim, invoked both on the normal path and via
# a TERM/INT trap so a killed process (e.g. LaunchAgent forcibly terminated)
# doesn't leave the temp dir behind. Takes the shim dir as $1 so it can be
# wired into `trap` with the value baked in at trap-set time.
_updates_shim_cleanup() {
  rm -rf "$1"
}
# Not exported - internal helper

# Update Homebrew packages
# Package managers provide their own network error diagnostics, so no pre-check needed
_homebrew_update() {
  local brew_prefix brew_owner my_id current_user
  brew_prefix="$(brew --prefix 2>/dev/null)" || { return 0; }
  brew_owner="$(stat -f '%u' "${brew_prefix}" 2>/dev/null)"
  my_id="$(id -u)"
  if [[ "${my_id}" != "${brew_owner}" ]]; then
    current_user="$(whoami)"
    _notif "Skipping Homebrew update: ${brew_prefix} is not owned by ${current_user}"
    return 0
  fi

  mkdir -p "${HOME}/.local/state" || return $?

  local timestamp output result
  timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

  _notif "Updating Homebrew..."
  # Note: tee failures are acceptable - output is shown to user even if logging fails
  echo "=== homebrew update ${timestamp} ===" | _update_log

  output=$(brew update --verbose 2>&1)
  result=$?
  echo "${output}" | _update_log
  if [[ "${result}" -ne 0 ]]; then
    _notif "brew update failed (exit ${result})"
    return "${result}"
  fi

  # Non-interactive mode (overnight LaunchAgent): upgrade formulae only and
  # defer ALL casks to the next interactive run. Casks such as tunnelblick
  # invoke `/usr/bin/sudo` by absolute path, which a PATH-based shim cannot
  # intercept; under pam_tid that surfaces a GUI TouchID prompt macOS defers
  # to unlock. Skipping casks removes that whole class of prompt. The sudo
  # shim is kept as defense-in-depth for a formula that shells out to a bare
  # `sudo`, and individual failures are tolerated so one bad formula does not
  # abort the unattended chain.
  local shim_dir=""
  local upgrade_path="${PATH}"
  local -a upgrade_args=(--verbose)
  local tolerate_upgrade_failure=false
  if _updates_noninteractive; then
    upgrade_args+=(--formula)
    tolerate_upgrade_failure=true
    shim_dir=$(_updates_sudo_shim) || shim_dir=""
    if [[ -n "${shim_dir}" ]]; then
      upgrade_path="${shim_dir}:${PATH}"
      # Normal-path cleanup happens after `brew upgrade` returns below, but
      # if this process is killed mid-run (e.g. LaunchAgent forcibly
      # terminated), that line never executes and the temp dir lingers.
      # Catch SIGTERM/SIGINT too, via the shared cleanup helper with the
      # shim dir path quoted into the trap command at set-time. Traps are
      # process-scoped (not function-scoped), so save whatever TERM/INT
      # handlers the caller already had and restore them on the cleanup
      # path below instead of unconditionally clearing to "default" —
      # this function may run inside an interactive shell or a parent
      # script with its own signal handling.
      local prev_term_trap prev_int_trap
      prev_term_trap=$(trap -p TERM)
      prev_int_trap=$(trap -p INT)
      local shim_trap_cmd
      printf -v shim_trap_cmd '_updates_shim_cleanup %q' "${shim_dir}"
      trap -- "${shim_trap_cmd}" TERM INT
    else
      _notif "Warning: sudo shim unavailable - a sudo-invoking formula may prompt"
    fi
    _notif "Non-interactive: upgrading formulae only; casks deferred to next interactive run"
  fi

  output=$(PATH="${upgrade_path}" brew upgrade "${upgrade_args[@]}" 2>&1)
  result=$?
  echo "${output}" | _update_log
  if [[ -n "${shim_dir}" ]]; then
    _updates_shim_cleanup "${shim_dir}"
    # Restore whatever TERM/INT handling was in place before we set ours,
    # rather than clearing to "default" (trap -p emits a ready-to-eval
    # `trap -- '...' SIG` command, or nothing if no handler was set).
    eval "${prev_term_trap:-trap - TERM}"
    eval "${prev_int_trap:-trap - INT}"
  fi
  if [[ "${result}" -ne 0 ]]; then
    if [[ "${tolerate_upgrade_failure}" == "true" ]]; then
      _notif "brew upgrade (formulae) completed with errors (exit ${result}) - check log"
    else
      _notif "brew upgrade failed (exit ${result})"
      return "${result}"
    fi
  fi

  output=$(brew cleanup --prune=all -s 2>&1)
  result=$?
  echo "${output}" | _update_log
  if [[ "${result}" -ne 0 ]]; then
    _notif "brew cleanup failed (exit ${result})"
    return "${result}"
  fi

  # brew doctor often returns non-zero for warnings; log but don't fail
  output=$(brew doctor 2>&1)
  result=$?
  echo "${output}" | _update_log
  if [[ "${result}" -eq 0 ]]; then
    _notif "Homebrew update completed successfully"
  else
    _notif "Homebrew update completed with warnings (check log)"
  fi

  return 0
}
# Not exported - internal helper

# Update global npm packages
# Returns 0 (success) if npm is not installed to allow graceful degradation
_npm_update() {
  if ! command -v npm &>/dev/null; then
    _notif "npm not found, skipping"
    return 0 # Not an error - npm is optional
  fi

  mkdir -p "${HOME}/.local/state" || return $?

  local timestamp output result
  timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

  _notif "Updating npm packages..."
  echo "=== npm update ${timestamp} ===" | _update_log

  output=$(npm update -g --verbose 2>&1)
  result=$?
  echo "${output}" | _update_log

  if [[ "${result}" -eq 0 ]]; then
    _notif "npm update completed"
  else
    _notif "npm update failed (exit ${result})"
  fi
  return "${result}"
}
# Not exported - internal helper

# Update pipx packages
# Returns 0 (success) if pipx is not installed to allow graceful degradation
_pipx_update() {
  if ! command -v pipx &>/dev/null; then
    _notif "pipx not found, skipping"
    return 0 # Not an error - pipx is optional
  fi

  mkdir -p "${HOME}/.local/state" || return $?

  local timestamp output result
  timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

  _notif "Updating pipx packages..."
  echo "=== pipx update ${timestamp} ===" | _update_log

  output=$(pipx upgrade-all --verbose 2>&1)
  result=$?
  echo "${output}" | _update_log

  if [[ "${result}" -eq 0 ]]; then
    _notif "pipx update completed"
  else
    _notif "pipx update failed (exit ${result})"
  fi
  return "${result}"
}
# Not exported - internal helper

# Update Ruby gems
# Returns 0 (success) if gem is not installed to allow graceful degradation
_gem_update() {
  if ! command -v gem &>/dev/null; then
    _notif "gem not found, skipping"
    return 0 # Not an error - gem is optional
  fi

  mkdir -p "${HOME}/.local/state" || return $?

  local timestamp output result
  timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

  _notif "Updating Ruby gems..."
  echo "=== gem update ${timestamp} ===" | _update_log

  # --no-document: Homebrew's rubygems plugin shim
  # (lib/ruby/gems/*/plugins/rdoc_plugin.rb) hardcodes the RDoc version shipped
  # with the ruby formula, so every gem process loads that RDoc at startup.
  # Doc generation then activates the newer rdoc from GEM_HOME, and the two
  # copies overwrite each other's constants in-process. Mismatched
  # RDoc::Markup::Formatter#initialize arity between the versions raises
  # ArgumentError and fails the whole update. Doc generation is the only path
  # that reaches the colliding code, so skipping it avoids the collision
  # regardless of which RDoc versions are installed. Regenerate on demand with
  # `gem rdoc <gemname>`.
  output=$(gem update --no-document --verbose 2>&1)
  result=$?
  echo "${output}" | _update_log

  if [[ "${result}" -ne 0 ]]; then
    _notif "gem update failed (exit ${result})"
    return "${result}"
  fi

  # gem cleanup is non-critical - warn on failure but don't fail overall
  output=$(gem cleanup --verbose 2>&1)
  local cleanup_result=$?
  echo "${output}" | _update_log

  if [[ "${cleanup_result}" -eq 0 ]]; then
    _notif "gem update and cleanup completed"
  else
    _notif "gem update succeeded, but cleanup failed (exit ${cleanup_result}) - check log"
  fi

  return 0 # Return success since update succeeded (cleanup failure is non-critical)
}
# Not exported - internal helper

# Update macOS system software
# Prompts for admin credentials via system dialog if needed
# Returns non-zero on failure (fail-fast)
_softwareupdate() {
  if ! command -v softwareupdate &>/dev/null; then
    _notif "softwareupdate not found, skipping"
    return 0 # Not an error - macOS-specific tool
  fi

  mkdir -p "${HOME}/.local/state" || return $?

  local timestamp output result
  timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

  _notif "Updating macOS system software..."
  echo "=== softwareupdate ${timestamp} ===" | _update_log

  # In non-interactive mode, any step beyond listing can prompt for admin
  # credentials — observed in the wild: `softwareupdate --download --all`
  # prompts when a system-scope update (e.g. a macOS point release) is in
  # the list, because the downloader stages it into a privileged location.
  # Only `-l` is truly admin-free. Log what's pending and defer both
  # download and install to the next interactive `updates` run.
  if _updates_noninteractive; then
    _notif "Non-interactive: listing pending updates only (download/install deferred)"
    output=$(softwareupdate -l 2>&1)
    echo "${output}" | _update_log
    return 0 # Don't fail the chain - install deferred by design
  fi

  # Run softwareupdate without sudo - it will prompt for admin credentials if needed
  # Use pipefail to capture exit code, run directly to preserve TTY for auth prompts
  (
    set -o pipefail
    softwareupdate -i -a 2>&1 | _update_log
  )
  result=$?

  if [[ "${result}" -ne 0 ]]; then
    _notif "softwareupdate failed (exit ${result})"
    return "${result}" # Fail-fast
  else
    _notif "softwareupdate completed"
    return 0
  fi
}
# Not exported - internal helper

# Update Mac App Store applications
# Returns 0 (success) if mas is not installed to allow graceful degradation
# Fails fast if mas upgrade fails (including authentication issues)
_mas_update() {
  if [[ "${MAS_UPDATE_DISABLE:-}" == "true" ]]; then
    _notif "skipping mas per MAS_UPDATE_DISABLE"
    return 0
  fi

  if ! command -v mas &>/dev/null; then
    _notif "mas not found, skipping"
    return 0 # Not an error - mas is optional
  fi

  mkdir -p "${HOME}/.local/state" || return $?

  local timestamp output result
  timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

  _notif "Updating Mac App Store apps..."
  echo "=== mas update ${timestamp} ===" | _update_log

  # In non-interactive mode, `mas upgrade` can hang waiting on a GUI App
  # Store authentication dialog on macOS versions where mas account/auth
  # still functions (mas account itself doesn't work on macOS 12+, but
  # upgrade's underlying auth prompt is a separate concern). Skip the
  # actual upgrade and defer to the next interactive `updates` run.
  if _updates_noninteractive; then
    _notif "Non-interactive: skipping mas upgrade (deferred to next interactive run)"
    echo "mas upgrade deferred - non-interactive mode" | _update_log
    return 0 # Don't fail the chain - upgrade deferred by design
  fi

  # Note: mas account doesn't work on macOS 12+
  # Let mas upgrade fail naturally if not authenticated
  output=$(mas upgrade 2>&1)
  result=$?
  echo "${output}" | _update_log

  if [[ "${result}" -ne 0 ]]; then
    _notif "mas upgrade failed (exit ${result}) - check App Store authentication"
    return "${result}" # Fail-fast
  else
    _notif "mas upgrade completed"
    return 0
  fi
}
# Not exported - internal helper

# Update Claude Code CLI
# Returns 0 (success) if claude is not installed to allow graceful degradation
# Respects DISABLE_AUTOUPDATER=1 in ~/.claude/settings.json
_claude_update() {
  # Bypass claude-wrapper (aliased over `claude` in interactive shells) —
  # `claude update` is a self-update of the binary and has no business
  # launching a full CCCLI session (and its 1Password secrets injection).
  local claude_bin="${HOME}/.local/bin/claude"
  if [[ ! -x "${claude_bin}" ]]; then
    _notif "claude not found, skipping"
    return 0 # Not an error - claude is optional
  fi

  # Check if autoupdater is disabled via settings
  local settings_file="${HOME}/.claude/settings.json"
  if [[ -f "${settings_file}" ]]; then
    if command -v jq &>/dev/null; then
      local disabled
      disabled=$(jq -r '.env.DISABLE_AUTOUPDATER // ""' "${settings_file}" 2>/dev/null)
      if [[ "${disabled}" == "1" ]]; then
        _notif "claude update disabled via settings, skipping"
        return 0
      fi
    else
      _notif "Warning: jq not installed, cannot check DISABLE_AUTOUPDATER setting"
    fi
  fi

  mkdir -p "${HOME}/.local/state" || return $?

  local timestamp binary_output binary_result
  timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

  _notif "Updating Claude Code..."
  echo "=== claude update ${timestamp} ===" | _update_log

  binary_output=$("${claude_bin}" update 2>&1)
  binary_result=$?
  echo "${binary_output}" | _update_log

  if [[ "${binary_result}" -eq 0 ]]; then
    _notif "claude update completed"
  else
    _notif "claude update failed (exit ${binary_result})"
    return "${binary_result}"
  fi

  # Update configured plugin marketplaces and enabled plugins.
  # Best-effort — failure here does not affect the binary update result.
  # Only enabled plugins are updated; disabled plugins are dead weight and
  # skipped to avoid churn on things that aren't in use.
  _notif "Updating Claude Code marketplaces..."
  local marketplace_output marketplace_result
  marketplace_output=$("${claude_bin}" plugin marketplace update 2>&1)
  marketplace_result=$?
  echo "${marketplace_output}" | _update_log
  if [[ "${marketplace_result}" -eq 0 ]]; then
    _notif "claude marketplace update completed"
  else
    _notif "claude marketplace update failed (exit ${marketplace_result})"
  fi

  if command -v jq &>/dev/null; then
    local plugin_list_json enabled_plugins
    plugin_list_json=$("${claude_bin}" plugin list --json 2>/dev/null)
    if [[ -n "${plugin_list_json}" ]]; then
      local enabled_plugins_raw
      enabled_plugins_raw=$(jq -r '.[] | select(.enabled == true) | .id' <<<"${plugin_list_json}" 2>/dev/null)
      enabled_plugins=()
      if [[ -n "${enabled_plugins_raw}" ]]; then
        mapfile -t enabled_plugins <<<"${enabled_plugins_raw}"
      fi
      if [[ "${#enabled_plugins[@]}" -gt 0 ]]; then
        _notif "Updating ${#enabled_plugins[@]} enabled Claude Code plugin(s)..."
        local plugin plugin_output plugin_result
        for plugin in "${enabled_plugins[@]}"; do
          plugin_output=$("${claude_bin}" plugin update "${plugin}" --yes 2>&1)
          plugin_result=$?
          echo "${plugin_output}" | _update_log
          if [[ "${plugin_result}" -eq 0 ]]; then
            _notif "  ${plugin} updated"
          else
            _notif "  ${plugin} update failed (exit ${plugin_result})"
          fi
        done
      fi
    else
      _notif "Warning: could not list Claude Code plugins, skipping plugin updates"
    fi
  else
    _notif "Warning: jq not installed, cannot enumerate enabled plugins to update"
  fi

  # Update git-sourced Claude Code components (skills, hooks, etc.)
  # Best-effort — failure here does not affect the binary update result.
  local tools_script="${HOME}/.claude/scripts/update-tools.sh"
  if [[ -x "${tools_script}" ]]; then
    _notif "Updating Claude Code tools..."
    local tools_output tools_result
    tools_output=$("${tools_script}" 2>&1)
    tools_result=$?
    echo "${tools_output}" | _update_log
    if [[ "${tools_result}" -eq 0 ]]; then
      _notif "claude tools update completed"
    else
      _notif "claude tools update failed (exit ${tools_result})"
    fi
  fi

  return "${binary_result}"
}
# Not exported - internal helper

# Orchestrate all system updates
# Each updater function is self-sufficient and creates its own log directory
# Records the failing step to a state file so `updates --continue` can resume
# after the user fixes the underlying problem, instead of re-running steps
# that already succeeded (e.g. brew update/upgrade before a broken gem dir).
# State file format: "<failed_step> <entrypoint>" where entrypoint is the
# command the user actually ran ("updates" or "allup"). The tag lets
# `allup --continue` tell whether the recorded failure came from its own run —
# without it, a bare `updates` failure would make the next `allup --continue`
# silently skip its repo pulls based on state it never wrote.
_UPDATES_STATE_FILE="${HOME}/.local/state/updates.progress"

# Echo the entrypoint recorded in the state file, or nothing if absent.
# Legacy state files (step only, no tag) yield an empty entrypoint, which
# callers treat as "not mine" — the conservative direction.
_updates_state_entrypoint() {
  [[ -f "${_UPDATES_STATE_FILE}" ]] || return 1
  local entrypoint
  entrypoint="$(awk 'NR==1{print $2}' "${_UPDATES_STATE_FILE}")"
  [[ -n "${entrypoint}" ]] || return 1
  printf '%s\n' "${entrypoint}"
}

# _UPDATES_ENTRYPOINT is set by allup so a failure is tagged with the command
# the user ran, not the inner function. Defaults to "updates".
updates() {
  local entrypoint="${_UPDATES_ENTRYPOINT:-updates}"
  local -a steps=(
    _homebrew_update
    _softwareupdate
    _mas_update
    _npm_update
    _pipx_update
    _gem_update
    _claude_update
  )
  local start_index=0

  if [[ -n "${1:-}" ]]; then
    if [[ "${1}" != "--continue" ]]; then
      _notif "Unknown option '${1}'; only --continue is supported"
      return 1
    fi

    if [[ -f "${_UPDATES_STATE_FILE}" ]]; then
      local last_failed i found=false
      # Field 1 is the step; field 2 (if present) is the entrypoint tag.
      last_failed="$(awk 'NR==1{print $1}' "${_UPDATES_STATE_FILE}")"
      for i in "${!steps[@]}"; do
        if [[ "${steps[i]}" == "${last_failed}" ]]; then
          start_index="${i}"
          found=true
          break
        fi
      done
      if [[ "${found}" == "true" ]]; then
        _notif "Resuming updates from ${last_failed}..."
      else
        _notif "State file references unknown step '${last_failed}'; running full updates"
      fi
    else
      _notif "No previous failure recorded; running full updates"
    fi

    # _homebrew_update defers casks to the next interactive run when the
    # prior invocation was non-interactive (e.g. the nightly LaunchAgent).
    # Skipping straight to a later step on --continue would silently drop
    # that catch-up forever, so always re-run it (idempotent, cheap) unless
    # it's already covered by the normal loop below.
    if ((start_index > 0)); then
      _notif "Re-running Homebrew update to pick up any casks deferred by a non-interactive run..."
      _homebrew_update || return $?
    fi
  fi

  _notif "Starting system updates..."

  local i step result
  for ((i = start_index; i < ${#steps[@]}; i++)); do
    step="${steps[i]}"
    "${step}"
    result=$?
    if [[ "${result}" -ne 0 ]]; then
      if ! mkdir -p "${HOME}/.local/state" || ! echo "${step} ${entrypoint}" >"${_UPDATES_STATE_FILE}"; then
        _notif "Warning: could not save resume state; '${entrypoint} --continue' will run from the start"
      fi
      _notif "updates stopped at ${step} (exit ${result}); fix the issue and run '${entrypoint} --continue'"
      return "${result}"
    fi
  done

  rm -f "${_UPDATES_STATE_FILE}"
  _notif "All updates completed successfully"
  return 0
}
# Not exported - interactive command only

# Update all local repos, repair local config symlinks, run software updates
# my-repos and beacon-repos are from ~/Developer/scripts, symlinked into ~/.local/bin
# `allup --continue` resumes after a failed step without re-running the
# network-bound repo pulls, which are the slow part. The two install.sh
# --sync calls always run: they are fast, idempotent, and are what installs
# files that the pulls brought in, so skipping them could leave the deployed
# tree stale for exactly the run that needed it.
#
# Pulls are skipped only when the recorded failure was tagged by allup. A
# state file left by a bare `updates` run is not ours to resume from, so we
# fall back to a full run rather than silently dropping the pulls.
allup() {
  local skip_pulls=false state_entrypoint

  if [[ -n "${1:-}" ]]; then
    if [[ "${1}" != "--continue" ]]; then
      _notif "Unknown option '${1}'; only --continue is supported"
      return 1
    fi

    state_entrypoint="$(_updates_state_entrypoint)" || state_entrypoint=""
    case "${state_entrypoint}" in
      allup)
        skip_pulls=true
        _notif "Resuming allup — skipping repo pulls (already done this cycle)"
        ;;
      "")
        _notif "No allup failure recorded; running full allup including pulls"
        ;;
      *)
        _notif "Recorded failure came from '${state_entrypoint}', not allup; running full allup including pulls"
        ;;
    esac
  fi

  if [[ "${skip_pulls}" != true ]]; then
    if command -v my-repos &>/dev/null; then my-repos || return $?; fi
    if command -v beacon-repos &>/dev/null; then beacon-repos || return $?; fi
  fi

  "${HOME}/Developer/dotfiles/install.sh" --sync || return $?
  "${HOME}/Developer/claude-config/install.sh" --sync || return $?
  # Refresh the calling shell's environment with whatever the two --sync
  # runs just deployed. allup is a function, not a script, so this affects
  # the interactive shell that invoked it rather than a subshell.
  #
  # Deliberately not `|| return $?`: .bash_profile's exit status is just
  # that of its last command (an nvm bash_completion probe), not a signal
  # that the environment loaded correctly. Gating on it would risk
  # skipping `updates` below after the pulls and installs had already run.
  #shellcheck source=/dev/null
  source "${HOME}/.bash_profile"

  _UPDATES_ENTRYPOINT=allup updates "$@"
}
# Not exported - interactive command only

# Where is a particular shell function declared?
# "where-func"
wf() {
  (
    shopt -s extdebug
    declare -F "$@"
  )
}
# Not exported

# Reinstall dotfiles and source profile in one step
dotfiles() {
  "${HOME}/Developer/dotfiles/install.sh" --sync || return $?
  source "${HOME}/.bash_profile"
}
# Not exported

# Extract compressed files (handles multiple formats)
extract() {
  if [[ -f "$1" ]]; then
    case "$1" in
      *.tar.bz2) tar xjf "$1" ;;
      *.tar.gz) tar xzf "$1" ;;
      *.tar.xz) tar xJf "$1" ;;
      *.bz2) bunzip2 "$1" ;;
      *.rar) unrar x "$1" ;;
      *.gz) gunzip "$1" ;;
      *.tar) tar xf "$1" ;;
      *.tbz2) tar xjf "$1" ;;
      *.tgz) tar xzf "$1" ;;
      *.zip) unzip "$1" ;;
      *.Z) uncompress "$1" ;;
      *.7z) 7z x "$1" ;;
      *) echo "'$1' cannot be extracted via extract()" ;;
    esac
  else
    echo "'$1' is not a valid file"
  fi
}

# Create a new directory and enter it
mkcd() {
  mkdir -p "$1" && cd "$1" || return
}
# Not exported - interactive command only

# Jump to git repository root
cdroot() {
  local root
  root=$(git rev-parse --show-toplevel 2>/dev/null)
  if [[ -n "${root}" ]]; then
    cd "${root}" || return
  else
    echo "Not in a git repository" >&2
    return 1
  fi
}
# Not exported - interactive command only

# Run a command; send all output (stdout+stderr) to the terminal and the clipboard
# Usage: pbrun <command> [args...]
# Streams output live when attached to a terminal; buffers otherwise. Returns
# the command's own exit status, not the pipeline's.
pbrun() {
  if [[ $# -eq 0 ]]; then
    echo "Usage: pbrun <command> [args...]" >&2
    return 1
  fi

  if ! command -v pbcopy &>/dev/null; then
    echo "pbcopy not found - pbrun requires macOS or a pbcopy shim" >&2
    return 1
  fi

  # A tty lets us stream: tee writes to the terminal while pbcopy consumes the
  # pipe, so pbcopy finishes before the pipeline returns and cannot race a
  # following pbpaste.
  #
  # `-t 1` alone is not enough: a process detached from its controlling
  # terminal (setsid, some daemons) can have a tty on stdout while /dev/tty
  # fails to open. `-w /dev/tty` does not cover that either -- it reports the
  # permission bits, which stay writable on a device that will not open, so it
  # returns true while `tee` dies with "Device not configured". Only an actual
  # open proves the redirect will work.
  if [[ -t 1 ]] && (: >/dev/tty) 2>/dev/null; then
    "$@" 2>&1 | tee /dev/tty | pbcopy
    return "${PIPESTATUS[0]}"
  fi

  # No terminal to stream to (piped, cron, script): buffer, then emit.
  #
  # Buffering through a file rather than $(...) keeps the two branches
  # byte-identical. Command substitution strips every trailing newline, so
  # re-adding exactly one with printf would make `pbrun printf 'a\n\n\n'` copy
  # one newline here and three when streaming, and would copy a lone newline
  # for a command that printed nothing. It also drops NUL bytes. For a
  # clipboard helper the exact bytes are the product, so preserve them.
  # The trap makes cleanup unconditional rather than dependent on reaching the
  # last line: an interrupt, a SIGPIPE from a closed downstream reader, or a
  # caller running under `set -e` can all leave the function early.
  local tmp rc
  tmp=$(mktemp) || return 1
  trap 'rm -f "${tmp}"' RETURN
  "$@" >"${tmp}" 2>&1
  rc=$?
  cat "${tmp}"
  pbcopy <"${tmp}"
  return "${rc}"
}
# Not exported - interactive command only

# Create and cd into a dated directory
mkdate() {
  local dir="${1:-$(date +%Y-%m-%d)}"
  mkdir -p "${dir}" && cd "${dir}" || return
}
# Not exported - interactive command only

# Toggle or set liquidprompt display mode
# Usage: lp_mode [single|multi|toggle]
# Default: toggle (when no argument provided)
lp_mode() {
  # Check if liquidprompt is loaded
  if ! type -t lp_theme &>/dev/null; then
    echo "Error: liquidprompt is not loaded" >&2
    return 1
  fi

  local mode="${1:-toggle}"

  case "${mode}" in
    single)
      LP_MARK_PREFIX=" "
      echo "Switched to single-line prompt"
      ;;
    multi | multiline)
      LP_MARK_PREFIX=$'\n'
      echo "Switched to multi-line prompt"
      ;;
    toggle)
      if [[ "${LP_MARK_PREFIX}" == " " ]]; then
        LP_MARK_PREFIX=$'\n'
        echo "Switched to multi-line prompt"
      else
        LP_MARK_PREFIX=" "
        echo "Switched to single-line prompt"
      fi
      ;;
    *)
      echo "Usage: lp_mode [single|multi|toggle]" >&2
      echo "  single   - Single-line prompt (default)" >&2
      echo "  multi    - Multi-line prompt ($ on own line)" >&2
      echo "  toggle   - Toggle between modes (default when no argument)" >&2
      return 1
      ;;
  esac
}
# Not exported - interactive command only

# ============================================================================
# Git Wrapper (post-init hook trigger)
# ============================================================================
# Canonical implementation lives in git-wrapper.sh (sourced below). See that
# file for why git, unlike gh, doesn't also get a standalone ~/.local/bin
# executable mode.

if [[ -f "${HOME}/.config/bash/git-wrapper.sh" ]]; then
  # shellcheck source=/dev/null
  source "${HOME}/.config/bash/git-wrapper.sh"
else
  echo "[git] WARNING: ${HOME}/.config/bash/git-wrapper.sh not found — git init post-checkout hook trigger is NOT active." >&2
  echo "[git] Run install.sh to restore it." >&2
fi

# ============================================================================
# GitHub CLI Wrapper
# ============================================================================
# Canonical implementation (including the identity auto-switch and the
# pre-merge review + REST/GraphQL merge-bypass blocking) lives in
# gh-wrapper.sh (sourced below), which also doubles as the standalone
# ~/.local/bin/gh wrapper when symlinked and executed directly. See that
# file for how the two modes interoperate.

if [[ -f "${HOME}/.config/bash/gh-wrapper.sh" ]]; then
  # shellcheck source=/dev/null
  source "${HOME}/.config/bash/gh-wrapper.sh"
else
  # Fail closed: a missing/broken symlink here (e.g. mid-install, or a
  # symlink-forest repair gone wrong) must not silently drop the
  # REST/GraphQL merge-bypass block and pre-merge review gate.
  echo "[gh] WARNING: ${HOME}/.config/bash/gh-wrapper.sh not found — gh merge guard is NOT active." >&2
  # install.sh --repair only re-links files that already exist as plain
  # copies; it skips paths that are missing entirely. A fully absent
  # gh-wrapper.sh needs the plain (non-repair) install.sh run.
  echo "[gh] Run install.sh to restore it." >&2
  gh() {
    echo "[gh] ERROR: gh-wrapper.sh is missing; refusing to run gh unguarded." >&2
    echo "[gh] Run install.sh to restore ${HOME}/.config/bash/gh-wrapper.sh." >&2
    return 1
  }
  export -f gh
fi

# ============================================================================
# gpush — push, PR, watch CI, confirm+merge
# ============================================================================
# Canonical implementation lives in gpush-wrapper.sh (sourced below), which
# also doubles as the standalone ~/.local/bin/gpush executable when
# symlinked and run directly. See that file for how the two modes work.

if [[ -f "${HOME}/.config/bash/gpush-wrapper.sh" ]]; then
  # shellcheck source=/dev/null
  source "${HOME}/.config/bash/gpush-wrapper.sh"
else
  echo "[gpush] WARNING: ${HOME}/.config/bash/gpush-wrapper.sh not found — gpush is unavailable." >&2
  echo "[gpush] Run install.sh to restore it." >&2
fi

# ============================================================================
# 1Password Helper
# ============================================================================
# opp — run op as personal account, bypassing the service account token.
# In interactive shells, OP_SERVICE_ACCOUNT_TOKEN is not set so this is
# equivalent to plain op. Inside CCCLI sessions (where the wrapper has set
# OP_SERVICE_ACCOUNT_TOKEN), this provides Personal vault access.
# Usage: opp <op-args> (e.g. `opp item list`); bare `opp` just runs `op`
# with no arguments, which prints op's own help text.

opp() {
  (
    unset OP_SERVICE_ACCOUNT_TOKEN
    if ! op whoami &>/dev/null; then
      local signin_cmd
      signin_cmd=$(op signin) || return $?
      eval "${signin_cmd}"
    fi
    op "$@"
  )
}
export -f opp # Exported - available inside CCCLI sessions
