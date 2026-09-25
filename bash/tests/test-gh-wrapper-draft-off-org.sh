#!/usr/bin/env bash
#shellcheck shell=bash
# Standalone verification for bash/gh-wrapper.sh's off-org draft-forcing.
# Run directly: bash bash/tests/test-gh-wrapper-draft-off-org.sh
#
# Coverage for smartwatermelon/dotfiles#174: `gh pr create` targeting a repo
# outside smartwatermelon/nightowlstudiollc must have --draft injected into
# the argument list, unconditionally, with no way for the caller to opt out.
set -euo pipefail

unset CDPATH

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# Clear inherited git repository-selection state before touching any fixture.
# A hook invoked from a linked worktree exports GIT_DIR, which outranks both the
# working directory and `git -C`, so without this the scratch repos below are
# silently redirected at the real checkout (smartwatermelon/dotfiles#239).
_tests_dir="$(CDPATH='' cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/git-env-isolation.sh
source "${_tests_dir}/lib/git-env-isolation.sh"
isolate_git_env

export BASH_CONFIG_DIR="${REPO_ROOT}/bash"

# Sourcing (not executing) the file puts it in function-definition mode,
# where _gh_wrapper_force_draft_for_off_org is defined but gh() itself is
# not invoked.
#shellcheck source=/dev/null
source "${BASH_CONFIG_DIR}/gh-wrapper.sh"

fail=0

assert_args() {
  local label="$1"
  shift
  local expected_has_draft="$1"
  shift
  local -a got=()
  mapfile -t -d '' got < <(_gh_wrapper_force_draft_for_off_org "$@" || true)

  local has_draft=0 a
  for a in "${got[@]}"; do
    [[ "${a}" == "--draft" ]] && has_draft=1
  done

  if [[ "${has_draft}" == "${expected_has_draft}" ]]; then
    echo "PASS: ${label}"
  else
    echo "FAIL: ${label} — expected --draft present=${expected_has_draft}, got=${has_draft} (args: ${got[*]})"
    fail=1
  fi
}

# In-org, explicit -R: no draft forced.
assert_args "in-org explicit --repo" 0 pr create --repo smartwatermelon/dotfiles --title x

# Off-org, explicit --repo=: draft forced.
assert_args "off-org explicit --repo=" 1 pr create --repo=someoutsideorg/foo --title x

# nightowlstudiollc counts as in-org: no draft forced.
assert_args "nightowlstudiollc explicit -R" 0 pr create -R nightowlstudiollc/somerepo --title x

# twistedmelonman is the personal account that keeps the archived repos and
# forks after the 2026-09 org migration: in-org, no draft forced.
assert_args "twistedmelonman explicit --repo" 0 pr create --repo twistedmelonman/old-archived --title x

# Case-insensitive owner match, mirroring _gh_wrapper_sync_identity's
# regression coverage for smartwatermelon/dotfiles#159.
assert_args "mixed-case in-org owner" 0 pr create --repo SmartWatermelon/dotfiles --title x

# Not `pr create`: unaffected regardless of owner.
assert_args "gh issue create off-org (unaffected)" 0 issue create --repo someoutsideorg/foo --title x
assert_args "gh pr merge off-org (unaffected)" 0 pr merge 5 --repo someoutsideorg/foo

# --help on an off-org pr create: the caller (standalone/function-mode entry
# points) skips calling this function at all for --help requests, but the
# function itself must still not misbehave if invoked directly.
assert_args "off-org pr create --help (function itself is harmless)" 1 pr create --repo someoutsideorg/foo --help

# Caller already passed --draft explicitly: harmless, still present exactly
# once more isn't required to be deduped, just confirm it's present.
assert_args "off-org pr create with explicit --draft already present" 1 pr create --repo someoutsideorg/foo --draft --title x

# Regression for smartwatermelon/dotfiles#186: a --body value containing
# embedded newlines must survive the arg-list rebuild intact as a single
# argument, not get shredded into multiple positional params at each \n.
multiline_body="$(printf 'line one\nline two\nline three')"
mapfile -t -d '' multiline_got < <(_gh_wrapper_force_draft_for_off_org pr create --repo smartwatermelon/dotfiles --title x --body "${multiline_body}" || true)
if [[ "${#multiline_got[@]}" == "8" && "${multiline_got[7]}" == "${multiline_body}" ]]; then
  echo "PASS: multi-line --body value survives arg rebuild intact"
