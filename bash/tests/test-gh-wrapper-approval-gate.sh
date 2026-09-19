#!/usr/bin/env bash
#shellcheck shell=bash
# Standalone verification for bash/gh-wrapper.sh's approval gate.
# Run directly: bash bash/tests/test-gh-wrapper-approval-gate.sh
#
# The gate refuses to write a PR or issue body unless those exact bytes are in
# gate-review's approved/ directory. It is the manual-`gh` half of a pair whose
# other half is ~/.claude/scripts/hook-block-personify.sh; the two enforce the
# same rule so the human learns one rule and not two.
#
# These cases drive the REAL gate-review.sh against a sandboxed GATE_REVIEW_DIR
# rather than a stub. A stub would encode what this test's author believed
# `check` does; claude-config's own history has three separate incidents of a
# green suite over broken code from exactly that substitution.
set -euo pipefail

unset CDPATH

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
_tests_dir="$(CDPATH='' cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/git-env-isolation.sh
source "${_tests_dir}/lib/git-env-isolation.sh"
isolate_git_env

export BASH_CONFIG_DIR="${REPO_ROOT}/bash"

#shellcheck source=/dev/null
source "${BASH_CONFIG_DIR}/gh-wrapper.sh"

fail=0

# Sandbox HOME so the gate resolves gate-review.sh and the approvals directory
# inside the fixture, never against the real one. Approving bytes for a test
# must not create an approval the live gate would honour.
SANDBOX="$(mktemp -d)"
trap 'rm -rf "${SANDBOX}"' EXIT
REAL_GATE="${HOME}/.claude/scripts/gate-review.sh"
export HOME="${SANDBOX}"
mkdir -p "${SANDBOX}/.claude/scripts"

if [[ -x "${REAL_GATE}" ]]; then
  cp "${REAL_GATE}" "${SANDBOX}/.claude/scripts/gate-review.sh"
  HAVE_GATE=1
else
  # claude-config is not installed on this machine. The gate-absent case is
  # still exercised below; the approval cases are skipped rather than faked.
  HAVE_GATE=0
fi

GATE="${SANDBOX}/.claude/scripts/gate-review.sh"
export GATE_REVIEW_DIR="${SANDBOX}/.claude/gate-review"
mkdir -p "${GATE_REVIEW_DIR}/pending" "${GATE_REVIEW_DIR}/approved"

BODY="${SANDBOX}/body.md"
printf 'A body that was approved.\n' >"${BODY}"

UNAPPROVED="${SANDBOX}/unapproved.md"
printf 'A body nobody ever read.\n' >"${UNAPPROVED}"

# Approve BODY's bytes by placing them in approved/, which is what a human
# typing APPROVED in the editor ultimately produces.
if [[ "${HAVE_GATE}" == "1" ]]; then
  cp "${BODY}" "${GATE_REVIEW_DIR}/approved/somelabel"
fi

# expected: 0 = call is allowed through, 1 = call is blocked
assert_gate() {
  local label="$1" expected="$2"
  shift 2
  local rc=0
  _gh_wrapper_approval_gate "$@" >/dev/null 2>&1 || rc=1

  if [[ "${rc}" == "${expected}" ]]; then
    echo "PASS: ${label}"
  else
    echo "FAIL: ${label} — expected rc=${expected}, got rc=${rc}"
    fail=1
  fi
}

# --- surfaces that carry no body: always allowed ------------------------------
# Titles are one line by nature and stay ungated, per the locked decision.
assert_gate "pr create with title only" 0 pr create --title "a title"
assert_gate "pr edit --add-label (no body)" 0 pr edit 5 --add-label bug
assert_gate "pr review --approve (no body)" 0 pr review 5 --approve
assert_gate "pr merge (not a text surface)" 0 pr merge 5 --squash
assert_gate "issue list (not a text surface)" 0 issue list
assert_gate "pr view (not a text surface)" 0 pr view 5

# --- inline body: unverifiable, always blocked --------------------------------
# There is nothing on disk to hash, so no approval can exist for it.
assert_gate "pr create --body inline" 1 pr create --title t --body "inline text"
assert_gate "pr create -b inline" 1 pr create --title t -b "inline text"
assert_gate "pr comment --body inline" 1 pr comment 5 --body "inline text"
assert_gate "issue create --body inline" 1 issue create --title t --body "inline"
assert_gate "issue comment --body inline" 1 issue comment 5 --body "inline"
assert_gate "pr edit --body inline" 1 pr edit 5 --body "inline"
assert_gate "issue edit --body inline" 1 issue edit 5 --body "inline"

