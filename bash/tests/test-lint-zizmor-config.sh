#!/usr/bin/env bash
#shellcheck shell=bash
# Standalone verification that git/hooks/lint-zizmor.sh resolves the zizmor
# config the way CI does instead of leaving zizmor to its own discovery.
# Run directly: bash bash/tests/test-lint-zizmor-config.sh
#
# The hook this replaced ran the bare binary with no --config. In a repo with
# no zizmor.yml that means zizmor's blanket `hash-pin` default, which rejects
# first-party reusable-workflow refs like
# `smartwatermelon/github-workflows/...@v3` that the fleet policy explicitly
# allows. That is what forced nightowlstudiollc/financial-agent#175 to convert
# floating refs to raw commit SHAs — a permanent opt-out from coordinated
# fleet remediation. See twistedmelonman/claude-config#531.
#
# Unlike the markdownlint wrapper, this does NOT merge configs: zizmor's
# --config loads a single file, and CI (run-standards.sh:177) is likewise
# either/or. The assertions below encode that difference deliberately.
set -uo pipefail
unset CDPATH

REPO_ROOT="$(CDPATH='' cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HOOK="${REPO_ROOT}/git/hooks/lint-zizmor.sh"

fail=0

_pass() { echo "  PASS: $1"; }
_fail() {
  echo "  FAIL: $1" >&2
  fail=1
}

if ! command -v zizmor >/dev/null; then
  echo "SKIP: zizmor not installed"
  exit 0
fi

TMPROOT="$(mktemp -d)"
trap 'rm -rf "${TMPROOT}"' EXIT

