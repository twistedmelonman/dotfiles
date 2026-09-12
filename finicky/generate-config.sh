#!/usr/bin/env bash
# finicky/generate-config.sh
#
# Generates ~/.config/finicky/finicky.js from finicky.template.js plus the
# Chrome PWAs actually installed on this machine.
#
# Why generate at all (all verified with Finicky 4.2.2, 2026-09-01):
#   - A Finicky handler for an app that is not installed drops the URL —
#     Chrome opens nothing, and Finicky does not fall back to defaultBrowser.
#   - The config runs in goja with no filesystem access and cannot import a
#     second file, so it cannot discover installed apps itself.
#   - A config that fails to build makes Finicky send every URL to Safari.
#   - Finicky's file watcher dies when the config's inode is replaced (every
#     git pull did that while the file was a symlink into the repo), so a
#     changed config needs a Finicky restart to take effect.
#
# "Installed" means a shim exists in ~/Applications/Chrome Apps.localized —
# Chrome creates one per OS-integrated PWA and removes it on uninstall. The
# per-profile "Manifest Resources" dirs are NOT used for that decision: they
# also list Google's preinstalled apps in every profile. They are used only to
# choose the --profile-directory to launch with.
#
# Usage: generate-config.sh [--dry-run]
#
# Environment overrides (for tests and unusual layouts):
#   FINICKY_TEMPLATE     template path   (default: <this dir>/finicky.template.js)
#   FINICKY_OUTPUT       output path     (default: ~/.config/finicky/finicky.js)
#   CHROME_APPS_DIR      PWA shim dir    (default: ~/Applications/Chrome Apps.localized)
#   CHROME_PROFILE_ROOT  Chrome profiles (default: ~/Library/Application Support/Google/Chrome)
#   FINICKY_RESTART_CMD  command run after a changed install (default: restart Finicky if running)
set -euo pipefail
unset CDPATH

_gen_info() { printf '[finicky] %s\n' "$*"; }
_gen_warn() { printf '[finicky] WARN: %s\n' "$*" >&2; }
_gen_err() { printf '[finicky] ERROR: %s\n' "$*" >&2; }

MARKER='const INSTALLED_PWAS = {}; // @@INSTALLED_PWAS@@'

# Reads one string key from a shim's Info.plist. Prints nothing on failure.
_plist_string() {
  local key="$1" plist="$2"
  plutil -extract "${key}" raw -o - "${plist}" 2>/dev/null || true
}