else
  echo "FAIL: multi-line --body value was shredded (count=${#multiline_got[@]}): ${multiline_got[*]@Q}"
  fail=1
fi

# Zero args: must not error and must not fabricate an argument.
mapfile -t -d '' zero_args < <(_gh_wrapper_force_draft_for_off_org || true)
if [[ "${#zero_args[@]}" == "0" ]]; then
  echo "PASS: zero-arg call produces an empty array"
else
  echo "FAIL: zero-arg call produced unexpected output: ${zero_args[*]}"
  fail=1
fi

# cwd-remote fallback: no explicit -R/--repo, owner resolved from `origin`.
off_org_clone="/tmp/gh-wrapper-draft-test-off-org-$$"
in_org_clone="/tmp/gh-wrapper-draft-test-in-org-$$"
mkdir -p "${off_org_clone}" "${in_org_clone}"
# cwd_status_dir is created further down but named here, so an abort between
# its mktemp and its explicit cleanup cannot leak it. The `:-` guard covers the
# window before it is assigned. Leaked fixture dirs are the defect class this
# suite has been clearing out (#255, #256).
# `${cwd_status_dir:+...}` expands to nothing at all when the variable is unset,
# rather than handing `rm -rf` an empty string. macOS `rm -rf ""` happens to be
# a silent no-op (verified), but GNU coreutils is not obliged to agree, and a
# spurious error here would land on top of whatever real failure triggered the
# abort. This form is unambiguous on both.
trap 'rm -rf "${off_org_clone}" "${in_org_clone}" ${cwd_status_dir:+"${cwd_status_dir}"}' EXIT
(cd "${off_org_clone}" && command git init -q && command git remote add origin git@github.com:someoutsideorg/foo.git)
(cd "${in_org_clone}" && command git init -q && command git remote add origin git@github.com:smartwatermelon/dotfiles.git)

# `fail` is set inside subshells, so it cannot propagate back by assignment.
# It travels through the filesystem instead — and the direction matters.
#
# Signalling FAILURE ("touch on failure") fails OPEN: this script runs under
# `set -e`, so a subshell that dies before reaching its sentinel line — an
# unexpected non-zero from `cd` or `assert_args` rather than a `fail=1` — writes
# nothing, and the parent reads that silence as a pass
# (smartwatermelon/dotfiles#247).
#
# Signalling COMPLETION instead fails CLOSED. Each subshell records its own
# verdict only after it has run to the end, so an early exit leaves the file
# absent and the parent treats a missing verdict as a failure. Silence can no
# longer be mistaken for success — the defect class this suite has been
# clearing out (see #256).
cwd_status_dir="$(mktemp -d "${TMPDIR:-/tmp}/gh-wrapper-draft-cwd.XXXXXX")"

run_cwd_case() {
  local clone="$1" desc="$2" want="$3" tag="$4"
  (
    cd "${clone}" || exit 1
    fail=0
    assert_args "${desc}" "${want}" pr create --title x
    # Reached only if the case ran to completion; the recorded value is this
    # subshell's own verdict.
    printf '%s\n' "${fail}" >"${cwd_status_dir}/${tag}"
  )
}

# `|| true` so a subshell that dies mid-case does not abort this script under
# `set -e`. Without it the script exits immediately with the subshell's status
# and NO explanation — the missing-verdict check below never runs, so a broken
# case looks like a bare non-zero exit rather than a named failure
# (smartwatermelon/dotfiles#270).
#
# This does not weaken the fail-closed property: the verdict file is still only
# written by a case that ran to completion, and a missing file is still treated
# as a failure. It only ensures the failure is REPORTED instead of aborting
# silently.
run_cwd_case "${off_org_clone}" "off-org cwd remote fallback" 1 off-org || true
run_cwd_case "${in_org_clone}" "in-org cwd remote fallback" 0 in-org || true

for tag in off-org in-org; do
  if [[ ! -f "${cwd_status_dir}/${tag}" ]]; then
    echo "FAIL: ${tag} cwd case did not run to completion (aborted before recording a verdict)"
    fail=1
  else
    cwd_verdict="$(cat "${cwd_status_dir}/${tag}")" || cwd_verdict="unreadable"
    if [[ "${cwd_verdict}" != "0" ]]; then
      fail=1
    fi
  fi
done
rm -rf "${cwd_status_dir}"

exit "${fail}"
