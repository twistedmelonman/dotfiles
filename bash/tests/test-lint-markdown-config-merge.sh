#!/usr/bin/env bash
#shellcheck shell=bash
# Standalone verification that git/hooks/lint-markdown.sh merges the canonical
# markdownlint config with a repo-local one instead of choosing between them.
# Run directly: bash bash/tests/test-lint-markdown-config-merge.sh
#
# The hook this replaced branched: a repo WITH its own config was linted with
# no --config at all, so it inherited none of the canonical rule disables.
# MD060 is disabled canonically because it rejects the table style
# terraform-docs emits, so a repo whose config predated MD060 got the rule at
# its default and every commit touching a generated README was blocked — with
# --fix unable to repair it (smartwatermelon/dotfiles#308,
# twistedmelonman/claude-config#533).
#
# Passing --config twice does not merge: markdownlint 0.49.1 takes the last
# flag and discards the earlier one. The merge therefore happens in the hook,
# and consuming repos need no changes.
set -uo pipefail
unset CDPATH

REPO_ROOT="$(CDPATH='' cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HOOK="${REPO_ROOT}/git/hooks/lint-markdown.sh"

fail=0

_pass() { echo "  PASS: $1"; }
_fail() {
  echo "  FAIL: $1" >&2
  fail=1
}

if ! command -v markdownlint >/dev/null; then
  echo "SKIP: markdownlint not installed"
  exit 0
fi
if ! command -v jq >/dev/null; then
  echo "SKIP: jq not installed"
  exit 0
fi

TMPROOT="$(mktemp -d)"
trap 'rm -rf "${TMPROOT}"' EXIT

# A canonical config fixture rather than the real ~/.config one: the test must
# assert the merge, not whatever the developer's machine happens to carry.
CANONICAL="${TMPROOT}/canonical.json"
cat >"${CANONICAL}" <<'EOF'
{
  "default": true,
  "MD013": false,
  "MD041": false,
  "MD060": false
}
EOF

# A terraform-docs-style table: MD060 rejects this pipe alignment.
_write_case() {
  local dir="$1"
  mkdir -p "${dir}"
  printf '%s\n' '# Doc' '' '| Name | Type |' '|------|---------|' '| a | b |' \
    >"${dir}/README.md"
}

# ---------------------------------------------------------------------
# Known-bad case first. If this does not reproduce the original failure,
# every assertion below is vacuous and the suite proves nothing.
# ---------------------------------------------------------------------
kb="${TMPROOT}/known-bad"
_write_case "${kb}"
printf '{"default": true, "MD013": false}\n' >"${kb}/.markdownlint.json"
kb_out="$(cd "${kb}" && markdownlint --fix README.md 2>&1)"
if grep -q MD060 <<<"${kb_out}"; then
  _pass "known-bad reproduces: repo config alone lets MD060 fire"
else
  _fail "known-bad did NOT reproduce — MD060 never fired, so the remaining cases prove nothing"
  echo "${kb_out}" >&2
  exit 1
fi

# ---------------------------------------------------------------------
# Case 1: repo config present. Canonical disables must still apply.
# ---------------------------------------------------------------------
c1="${TMPROOT}/case1"
_write_case "${c1}"
printf '{"default": true, "MD013": false}\n' >"${c1}/.markdownlint.json"
c1_out="$(cd "${c1}" && MARKDOWNLINT_CANONICAL_CONFIG="${CANONICAL}" bash "${HOOK}" README.md 2>&1)"
if grep -q MD060 <<<"${c1_out}"; then
  _fail "repo config present: MD060 fired, so the canonical disables were dropped"
  echo "${c1_out}" >&2
else
  _pass "repo config present: canonical MD060 disable survives the merge"
fi

# ---------------------------------------------------------------------
# Case 2: no repo config. Canonical alone, unchanged behaviour.
# ---------------------------------------------------------------------
c2="${TMPROOT}/case2"
_write_case "${c2}"
c2_out="$(cd "${c2}" && MARKDOWNLINT_CANONICAL_CONFIG="${CANONICAL}" bash "${HOOK}" README.md 2>&1)"
if grep -q MD060 <<<"${c2_out}"; then
  _fail "no repo config: MD060 fired, so the canonical config was not applied"
  echo "${c2_out}" >&2
