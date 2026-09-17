#!/usr/bin/env bash
set -euo pipefail

# ~/Developer/dotfiles/install.sh
# Idempotent bootstrap script for a new macOS machine.
# Every step checks before acting — safe to re-run at any time.

# ── Formatting helpers ───────────────────────────────────
_info() { printf '\033[1;34m[INFO]\033[0m  %s\n' "$*"; }
_ok() { printf '\033[1;32m[OK]\033[0m    %s\n' "$*"; }
_warn() { printf '\033[1;33m[WARN]\033[0m  %s\n' "$*"; }
_err() { printf '\033[1;31m[ERR]\033[0m   %s\n' "$*" >&2; }
_skip() {
  printf '\033[0;90m[SKIP]\033[0m  %s\n' "$*"
  skipped+=("$*")
}
_dry() { printf '\033[1;35m[DRY]\033[0m   %s\n' "$*"; }

installed=()
skipped=()
manual=()
failures=()

# ── Parse arguments ──────────────────────────────────────
DRY_RUN=false
REPAIR_ONLY=false
SYNC_ONLY=false
for arg in "$@"; do
  case "${arg}" in
    --dry-run) DRY_RUN=true ;;
    --repair) REPAIR_ONLY=true ;;
    --sync) SYNC_ONLY=true ;;
    *)
      _err "Unknown argument: ${arg}"
      echo "Usage: install.sh [--dry-run] [--repair] [--sync]"
      exit 1
      ;;
  esac
done

if [[ "${REPAIR_ONLY}" == true && "${SYNC_ONLY}" == true ]]; then
  _err "--repair and --sync are mutually exclusive (--sync already repairs)"
  exit 1
fi

if [[ "${DRY_RUN}" == true ]]; then
  _info "Dry-run mode — no changes will be made"
fi

# ============================================================================
# 1. PRE-FLIGHT CHECKS
# ============================================================================

detected_os="$(uname -s)" || true
if [[ "${detected_os}" != "Darwin" ]]; then
  _err "This script is designed for macOS (Darwin). Detected: ${detected_os}"
  exit 1
fi

# CDPATH='' scopes out CDPATH for this one invocation so `cd` can never
# resolve via CDPATH search and echo the resolved path to stdout, which
# would otherwise corrupt this command substitution if the caller's shell
# has CDPATH exported and dirname's output happens to match a CDPATH
# entry by bare name (see smartwatermelon/dotfiles#176).
REPO_DIR="$(CDPATH='' cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# `git rev-parse --git-dir`, not `[[ -d .git ]]`. A linked worktree's .git is a
# FILE holding a `gitdir:` pointer, not a directory, so the -d test rejected a
# perfectly valid worktree as "not a git repository"
# (smartwatermelon/dotfiles#254). rev-parse resolves both forms and, unlike
# `-e`, confirms the entry actually resolves to a repository rather than just
# existing.
if ! git -C "${REPO_DIR}" rev-parse --git-dir >/dev/null 2>&1; then
  _err "Not a git repository: ${REPO_DIR}"
  _err "This script must be run from the dotfiles repo root."
  exit 1
fi

if [[ ! -f "${REPO_DIR}/git/config" ]]; then
  _err "Canary file missing: ${REPO_DIR}/git/config"
  exit 1
fi

if [[ ! -f "${REPO_DIR}/bash/main.sh" ]]; then
  _err "Canary file missing: ${REPO_DIR}/bash/main.sh"
  exit 1
fi

if [[ "${EUID}" -eq 0 ]]; then
  _err "Do not run this script as root."
  exit 1
fi

_ok "Pre-flight checks passed (macOS, git repo at ${REPO_DIR}, non-root)"

