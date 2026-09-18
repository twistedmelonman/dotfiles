#!/usr/bin/env bash
# YAML lint wrapper for the `yamllint` pre-commit hook.
#
# Resolves the config the way CI does (standards/run-standards.sh:147-150):
#
#   cfg=""
#   for c in .yamllint .yamllint.yml .yamllint.yaml; do
#     if [[ -f "${repo}/${c}" ]]; then cfg="${repo}/${c}"; break; fi
#   done
#   [[ -n "${cfg}" ]] || cfg="${config_dir}/yamllint.yml"
#
# The hook this replaces ran the bare binary with no -c, so yamllint fell back
# to its own discovery: a repo-local .yamllint* if present, else
# ~/.config/yamllint/config, else its built-in `default` preset. On a machine
# without dotfiles installed that means `default`, which is stricter than the
# fleet's `relaxed` base. Measured 2026-09-18, the rules that can BLOCK are
# `line-length` (default: error at 80; canonical: warning at 120) and
# `indentation` (default: error; relaxed: warning). `truthy` and
# `comments-indentation` differ too but only at warning level, and
# `octal-values` is disabled in both. Local and CI then disagree by
# construction, which is twistedmelonman/claude-config#532.
#
# Repo-local discovery also differs, not just the fallback: yamllint's own
# order is .yamllint, .yamllint.yaml, .yamllint.yml, while CI's is .yamllint,
# .yamllint.yml, .yamllint.yaml. A repo carrying both extensions is resolved
# differently by each. That is why this wrapper iterates explicitly below
# rather than letting yamllint choose.
#
# UNLIKE the markdownlint wrapper next door, this does NOT merge configs.
# yamllint's -c takes a single file, and CI's own resolution at
# run-standards.sh:147-150 is likewise either/or: the first repo-local name
# that exists wins outright, and the canonical file is used only when none do.
# An earlier handoff speculated this "may legitimately be a merge because
# yamllint has `extends:` semantics". It is not. `extends:` is a directive
# *inside* a config file, resolved by yamllint itself; it is not config
# layering performed by the caller. Do not port lint-markdown.sh's jq merge
# into this file: for markdownlint CI merges, and the hook's failure to merge
# was the bug (claude-config#533). The wrappers differ because the linters do.
#
# Discovery discrepancy, deliberate: yamllint also honours a `.yamllint`
# directory and the YAMLLINT_CONFIG_FILE environment variable.
# run-standards.sh checks the three repo-root filenames only. This wrapper
# matches CI rather than yamllint, on the same reasoning as lint-zizmor.sh: if
# it ever matters, fix run-standards.sh first and follow it here.
#
# Filename note: dotfiles deploys the canonical config to
# ~/.config/yamllint/config (no extension — that is yamllint's own XDG
# discovery name), while CI's copy is standards/yamllint.yml. The two are
# functionally identical; the names differ because each side is named for its
# own consumer. This wrapper passes the deployed path explicitly, so the
# filename difference cannot change which rules apply.

set -euo pipefail

CANONICAL="${YAMLLINT_CANONICAL_CONFIG:-${HOME}/.config/yamllint/config}"

main() {
  # Nothing staged for this hook: pre-commit still invokes it. yamllint with
  # no inputs is not a meaningful run, so exit clean rather than inventing a
  # failure. Mirrors lint-zizmor.sh and lint-markdown.sh.
  (($# > 0)) || exit 0

  # A repo-local config wins, exactly as in CI, and in CI's order. yamllint's
  # own discovery would find these too; passing the resolved path explicitly
  # keeps this wrapper identical to run-standards.sh rather than implicit.
  local c
  for c in .yamllint .yamllint.yml .yamllint.yaml; do
    if [[ -f "${c}" ]]; then
      exec yamllint -c "${c}" -f parsable "$@"
    fi
  done

  # No repo config and no canonical file: a fresh machine where dotfiles is
  # cloned but not yet installed. Passing a nonexistent path makes yamllint
  # fail on a path the user never configured, blocking the commit with a
  # confusing error. Warn and fall back to yamllint's built-in defaults, which
  # still lint — they are merely stricter than the fleet base. Same shape as
  # the fix in dotfiles#343.
  if [[ ! -f "${CANONICAL}" ]]; then
    printf 'lint-yamllint: canonical config not found at %s; using yamllint defaults\n' \
      "${CANONICAL}" >&2
    printf 'lint-yamllint: the default preset is stricter than the fleet base\n' >&2
    exec yamllint -f parsable "$@"
  fi

  exec yamllint -c "${CANONICAL}" -f parsable "$@"
}

main "$@"