else
  _pass "no repo config: canonical config applies"
fi

# ---------------------------------------------------------------------
# Case 3: precedence. A repo key must override the canonical key, or the
# merge is just "canonical wins" and repos lose their own choices.
#
# MD013 is used because it is NOT auto-fixable: --fix would otherwise rewrite
# the file before the rule could fire, and the absence of a finding would look
# like a pass while testing nothing.
# ---------------------------------------------------------------------
c3="${TMPROOT}/case3"
mkdir -p "${c3}"
printf '%s\n' '# D' '' 'aaaa bbbb cccc dddd eeee ffff gggg hhhh' >"${c3}/long.md"
printf '{"MD013": {"line_length": 20}}\n' >"${c3}/.markdownlint.json"
c3_out="$(cd "${c3}" && MARKDOWNLINT_CANONICAL_CONFIG="${CANONICAL}" bash "${HOOK}" long.md 2>&1)"
if grep -q MD013 <<<"${c3_out}"; then
  _pass "precedence: repo MD013 overrides the canonical MD013:false"
else
  _fail "precedence: repo MD013 did not override canonical — repo keys are being discarded"
  echo "${c3_out}" >&2
fi

# ---------------------------------------------------------------------
# Case 4: missing canonical config (fresh machine, dotfiles not installed).
# Must fall back to the repo config and warn, not fail the commit.
# ---------------------------------------------------------------------
c4="${TMPROOT}/case4"
_write_case "${c4}"
printf '{"default": true, "MD013": false, "MD060": false}\n' >"${c4}/.markdownlint.json"
c4_out="$(cd "${c4}" && MARKDOWNLINT_CANONICAL_CONFIG="${TMPROOT}/does-not-exist.json" bash "${HOOK}" README.md 2>&1)"
c4_rc=$?
if ((c4_rc == 0)) && grep -q 'canonical config not found' <<<"${c4_out}"; then
  _pass "missing canonical: falls back to repo config and warns"
else
  _fail "missing canonical: expected a warning and exit 0, got rc=${c4_rc}"
  echo "${c4_out}" >&2
fi

# ---------------------------------------------------------------------
# Case 5: no files passed. pre-commit still invokes the hook; it must not
# invent a failure.
# ---------------------------------------------------------------------
c5_out="$(cd "${TMPROOT}" && MARKDOWNLINT_CANONICAL_CONFIG="${CANONICAL}" bash "${HOOK}" 2>&1)"
c5_rc=$?
if ((c5_rc == 0)); then
  _pass "no files: exits clean"
else
  _fail "no files: expected exit 0, got ${c5_rc}"
  echo "${c5_out}" >&2
fi

# ---------------------------------------------------------------------
# Case 6: the merged temp config must not survive the run.
# ---------------------------------------------------------------------
before="$(find "${TMPDIR:-/tmp}" -maxdepth 1 -name 'markdownlint-merged.*' 2>/dev/null | wc -l | tr -d ' ')"
c6="${TMPROOT}/case6"
_write_case "${c6}"
printf '{"default": true}\n' >"${c6}/.markdownlint.json"
(cd "${c6}" && MARKDOWNLINT_CANONICAL_CONFIG="${CANONICAL}" bash "${HOOK}" README.md >/dev/null 2>&1)
after="$(find "${TMPDIR:-/tmp}" -maxdepth 1 -name 'markdownlint-merged.*' 2>/dev/null | wc -l | tr -d ' ')"
if [[ "${before}" == "${after}" ]]; then
  _pass "temp config cleaned up"
else
  _fail "temp config leaked (${before} -> ${after})"
fi

if ((fail)); then
  echo "FAIL: lint-markdown config merge"
  exit 1
fi
echo "OK: lint-markdown config merge"
