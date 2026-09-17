#!/usr/bin/env bash
# Markdown lint wrapper for the `markdownlint` pre-commit hook.
#
# Resolves the config the way CI does (standards/run-standards.sh:193-197):
# the canonical policy applies, and a repo-local config layers on top of it.
#
# The hook this replaces branched instead of merging:
#
#   if repo has its own config; then markdownlint --fix "$@"       # no --config
#   else markdownlint --fix --config "$CANONICAL" "$@"; fi
#
# The first branch passed no --config at all, so a repo with its own config
# inherited none of the canonical rule disables. `MD060: false` is set
# canonically because MD060 rejects the table style terraform-docs emits, so a
# repo whose config predates MD060 got the rule at its default and every commit
# touching a generated README was blocked, with --fix unable to repair it.
# See twistedmelonman/claude-config#533 and twistedmelonman/dotfiles#308.
#
# Passing --config twice does not merge: markdownlint 0.49.1 takes the last
# flag and discards the earlier one (verified 2026-09-16). `extends` in the
# repo config does merge correctly, but that requires editing every consuming
# repo — the fleet-wide sweep this is meant to avoid. So the merge happens
# here, and consuming repos stay untouched.
#
# Precedence: repo keys win over canonical keys. Measured across the six
# repo-local configs in the fleet, no repo overrides a canonical key, so today
# the merge is purely additive — repos gain disables they were silently
# missing and nothing becomes stricter.

set -euo pipefail

CANONICAL="${MARKDOWNLINT_CANONICAL_CONFIG:-${HOME}/.config/markdownlint-cli/.markdownlint.json}"

# markdownlint's own discovery order, repo root only. A nested config is not
# consulted: markdownlint-cli resolves config at the invocation, not per
# directory.
_find_repo_config() {
  local c
  for c in .markdownlint.json .markdownlint.yaml .markdownlint.yml \
    .markdownlint.jsonc .markdownlintrc; do
    if [[ -f "${c}" ]]; then
      printf '%s' "${c}"
      return 0
    fi
  done
  return 1
}

main() {
  # Nothing staged for this hook: pre-commit still invokes it, and
  # markdownlint with no files would lint nothing but exit non-zero on some
  # versions. Exit clean rather than inventing a failure.
  (($# > 0)) || exit 0

  local repo_config merged
  if ! repo_config="$(_find_repo_config)"; then
    # No repo config: the canonical file is the whole policy.
    exec markdownlint --fix --config "${CANONICAL}" "$@"
  fi

  if [[ ! -f "${CANONICAL}" ]]; then
    # Canonical file missing (fresh machine, dotfiles not yet installed).
    # Fall back to the repo's own config rather than failing the commit, and
    # say so — a silent fallback here is what made the original bug invisible.
    printf 'lint-markdown: canonical config not found at %s; using %s alone\n' \
      "${CANONICAL}" "${repo_config}" >&2
    exec markdownlint --fix --config "${repo_config}" "$@"
  fi

  # jq reads JSON and JSONC-without-comments. YAML configs and .markdownlintrc
  # with comments are not merged — use the repo config alone rather than
  # guessing at a parse. No repo in the fleet uses those formats today
  # (verified 2026-09-16); this branch exists so that changing is not silently
  # wrong.
  if ! merged="$(jq -s '.[0] * .[1]' "${CANONICAL}" "${repo_config}" 2>/dev/null)"; then
    printf 'lint-markdown: cannot merge %s (unsupported format); using it alone\n' \
      "${repo_config}" >&2
    exec markdownlint --fix --config "${repo_config}" "$@"
  fi

  # File-scoped, not `local`: the EXIT trap fires after main() returns, when a
  # function-local would be out of scope and `set -u` would abort the cleanup
  # with "tmp: unbound variable".
  _lint_md_tmp="$(mktemp -t markdownlint-merged.XXXXXX.json)"
  # The trap covers every exit path, so the merged config never outlives the
  # run. It holds no secrets — only lint rule toggles.
  trap 'rm -f "${_lint_md_tmp:-}"' EXIT
  printf '%s\n' "${merged}" >"${_lint_md_tmp}"

  markdownlint --fix --config "${_lint_md_tmp}" "$@"
}

main "$@"
