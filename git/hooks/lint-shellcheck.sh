#!/usr/bin/env bash
# Resolve which config the pre-commit shell hook lints against: repo-root
# .shellcheckrc if present, else the canonical base. Prints a path, runs no
# linter. Matches the resolution in standards/run-standards.sh.
#
# Without this, lint-shell.sh passed no --rcfile and fell back to the ancestor
# search, which reaches $HOME. Measured 2026-09-18 over dotfiles' 60 shell
# files at -S info: repo rc and canonical base both 0 findings,
# ~/.shellcheckrc (enable=all) 87. Those 87 are why #534's per-repo .shellcheckrc
# deletions cannot land before this does.
#
# Configs do NOT merge: a repo-root file halts the search and --rcfile replaces
# it, so a per-repo exception restates the whole base and drifts. Prefer a
# file-level disable directive.
#
# No comment line here may begin with the tool's name plus a word: that parses
# as a directive and fails the file with SC1072/SC1073.

set -euo pipefail

CANONICAL="${SHELLCHECK_CANONICAL_CONFIG:-${HOME}/.config/shellcheck/shellcheckrc}"

main() {
  # Repo root, not cwd: pre-commit invokes from the top level but a direct call
  # need not, and the search this replaces was itself cwd-sensitive.
  local repo
  repo="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"

  if [[ -f "${repo}/.shellcheckrc" ]]; then
    printf '%s\n' "${repo}/.shellcheckrc"
    return 0
  fi

  # Fresh machine: cloned but not installed. Print nothing so the caller runs
  # bare rather than failing on a path the user never configured. Same shape as
  # lint-zizmor.sh.
  if [[ ! -f "${CANONICAL}" ]]; then
    printf 'lint-shellcheck: canonical config not found at %s; using shellcheck discovery\n' \
      "${CANONICAL}" >&2
    printf 'lint-shellcheck: local findings may differ from CI (claude-config#534)\n' >&2
    return 0
  fi

  printf '%s\n' "${CANONICAL}"
}

main "$@"