# --- relative and unexpanded paths: blocked -----------------------------------
# gh resolves these against its own cwd and the gate against this process's;
# the two can disagree silently, so neither is trusted.
#
# These cases run from a cwd where the relative name RESOLVES to a file whose
# bytes are approved. Without that, a relative path blocks because no such file
# exists, the assertion passes, and the absolute-path rule itself is never
# exercised -- measured 2026-09-18: deleting that rule left this whole group
# green. Making the file real and approved leaves the path rule as the only
# thing that can block, so the case fails if it is removed.
pushd "${SANDBOX}" >/dev/null
assert_gate "relative --body-file" 1 pr create --title t --body-file body.md
assert_gate "dot-relative --body-file" 1 pr create --title t --body-file ./body.md
popd >/dev/null
# Both paths below are deliberately UNEXPANDED: a tilde and a dollar-var that
# reached the gate as literal text, which is what happens when gh is handed a
# quoted path. They are assembled from pieces so the literal bytes exist without
# writing a tilde or a `$VAR` inside quotes, which shellcheck reads as a mistake
# (SC2088/SC2016) and which no `disable` directive is permitted to silence.
#
# As above, these run from a cwd where the literal name resolves to an approved
# file, so the path rule is the only thing left that can block them.
tilde_path="$(printf '%s/body.md' '~')"
dollar_path="$(printf '%sHOME/body.md' '$')"
mkdir -p "${SANDBOX}/~" "${SANDBOX}/\$HOME"
cp "${BODY}" "${SANDBOX}/${tilde_path}"
cp "${BODY}" "${SANDBOX}/${dollar_path}"
pushd "${SANDBOX}" >/dev/null
assert_gate "tilde path --body-file" 1 pr create --title t --body-file "${tilde_path}"
assert_gate "unexpanded var --body-file" 1 pr create --title t --body-file "${dollar_path}"
popd >/dev/null

# A stdin body has no path to resolve and no bytes on disk to hash, so it is
# blocked by the same absolute-path rule rather than a case of its own.
assert_gate "stdin --body-file -" 1 pr create --title t --body-file -

# --- absolute path that does not exist ----------------------------------------
assert_gate "absolute path, missing file" 1 pr create --title t --body-file "${SANDBOX}/nope.md"

if [[ "${HAVE_GATE}" == "1" ]]; then
  # --- unapproved bytes: blocked ----------------------------------------------
  assert_gate "absolute path, unapproved bytes" 1 pr create --title t --body-file "${UNAPPROVED}"

  # --- approved bytes: allowed, in each flag spelling -------------------------
  assert_gate "--body-file approved" 0 pr create --title t --body-file "${BODY}"
  assert_gate "--body-file= approved" 0 pr create --title t "--body-file=${BODY}"
  assert_gate "-F approved" 0 pr create --title t -F "${BODY}"
  assert_gate "-F<path> attached, approved" 0 pr create --title t "-F${BODY}"
  assert_gate "pr comment approved" 0 pr comment 5 --body-file "${BODY}"
  assert_gate "issue create approved" 0 issue create --title t --body-file "${BODY}"
  assert_gate "issue comment approved" 0 issue comment 5 --body-file "${BODY}"
  assert_gate "pr edit approved" 0 pr edit 5 --body-file "${BODY}"
  assert_gate "issue edit approved" 0 issue edit 5 --body-file "${BODY}"

  # A -R value that happens to look like a subcommand must not be read as one.
  assert_gate "--repo value not mistaken for subcommand" 0 \
    pr create -R someorg/pr --title t --body-file "${BODY}"

  # Editing the approved file after approval invalidates it: the gate binds to
  # bytes, not to the filename.
  printf 'Edited after approval.\n' >"${SANDBOX}/tampered.md"
  assert_gate "bytes changed after approval" 1 pr create --title t --body-file "${SANDBOX}/tampered.md"

  # An approval made under one label satisfies a body used anywhere: `check`
  # matches on content and takes no name.
  assert_gate "approval is label-independent" 0 issue comment 9 --body-file "${BODY}"
else
  echo "SKIP: approval cases — gate-review.sh not installed at ${REAL_GATE}"
fi

# --- gate-review.sh absent: fails CLOSED --------------------------------------
# A redundant pair whose halves disagree about the unverifiable case is not
# redundant. Removing the gate must not turn the check into a pass.
mv "${GATE}" "${GATE}.hidden" 2>/dev/null || true
assert_gate "gate-review.sh absent fails closed" 1 pr create --title t --body-file "${BODY}"
# ...but a call with no body is still unaffected by the gate's absence.
assert_gate "gate absent, no body, still allowed" 0 pr create --title "a title"
mv "${GATE}.hidden" "${GATE}" 2>/dev/null || true

if [[ "${fail}" == "0" ]]; then
  echo "All approval-gate checks passed."
else
  echo "Approval-gate checks FAILED."
fi
exit "${fail}"