# Picks the Chrome profile directory that has this app installed.
# Prefers Default; otherwise the first match in sorted order; otherwise
# Default with a warning (the launch will then fail, but loudly in the log).
_profile_for_app() {
  local app_id="$1" profile_root="$2" dir
  if [[ -d "${profile_root}/Default/Web Applications/Manifest Resources/${app_id}" ]]; then
    printf 'Default'
    return 0
  fi
  for dir in "${profile_root}"/*/; do
    dir="${dir%/}"
    if [[ -d "${dir}/Web Applications/Manifest Resources/${app_id}" ]]; then
      printf '%s' "$(basename "${dir}")"
      return 0
    fi
  done
  _gen_warn "app ${app_id} has a shim but no Chrome profile lists it; assuming Default"
  printf 'Default'
}

# finicky_scan_pwas <apps_dir> <profile_root>
# Emits "appId<TAB>name<TAB>profileDir" per installed PWA, sorted by appId.
finicky_scan_pwas() {
  local apps_dir="$1" profile_root="$2" shim plist app_id name profile
  [[ -d "${apps_dir}" ]] || return 0
  for shim in "${apps_dir}"/*.app; do
    [[ -d "${shim}" ]] || continue
    plist="${shim}/Contents/Info.plist"
    [[ -f "${plist}" ]] || continue
    app_id="$(_plist_string CrAppModeShortcutID "${plist}")"
    [[ -n "${app_id}" ]] || continue
    name="$(_plist_string CrAppModeShortcutName "${plist}")"
    [[ -n "${name}" ]] || name="$(basename "${shim}" .app)"
    profile="$(_profile_for_app "${app_id}" "${profile_root}")"
    printf '%s\t%s\t%s\n' "${app_id}" "${name}" "${profile}"
  done | LC_ALL=C sort
}

# finicky_catalog_ids <template_path>
# Emits the app ids keyed in the template's CATALOG block, one per line.
# Chrome app ids are exactly 32 characters from a-p, which is strict enough to
# skip commented-out entries and the block's own punctuation. Prints nothing
# when the template has no CATALOG block.
finicky_catalog_ids() {
  local template="$1"
  [[ -f "${template}" ]] || return 0
  awk '
    /^const CATALOG = \{/ { inblock = 1; next }
    inblock && /^\};/     { inblock = 0 }
    inblock && match($0, /[a-p]{32}/) {
      # Re-anchor: only a bare or quoted key at the start of the line counts,
      # so a commented-out entry and any id inside a hostname are skipped.
      if ($0 ~ /^[[:space:]]*"?[a-p]{32}"?:/) {
        print substr($0, RSTART, RLENGTH)
      }
    }
  ' "${template}"
}

# finicky_check_catalog <template_path> <scan_lines>
# Warns for every CATALOG entry with no matching installed PWA. Such an entry
# is dropped by the template's filter, so its hostnames quietly fall through
# to defaultBrowser instead of opening the app — a failure with no other
# diagnostic. Prints a count summary when the template has a CATALOG block.
finicky_check_catalog() {
  local template="$1" scan="$2" ids id total=0 active=0
  ids="$(finicky_catalog_ids "${template}")"
  [[ -n "${ids}" ]] || return 0
  while IFS= read -r id; do
    [[ -n "${id}" ]] || continue
    ((total += 1))
    if [[ -n "${scan}" ]] && grep -q "^${id}	" <<<"${scan}"; then
      ((active += 1))
    else
      _gen_warn "CATALOG entry ${id} has no installed PWA; its hostnames fall through to defaultBrowser"
    fi
  done <<<"${ids}"
  _gen_info "CATALOG entries: ${total}, active handlers: ${active}"
}

# Escapes a value for use inside a double-quoted JSON string.
_json_escape() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  printf '%s' "${s}"
}

# finicky_render <template_path> <scan_lines>
# Prints the template with the marker line replaced by the installed-app
# literal and a GENERATED header prepended. Fails unless exactly one marker.
finicky_render() {
  local template="$1" scan="$2" count literal="" app_id name profile sep=""
  local esc_id esc_name esc_profile
  [[ -f "${template}" ]] || {
    _gen_err "template not found: ${template}"
    return 1
  }
  count="$(RENDER_MARKER="${MARKER}" awk '$0 == ENVIRON["RENDER_MARKER"] { n += 1 } END { print n + 0 }' "${template}")"
  if [[ "${count}" -ne 1 ]]; then
    _gen_err "expected exactly one marker line in ${template}, found ${count}: ${MARKER}"
    return 1
  fi
  if [[ -n "${scan}" ]]; then
    while IFS=$'\t' read -r app_id name profile; do
      [[ -n "${app_id}" ]] || continue
      esc_id="$(_json_escape "${app_id}")"
      esc_name="$(_json_escape "${name}")"
      esc_profile="$(_json_escape "${profile}")"
      literal+="${sep}\"${esc_id}\": {\"name\": \"${esc_name}\", \"profile\": \"${esc_profile}\"}"
      sep=", "
    done <<<"${scan}"
  fi
  local out
  out="$(
    printf '// GENERATED by finicky/generate-config.sh from %s — do not edit.\n' "$(basename "${template}")"
    printf '// Re-run install.sh --sync (or the generator) after installing or removing a Chrome PWA.\n'
    # awk with -v would reinterpret backslashes in the literal; pass via ENVIRON.
    RENDER_MARKER="${MARKER}" RENDER_LITERAL="const INSTALLED_PWAS = {${literal}};" \
      awk '$0 == ENVIRON["RENDER_MARKER"] { print ENVIRON["RENDER_LITERAL"]; next } { print }' "${template}"
  )"
  # Belt and braces: the count above already guarantees exactly one exact
  # marker line, but if that ever regresses, refuse to install a config
  # that still contains the raw marker instead of silently shipping it.
  if grep -qF -- "@@INSTALLED_PWAS@@" <<<"${out}"; then
    _gen_err "rendered output still contains @@INSTALLED_PWAS@@ after substitution"
    return 1
  fi
  printf '%s\n' "${out}"
}

# Validates a rendered config with node when available. The rendered file
# is an ES module, so it is checked under an .mjs name.
_validate_rendered() {
  local rendered="$1" tmp_dir tmp_mjs
  if ! command -v node >/dev/null 2>&1; then
    _gen_warn "node not on PATH; skipping syntax check of rendered config"
    return 0
  fi
  tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/finicky-check.XXXXXX")"
  tmp_mjs="${tmp_dir}/rendered.mjs"
  cp "${rendered}" "${tmp_mjs}"
  if node --check "${tmp_mjs}"; then
    rm -rf "${tmp_dir}"
    return 0
  fi
  rm -rf "${tmp_dir}"
  return 1
}

# Default restart: only if Finicky is running. `open -g` keeps it in the
# background. Finicky's watcher does not survive an inode replacement, so a
# restart is the only reliable way for a changed config to take effect.
#
# `pkill` returns as soon as the signal is sent, not when the process has
# actually exited, and a single-instance app's `open -g -a Finicky` against
# a still-terminating instance just activates the dying one and returns 0 —
# so neither a fixed `sleep` nor `open`'s exit status can be trusted to know
# when it's safe to relaunch, or whether the relaunch actually took. Poll
# pgrep in both directions instead.
_default_restart() {
  pgrep -x Finicky >/dev/null 2>&1 || return 0

  pkill -x Finicky || true
  local waited=0
  while pgrep -x Finicky >/dev/null 2>&1; do
    if ((waited >= 50)); then
      _gen_warn "Finicky did not exit after 10s; leaving it stopped, start it by hand"
      return 0
    fi
    sleep 0.2
    ((waited += 1))
  done

  if ! open -g -a Finicky; then
    _gen_warn "could not relaunch Finicky; start it by hand"
    return 0
  fi

  waited=0
  while ! pgrep -x Finicky >/dev/null 2>&1; do
    if ((waited >= 25)); then
      _gen_warn "Finicky was stopped but did not come back; start it by hand"
      return 0
    fi
    sleep 0.2
    ((waited += 1))
  done
  _gen_info "restarted Finicky so it reads the new config"
}

main() {
  local dry_run=false arg
  for arg in "$@"; do
    case "${arg}" in
      --dry-run) dry_run=true ;;
      *)
        _gen_err "unknown argument: ${arg}"
        return 1
        ;;
    esac
  done

  local script_dir template output apps_dir profile_root
  script_dir="$(CDPATH='' cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  template="${FINICKY_TEMPLATE:-${script_dir}/finicky.template.js}"
  output="${FINICKY_OUTPUT:-${HOME}/.config/finicky/finicky.js}"
  apps_dir="${CHROME_APPS_DIR:-${HOME}/Applications/Chrome Apps.localized}"
  profile_root="${CHROME_PROFILE_ROOT:-${HOME}/Library/Application Support/Google/Chrome}"

  local scan rendered
  scan="$(finicky_scan_pwas "${apps_dir}" "${profile_root}")"
  # Before rendering, so an orphaned CATALOG entry is reported on --dry-run
  # and on the unchanged-config early return as well as on a real install.
  finicky_check_catalog "${template}" "${scan}"
  rendered="$(mktemp "${TMPDIR:-/tmp}/finicky-render.XXXXXX")"
  if ! finicky_render "${template}" "${scan}" >"${rendered}"; then
    rm -f "${rendered}"
    return 1
  fi
  if ! _validate_rendered "${rendered}"; then
    _gen_err "rendered config failed syntax check; leaving ${output} untouched"
    rm -f "${rendered}"
    return 1
  fi

  local count=0
  [[ -n "${scan}" ]] && count="$(wc -l <<<"${scan}" | tr -d ' ')"
  _gen_info "installed PWAs found: ${count}"

  # A symlink here is the pre-generator deployment (finicky.js used to be
  # tracked and linked into place). Its target was renamed, so it dangles.
  # Compare against whatever the symlink resolves to (nothing, if dangling)
  # so a symlink to already-correct content is still treated as unchanged.
  # Deliberately keeps an already-correct symlink in place instead of
  # replacing it (spec says remove); this avoids a needless Finicky restart,
  # and the state is unreachable in practice anyway.
  if [[ -L "${output}" ]]; then
    if [[ -f "${output}" ]] && cmp -s "${rendered}" "${output}"; then
      _gen_info "unchanged: ${output}"
      rm -f "${rendered}"
      return 0
    fi
    if ${dry_run}; then
      _gen_info "would remove symlink: ${output}"
    else
      rm -f "${output}"
      _gen_info "removed symlink: ${output}"
    fi
  elif [[ -f "${output}" ]] && cmp -s "${rendered}" "${output}"; then
    _gen_info "unchanged: ${output}"
    rm -f "${rendered}"
    return 0
  fi

  if ${dry_run}; then
    _gen_info "would install: ${output}"
    rm -f "${rendered}"
    return 0
  fi

  mkdir -p "$(dirname "${output}")"
  chmod 0644 "${rendered}"
  mv "${rendered}" "${output}"
  _gen_info "installed: ${output}"

  if [[ -n "${FINICKY_RESTART_CMD:-}" ]]; then
    bash -c "${FINICKY_RESTART_CMD}" || _gen_warn "restart command failed: ${FINICKY_RESTART_CMD}"
  else
    _default_restart
  fi
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