# A canonical fixture rather than the real ~/.config/zizmor/zizmor.yml: the
# test must assert the resolution, not whatever the developer's machine
# happens to carry. Only the unpinned-uses policy matters here.
CANONICAL="${TMPROOT}/canonical.yml"
cat >"${CANONICAL}" <<'EOF'
rules:
  unpinned-uses:
    config:
      policies:
        smartwatermelon/github-workflows/*: ref-pin
        "*": hash-pin
EOF

# A caller stub with a floating first-party ref: rejected by zizmor's blanket
# default, allowed by the fleet policy. This is the exact shape the 21
# config-less fleet repos carry.
_write_case() {
  local dir="$1"
  mkdir -p "${dir}/.github/workflows"
  cat >"${dir}/.github/workflows/claude.yml" <<'EOF'
name: Claude
on:
  pull_request:
permissions:
  contents: read
jobs:
  review:
    uses: smartwatermelon/github-workflows/.github/workflows/claude-assistant.yml@v3
EOF
}

# ---------------------------------------------------------------------
# Known-bad case first. If the bare binary does not reject the floating
# first-party ref, every assertion below is vacuous.
# ---------------------------------------------------------------------
kb="${TMPROOT}/known-bad"
_write_case "${kb}"
kb_out="$(cd "${kb}" && zizmor --min-severity low --no-online-audits .github/workflows/claude.yml 2>&1)"
if grep -q 'unpinned-uses' <<<"${kb_out}"; then
  _pass "known-bad reproduces: bare zizmor rejects the first-party @v3 ref"
else
  _fail "known-bad did NOT reproduce — unpinned-uses never fired, so the remaining cases prove nothing"
  echo "${kb_out}" >&2
  exit 1
fi

# ---------------------------------------------------------------------
# Case 1: no repo config. The canonical policy must apply, so the same
# workflow that just failed now passes. This is the whole point of the fix.
# ---------------------------------------------------------------------
c1="${TMPROOT}/case1"
_write_case "${c1}"
c1_out="$(cd "${c1}" && ZIZMOR_CANONICAL_CONFIG="${CANONICAL}" bash "${HOOK}" .github/workflows/claude.yml 2>&1)"
c1_rc=$?
if ((c1_rc == 0)) && ! grep -q 'unpinned-uses' <<<"${c1_out}"; then
  _pass "no repo config: canonical policy applies, first-party ref accepted"
else
  _fail "no repo config: expected clean, got rc=${c1_rc}"
  echo "${c1_out}" >&2
fi

# ---------------------------------------------------------------------
# Case 2: repo config present. It must WIN over the canonical file, matching
# run-standards.sh:177. Asserted with a repo config that is deliberately
# stricter than canonical — if the canonical were used instead, the finding
# would not fire and this would silently pass.
# ---------------------------------------------------------------------
c2="${TMPROOT}/case2"
_write_case "${c2}"
cat >"${c2}/zizmor.yml" <<'EOF'
rules:
  unpinned-uses:
    config:
      policies:
        "*": hash-pin
EOF
c2_out="$(cd "${c2}" && ZIZMOR_CANONICAL_CONFIG="${CANONICAL}" bash "${HOOK}" .github/workflows/claude.yml 2>&1)"
if grep -q 'unpinned-uses' <<<"${c2_out}"; then
  _pass "repo config present: repo config wins over canonical"
else
  _fail "repo config present: canonical was applied instead of the repo's own config"
  echo "${c2_out}" >&2
fi

# ---------------------------------------------------------------------
# Case 3: missing canonical config (fresh machine, dotfiles cloned but not
# installed). Must warn and fall back to zizmor's defaults, not hand zizmor a
# nonexistent path. Same shape as the fix in dotfiles#343.
#
# The assertion is "warns, and still lints" — NOT "exits 0". The fixture
# carries the floating first-party ref that zizmor's defaults reject, which is
# precisely why the canonical policy exists. Asserting exit 0 would demand the
# defaults accept a file the canonical policy exists to permit.
# ---------------------------------------------------------------------
c3="${TMPROOT}/case3"
_write_case "${c3}"
c3_out="$(cd "${c3}" && ZIZMOR_CANONICAL_CONFIG="${TMPROOT}/does-not-exist.yml" bash "${HOOK}" .github/workflows/claude.yml 2>&1)"
if grep -q 'canonical config not found' <<<"${c3_out}"; then
  _pass "missing canonical: warns rather than failing on a nonexistent path"
else
  _fail "missing canonical: expected a warning naming the path"
  echo "${c3_out}" >&2
fi

# The fallback must still LINT. A fallback that silently passes everything
# would turn a missing config into "workflows are never audited on this
# machine", which is the failure mode this hook exists to prevent.
if grep -q 'unpinned-uses' <<<"${c3_out}"; then
  _pass "missing canonical fallback still enforces zizmor defaults"
else
  _fail "missing canonical fallback did not lint — a silent pass"
  echo "${c3_out}" >&2
fi

# ---------------------------------------------------------------------
# Case 4: no files passed. pre-commit still invokes the hook; it must not
# invent a failure.
# ---------------------------------------------------------------------
c4_out="$(cd "${TMPROOT}" && ZIZMOR_CANONICAL_CONFIG="${CANONICAL}" bash "${HOOK}" 2>&1)"
c4_rc=$?
if ((c4_rc == 0)); then
  _pass "no files: exits clean"
else
  _fail "no files: expected exit 0, got ${c4_rc}"
  echo "${c4_out}" >&2
fi

# ---------------------------------------------------------------------
# Case 5: the vendored canonical copy must match the upstream policy byte for
# byte when the github-workflows checkout is present. A second copy of a
# policy file is a drift risk (twistedmelonman/claude-config#531 discussion,
# and the truncated copy in smartwatermelon/gmail-newsletter-filter); this
# catches the cheap half of that. Skipped when the sibling checkout is absent,
# so CI and other machines do not fail on a path that is not theirs.
# ---------------------------------------------------------------------
UPSTREAM="${ZIZMOR_UPSTREAM_CONFIG:-${HOME}/Developer/github-workflows/zizmor.yml}"
VENDORED="${REPO_ROOT}/zizmor/zizmor.yml"
if [[ -f "${UPSTREAM}" ]]; then
  if cmp -s "${UPSTREAM}" "${VENDORED}"; then
    _pass "vendored canonical config matches upstream byte for byte"
  else
    _fail "vendored zizmor/zizmor.yml has drifted from ${UPSTREAM}"
    diff -u "${UPSTREAM}" "${VENDORED}" >&2 || true
  fi
else
  echo "  SKIP: upstream checkout not present at ${UPSTREAM}"
fi

if ((fail)); then
  echo "FAIL: lint-zizmor config resolution"
  exit 1
fi
echo "OK: lint-zizmor config resolution"