# ── Repair-only mode ─────────────────────────────────────
if ${REPAIR_ONLY}; then
  _info "Repair mode — checking symlinks only"
  # shellcheck source=git/hooks/lib-symlink-repair.sh
  source "${REPO_DIR}/git/hooks/lib-symlink-repair.sh"
  repair_config_symlinks false
  if [[ ${#SYMLINK_REPAIRS[@]} -eq 0 ]]; then
    _ok "All symlinks healthy — nothing to repair"
  else
    _ok "Repaired ${#SYMLINK_REPAIRS[@]} symlink(s)"
  fi
  exit 0
fi

# ============================================================================
# 2. HOMEBREW
# ============================================================================
# Skipped in --sync mode: sync reconciles the deployed tree with the repo
# (sections 3-4) and must stay fast enough to run on every `allup`. Package
# installation is bootstrap-only.

if ${SYNC_ONLY}; then
  _info "Sync mode — reconciling symlinks only (skipping package installation)"
elif command -v brew &>/dev/null; then
  _skip "Homebrew already installed"
else
  if [[ "${DRY_RUN}" == true ]]; then
    _dry "Would install Homebrew"
  else
    _info "Installing Homebrew..."
    # Let curl failure propagate — on a fresh machine, this IS fatal
    brew_installer="$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
    /bin/bash -c "${brew_installer}"
    # Ensure brew is on PATH for the rest of this script
    brew_env="$(/opt/homebrew/bin/brew shellenv 2>/dev/null || /usr/local/bin/brew shellenv 2>/dev/null)"
    eval "${brew_env}"
    installed+=("Homebrew")
  fi
fi

if ${SYNC_ONLY}; then
  :
elif [[ "${DRY_RUN}" == true ]]; then
  if ! command -v brew &>/dev/null; then
    _dry "Would verify Homebrew is on PATH (not currently available)"
  fi
elif ! command -v brew &>/dev/null; then
  _err "Homebrew is not available on PATH. Cannot continue."
  exit 1
fi

if ! ${SYNC_ONLY}; then
  _info "Running brew bundle..."
  if [[ "${DRY_RUN}" == true ]]; then
    _dry "Would run: brew bundle --file=${REPO_DIR}/Brewfile"
  elif brew bundle check --file="${REPO_DIR}/Brewfile" &>/dev/null; then
    _skip "All Brewfile packages already installed"
  else
    brew bundle --file="${REPO_DIR}/Brewfile"
    installed+=("Brewfile packages")
  fi
fi

# ============================================================================
# 3. CONFIG SYMLINKS (repo → ~/.config)
# ============================================================================

BACKUP_DIR="${HOME}/.config/backup"

_ensure_symlink() {
  local target="$1" link="$2"

  if [[ -L "${link}" ]]; then
    local current
    current="$(readlink "${link}")"
    if [[ "${current}" == "${target}" ]]; then
      _skip "Symlink already correct: ${link}"
      return
    fi
    _warn "Symlink ${link} points to ${current}, replacing"
  fi

  # Back up existing file/symlink if it exists and isn't the correct link
  if [[ -e "${link}" || -L "${link}" ]]; then
    mkdir -p "${BACKUP_DIR}"
    local backup_name
    # Include relative path in backup name to avoid collisions (e.g. git/config vs vim/config)
    backup_name="${link#"${HOME}/.config/"}"
    backup_name="${backup_name//\//_}.$(date +%Y%m%d%H%M%S)"
    mv "${link}" "${BACKUP_DIR}/${backup_name}"
    _warn "Backed up ${link} to ${BACKUP_DIR}/${backup_name}"
  fi

  ln -s "${target}" "${link}"
  _ok "Created symlink: ${link} -> ${target}"
  installed+=("symlink:${link}")
}

# Exclusion list is shared with the pre-commit repair hook — see
# git/hooks/lib-symlink-exclusions.sh. Defines _symlink_is_excluded().
# shellcheck source=git/hooks/lib-symlink-exclusions.sh
source "${REPO_DIR}/git/hooks/lib-symlink-exclusions.sh"

# Known config directories that should be symlinked into ~/.config.
# Any top-level path not in this list AND not excluded triggers a warning.
_KNOWN_CONFIG_DIRS="bash btop dig finicky gh git liquidpromptrc markdownlint-cli pre-commit s shellcheck tidy vim yamllint yt-dlp zizmor"

_is_known_config_path() {
  local top_level
  top_level="${1%%/*}"
  # Single-file at root (e.g., liquidpromptrc) — top_level equals the file
  for known in ${_KNOWN_CONFIG_DIRS}; do
    if [[ "${top_level}" == "${known}" ]]; then
      return 0
    fi
  done
  return 1
}

# In sync mode, run the repair pass first. _ensure_symlink would replace a
# clobbered regular file by backing it up, but repair_config_symlinks copies
# changed content back to the repo before restoring the link — preserving
# edits that atomic writes landed in ~/.config. Repair must therefore win.
if ${SYNC_ONLY} && [[ "${DRY_RUN}" != true ]]; then
  # shellcheck source=git/hooks/lib-symlink-repair.sh
  source "${REPO_DIR}/git/hooks/lib-symlink-repair.sh"
  repair_config_symlinks false
  if [[ ${#SYMLINK_REPAIRS[@]} -gt 0 ]]; then
    _ok "Repaired ${#SYMLINK_REPAIRS[@]} clobbered symlink(s)"
  fi
fi

_info "Creating config symlinks from repo to ~/.config..."

while IFS= read -r file; do
  if _symlink_is_excluded "${file}"; then
    continue
  fi

  # Safety net: warn about tracked files not in a known config directory
  if ! _is_known_config_path "${file}"; then
    _warn "Unrecognized config path: ${file} — add to _KNOWN_CONFIG_DIRS or git/hooks/lib-symlink-exclusions.sh"
    failures+=("unrecognized-path:${file}")
    continue
  fi

  link="${HOME}/.config/${file}"
  target="${REPO_DIR}/${file}"

  if [[ "${DRY_RUN}" == true ]]; then
    parent_dir="$(dirname "${link}")"
    if [[ ! -d "${parent_dir}" ]]; then
      _dry "Would create directory: ${parent_dir}"
    fi
    _dry "Would symlink: ${link} -> ${target}"
  else
    mkdir -p "$(dirname "${link}")"
    _ensure_symlink "${target}" "${link}"
  fi
done < <(git -C "${REPO_DIR}" ls-files)

# ============================================================================
# 3b. GENERATED CONFIGS
# ============================================================================
# finicky.js is generated per machine from finicky.template.js plus the
# Chrome PWAs installed here; a handler for a PWA that is missing would drop
# URLs. The generator restarts Finicky when the file changes, because
# Finicky's watcher does not survive the file being replaced.
#
# Ruling: the generator is an optional convenience, not a hard requirement —
# a failure leaves the previous finicky.js intact, so it must warn loudly
# but NOT enter failures (which would abort the rest of the sync for no gain).
_info "Generating Finicky config from installed Chrome PWAs..."
if [[ "${DRY_RUN}" == true ]]; then
  if ! bash "${REPO_DIR}/finicky/generate-config.sh" --dry-run; then
    _warn "Finicky config generation (dry-run) failed — see messages above"
  fi
elif bash "${REPO_DIR}/finicky/generate-config.sh"; then
  installed+=("generated:${HOME}/.config/finicky/finicky.js")
else
  _warn "Finicky config generation failed — see messages above"
fi

# ============================================================================
# 4. HOME SYMLINKS (~/.<file> → ~/.config/<path>)
# ============================================================================

if [[ "${DRY_RUN}" == true ]]; then
  _dry "Would symlink: ~/.bash_profile -> ~/.config/bash/.bash_profile"
  _dry "Would symlink: ~/.digrc -> ~/.config/dig/digrc"
  _dry "Would symlink: ~/.shellcheckrc -> ~/.config/shellcheck/.shellcheckrc"
  _dry "Would symlink: ~/.markdownlint.json -> ~/.config/markdownlint-cli/.markdownlint.json"
  _dry "Would create directory: ~/.local/bin"
  _dry "Would symlink: ~/.local/bin/gh -> ~/.config/bash/gh-wrapper.sh"
  _dry "Would symlink: ~/.local/bin/gpush -> ~/.config/bash/gpush-wrapper.sh"
else
  _ensure_symlink "${HOME}/.config/bash/.bash_profile" "${HOME}/.bash_profile"
  _ensure_symlink "${HOME}/.config/dig/digrc" "${HOME}/.digrc"
  _ensure_symlink "${HOME}/.config/shellcheck/.shellcheckrc" "${HOME}/.shellcheckrc"
  _ensure_symlink "${HOME}/.config/markdownlint-cli/.markdownlint.json" "${HOME}/.markdownlint.json"
  # ~/.local/bin must exist before this symlink is created; section 5
  # (CREATE DIRECTORIES) runs after this block, so it's created here instead.
  mkdir -p "${HOME}/.local/bin"
  _ensure_symlink "${HOME}/.config/bash/gh-wrapper.sh" "${HOME}/.local/bin/gh"
  _ensure_symlink "${HOME}/.config/bash/gpush-wrapper.sh" "${HOME}/.local/bin/gpush"
fi

# ── Sync-mode exit ───────────────────────────────────────
# Sections 3-4 above reconcile the deployed tree with the repo: they create
# symlinks for newly-pulled files (which --repair deliberately skips, since it
# only restores links clobbered into regular files) and repair existing ones.
# Everything below is bootstrap-only, so --sync stops here.
#
# Unlike the bootstrap summary, this exits non-zero on failures so that
# `allup`'s `|| return $?` actually surfaces an unrecognized config path.
if ${SYNC_ONLY}; then
  echo ""
  if [[ ${#installed[@]} -gt 0 ]]; then
    _info "Sync created:"
    for item in "${installed[@]}"; do
      echo "  + ${item}"
    done
  fi
  if [[ ${#failures[@]} -gt 0 ]]; then
    _warn "Sync completed with ${#failures[@]} issue(s):"
    for item in "${failures[@]}"; do
      echo "  ! ${item}"
    done
    exit 1
  fi
  if [[ ${#installed[@]} -eq 0 ]]; then
    _ok "Sync complete — deployed tree already matches repo"
  else
    _ok "Sync complete — ${#installed[@]} item(s) created"
  fi
  exit 0
fi

# ============================================================================
# 5. CREATE DIRECTORIES
# ============================================================================

dir="${HOME}/.local/state/bash"
if [[ -d "${dir}" ]]; then
  _skip "Directory exists: ${dir}"
elif [[ "${DRY_RUN}" == true ]]; then
  _dry "Would create directory: ${dir}"
else
  mkdir -p "${dir}"
  _ok "Created directory: ${dir}"
  installed+=("dir:${dir}")
fi

# ============================================================================
# 6. PIPX PACKAGES
# ============================================================================

if ! command -v pipx &>/dev/null; then
  _warn "pipx not found — skipping pipx packages"
  manual+=("Install pipx, then run: pipx install argcomplete")
else
  if pipx list --short 2>/dev/null | grep -q "^argcomplete "; then
    _skip "pipx package already installed: argcomplete"
  elif [[ "${DRY_RUN}" == true ]]; then
    _dry "Would install pipx package: argcomplete"
  else
    _info "Installing pipx package: argcomplete"
    pipx install argcomplete
    installed+=("pipx:argcomplete")
  fi
fi

# ============================================================================
# 7. NVM (Node Version Manager)
# ============================================================================

NVM_VERSION="v0.40.4"
if [[ -d "${HOME}/.nvm" ]]; then
  _skip "NVM already installed at ~/.nvm"
elif [[ "${DRY_RUN}" == true ]]; then
  _dry "Would install NVM ${NVM_VERSION}"
else
  _info "Installing NVM ${NVM_VERSION}..."
  nvm_installer="$(curl -fsSL "https://raw.githubusercontent.com/nvm-sh/nvm/${NVM_VERSION}/install.sh")"
  PROFILE=/dev/null bash -c "${nvm_installer}"
  if [[ ! -d "${HOME}/.nvm" ]]; then
    _warn "NVM installation may have failed — ~/.nvm not found"
    failures+=("nvm-install")
  else
    installed+=("NVM ${NVM_VERSION}")
  fi
fi

# ============================================================================
# 8. SECRETS STUB
# ============================================================================

SECRETS_FILE="${HOME}/.config/bash/secrets.sh"
if [[ -f "${SECRETS_FILE}" ]]; then
  _skip "Secrets file already exists: ${SECRETS_FILE}"
elif [[ "${DRY_RUN}" == true ]]; then
  _dry "Would create secrets stub: ${SECRETS_FILE}"
else
  cat >"${SECRETS_FILE}" <<'SECRETS_EOF'
# ~/.config/bash/secrets.sh
#shellcheck shell=bash
# This file is sourced by main.sh but EXCLUDED from git.
# Put API keys, tokens, and other secrets here.
# Example:
#   export GITHUB_TOKEN="ghp_..."
#   export OPENAI_API_KEY="sk-..."
SECRETS_EOF
  chmod 600 "${SECRETS_FILE}"
  _ok "Created secrets stub: ${SECRETS_FILE} (mode 600)"
  installed+=("secrets stub")
fi

# ============================================================================
# 9. POST-INSTALL SMOKE TEST
# ============================================================================

_info "Running smoke tests..."

# Check key commands exist
for cmd in git bash shellcheck shfmt pre-commit vim gh; do
  if command -v "${cmd}" &>/dev/null; then
    _ok "Found: ${cmd}"
  else
    _warn "Missing: ${cmd}"
    failures+=("${cmd}")
  fi
done

# Check bash version (need 5+)
bash_version="$(bash --version | head -1)"
if [[ "${bash_version}" == *"version 5"* || "${bash_version}" == *"version 6"* ]]; then
  _ok "Bash 5+ detected"
else
  _warn "Bash may not be 5+: ${bash_version}"
  failures+=("bash-version")
fi

# Check git hooks path
hooks_path="$(git config --global core.hooksPath 2>/dev/null || true)"
if [[ -n "${hooks_path}" ]]; then
  _ok "Git hooksPath configured: ${hooks_path}"
else
  _warn "Git core.hooksPath not set"
  failures+=("git-hooksPath")
fi

# Check per-machine work-identity gitconfig — only relevant if the work
# (Beacon) workdir exists but its includeIf target is missing, which would
# silently fall back to the personal git identity.
#
# bash/env.sh is the canonical definition of BEACON_WORKDIR, but install.sh
# never sources it (it configures the shell rather than running under it), so
# the default is spelled out here as a fallback. Keep the two in sync.
BEACON_WORKDIR="${BEACON_WORKDIR:-${HOME}/Developer/beacon-biosignals}"
BEACON_GITCONFIG="${HOME}/.gitconfig-beacon"
if [[ -d "${BEACON_WORKDIR}" ]]; then
  if [[ -f "${BEACON_GITCONFIG}" ]]; then
    _ok "Work-identity gitconfig present: ${BEACON_GITCONFIG}"
  else
    _warn "Missing ${BEACON_GITCONFIG} — ${BEACON_WORKDIR} repos will silently use your personal git identity"
    _warn "  Fix: cp ${REPO_DIR}/git/gitconfig-beacon.example ${BEACON_GITCONFIG} && edit the email"
    failures+=("beacon-gitconfig")
  fi
fi

# Check per-machine work (Beacon) bash env overrides — only relevant if the
# work workdir exists but env.sh's sourced target is missing, which would
# silently skip work-only env vars (e.g. AWS_PROFILE) with no warning.
BEACON_BASHENV="${HOME}/.config/bash/beacon.sh"
if [[ -d "${BEACON_WORKDIR}" ]]; then
  if [[ -f "${BEACON_BASHENV}" ]]; then
    _ok "Work bash env overrides present: ${BEACON_BASHENV}"
  else
    _warn "Missing ${BEACON_BASHENV} — work-only env vars (e.g. AWS_PROFILE) won't be set"
    _warn "  Fix: cp ${REPO_DIR}/bash/beacon.sh.example ${BEACON_BASHENV} && adjust as needed"
    failures+=("beacon-bashenv")
  fi
fi

# Symlink health check — verify all config symlinks resolve
if [[ "${DRY_RUN}" == true ]]; then
  _dry "Would verify config symlink health"
else
  _info "Checking config symlink health..."
  symlink_errors=0
  while IFS= read -r file; do
    if _symlink_is_excluded "${file}"; then
      continue
    fi
    if ! _is_known_config_path "${file}"; then
      continue
    fi
    link="${HOME}/.config/${file}"
    if [[ -L "${link}" ]]; then
      if [[ ! -e "${link}" ]]; then
        _warn "Broken symlink: ${link}"
        failures+=("broken-symlink:${link}")
        ((symlink_errors += 1))
      fi
    elif [[ -e "${link}" ]]; then
      _warn "Not a symlink (expected symlink): ${link}"
      failures+=("not-symlink:${link}")
      ((symlink_errors += 1))
    else
      _warn "Missing symlink: ${link}"
      failures+=("missing-symlink:${link}")
      ((symlink_errors += 1))
    fi
  done < <(git -C "${REPO_DIR}" ls-files)

  if [[ "${symlink_errors}" -eq 0 ]]; then
    _ok "All config symlinks healthy"
  fi
fi

# ============================================================================
# 10. SUMMARY
# ============================================================================

echo ""
echo "═══════════════════════════════════════════════════════"
echo " Bootstrap Summary"
echo "═══════════════════════════════════════════════════════"

if [[ ${#installed[@]} -gt 0 ]]; then
  _info "Installed/created:"
  for item in "${installed[@]}"; do
    echo "  + ${item}"
  done
fi

if [[ ${#skipped[@]} -gt 0 ]]; then
  echo ""
  _info "Skipped (already present):"
  for item in "${skipped[@]}"; do
    echo "  - ${item}"
  done
fi

if [[ ${#failures[@]} -gt 0 ]]; then
  echo ""
  _warn "Smoke test issues:"
  for item in "${failures[@]}"; do
    echo "  ! ${item}"
  done
fi

echo ""
echo "── Manual steps (cannot be automated) ──────────────"
echo "  1. Claude Code setup (~/.claude/ infrastructure)"
echo "  2. iTerm2 shell integration (Install Shell Integration from menu)"
echo "  3. source ~/.bash_profile   # activate the new shell config"

if [[ ${#manual[@]} -gt 0 ]]; then
  for item in "${manual[@]}"; do
    echo "  * ${item}"
  done
fi

echo ""
if [[ "${DRY_RUN}" == true ]]; then
  _info "Dry run complete — no changes were made"
elif [[ ${#failures[@]} -eq 0 ]]; then
  _ok "Bootstrap complete!"
else
  _warn "Bootstrap complete with ${#failures[@]} issue(s) — see above."
fi
