#!/usr/bin/env bash
# Prettier wrapper for the `prettier` pre-commit hook.
#
# Prettier resolves a `.prettierrc`'s `plugins:` entries relative to the
# process cwd, not relative to the config file that declares them or to the
# file being formatted. The pre-commit hook used to run prettier from the
# repo root:
#
#   entry: bash -c 'npx prettier --write --ignore-unknown "$@"' --
#
# In a repo with per-package node_modules (no root install), the root cwd
# has no node_modules, so any plugin declared by a nested package's
# .prettierrc fails to resolve and blocks every commit that touches that
# package. See twistedmelonman/dotfiles#321.
#
# Fix: run each file from its nearest ancestor directory containing a
# package.json, so node's module resolution (and therefore prettier's
# plugin resolution) finds that package's own node_modules. Falls back to
# running from the current directory — the previous behavior — when no
# package.json ancestor exists, so repos with a single root install are
# unaffected.
set -euo pipefail

main() {
  # Nothing staged for this hook: pre-commit still invokes it. Exit clean
  # rather than inventing a failure. Mirrors lint-yamllint.sh / lint-zizmor.sh.
  (($# > 0)) || exit 0

  local f d rel
  for f in "$@"; do
    d="$(dirname "$f")"
    while [[ "${d}" != "." && "${d}" != "/" && ! -f "${d}/package.json" ]]; do
      d="$(dirname "${d}")"
    done

    if [[ -f "${d}/package.json" ]]; then
      rel="${f#"${d}"/}"
      # pre-commit passes repo-relative paths under the discovered package
      # dir, so `rel` should never climb back out of it. Reject a stray
      # `..` segment rather than letting `cd "${d}"` plus a traversing
      # relative path touch something outside that package.
      case "/${rel}/" in
        */../*)
          printf 'lint-prettier: refusing path outside package dir %s: %s\n' "${d}" "${f}" >&2
          exit 1
          ;;
      esac
      if ! (cd "${d}" && npx prettier --write --ignore-unknown "${rel}"); then
        exit 1
      fi
    elif ! npx prettier --write --ignore-unknown "${f}"; then
      exit 1
    fi
  done
}

main "$@"
