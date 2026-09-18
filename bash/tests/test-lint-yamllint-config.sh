#!/usr/bin/env bash
#shellcheck shell=bash
# Standalone verification that git/hooks/lint-yamllint.sh resolves the yamllint
# config the way CI does instead of leaving yamllint to its own discovery.
# Run directly: bash bash/tests/test-lint-yamllint-config.sh
#
# The hook this replaced ran the bare binary with no -c. On a machine without
# dotfiles installed, yamllint then falls back to its built-in `default`
# preset, which is stricter than the fleet's `relaxed` base. The blocking
# divergence is `line-length` (default: error at 80; canonical: warning at
# 120) and `indentation` (default: error; relaxed: warning). Local and CI
# disagree by construction. See twistedmelonman/claude-config#532.
#
# `truthy` is the discriminator used throughout the assertions below, but it
# is a WARNING under `default` and disabled under `relaxed` — so these cases
# grep yamllint's OUTPUT for it rather than testing the exit code. Measured
# from the installed preset 2026-09-18: truthy=warning,
# comments-indentation=warning, octal-values=disabled.
#
# Unlike the markdownlint wrapper, this does NOT merge configs: yamllint's -c
# loads a single file, and CI (the yamllint config block in
# run-standards.sh) is likewise either/or. The assertions below encode that
# difference deliberately.
set -uo pipefail
unset CDPATH

REPO_ROOT="$(CDPATH='' cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HOOK="${REPO_ROOT}/git/hooks/lint-yamllint.sh"

fail=0

_pass() { echo "  PASS: $1"; }
_fail() {
  echo "  FAIL: $1" >&2
  fail=1
}

if ! command -v yamllint >/dev/null; then
  echo "SKIP: yamllint not installed"
  exit 0
fi

TMPROOT="$(mktemp -d)"
trap 'rm -rf "${TMPROOT}"' EXIT

# A canonical fixture rather than the real ~/.config/yamllint/config: the test
# must assert the resolution, not whatever the developer's machine happens to
# carry. `relaxed` plus the fleet's line-length is the whole canonical policy.
CANONICAL="${TMPROOT}/canonical.yml"
cat >"${CANONICAL}" <<'EOF'
---
extends: relaxed

rules:
  line-length:
    max: 120
EOF

# A fixture that `relaxed` passes silently but yamllint's `default` preset
# reports on. `truthy` is the discriminator: default WARNS on bare yes/no,
# relaxed disables the rule entirely. This is the exact shape of the
# local-vs-CI disagreement being fixed — and because it is a warning, every
# assertion below greps output rather than checking rc.
_write_case() {
  local dir="$1"
  mkdir -p "${dir}"
  cat >"${dir}/sample.yml" <<'EOF'
---
name: sample
on:
  push: yes
EOF
}

# ---------------------------------------------------------------------
# Known-bad case first. If the bare binary does not reject the fixture, every
# assertion below is vacuous.
# ---------------------------------------------------------------------
kb="${TMPROOT}/known-bad"
_write_case "${kb}"
kb_out="$(cd "${kb}" && yamllint -d default -f parsable sample.yml 2>&1)"
if grep -q 'truthy' <<<"${kb_out}"; then
  _pass "known-bad reproduces: yamllint's default preset rejects the fixture"
else
  _fail "known-bad did NOT reproduce — truthy never fired, so the remaining cases prove nothing"
  echo "${kb_out}" >&2
  exit 1
fi

# ---------------------------------------------------------------------
# Case 1: no repo config. The canonical policy must apply, so the same file
# that just failed now passes. This is the whole point of the fix.
# ---------------------------------------------------------------------
c1="${TMPROOT}/case1"
_write_case "${c1}"
c1_out="$(cd "${c1}" && YAMLLINT_CANONICAL_CONFIG="${CANONICAL}" bash "${HOOK}" sample.yml 2>&1)"
c1_rc=$?
if ((c1_rc == 0)) && ! grep -q 'truthy' <<<"${c1_out}"; then
  _pass "no repo config: canonical policy applies, relaxed rules accepted"
else
  _fail "no repo config: expected clean, got rc=${c1_rc}"
  echo "${c1_out}" >&2
fi

# ---------------------------------------------------------------------
# Case 2: repo config present. It must WIN over the canonical file, matching
# CI's yamllint block. Asserted with a repo config that is deliberately
# stricter than canonical — if the canonical were used instead, the finding
# would not fire and this would silently pass.
# ---------------------------------------------------------------------
c2="${TMPROOT}/case2"
_write_case "${c2}"
cat >"${c2}/.yamllint" <<'EOF'
---
extends: default
EOF
c2_out="$(cd "${c2}" && YAMLLINT_CANONICAL_CONFIG="${CANONICAL}" bash "${HOOK}" sample.yml 2>&1)"
if grep -q 'truthy' <<<"${c2_out}"; then
  _pass "repo config present: repo config wins over canonical"
else
  _fail "repo config present: canonical was applied instead of the repo's own config"
  echo "${c2_out}" >&2
fi

# ---------------------------------------------------------------------
# Case 3: CI's filename PRECEDENCE, not merely "some repo file wins".
# run-standards.sh checks .yamllint, then .yamllint.yml, then .yamllint.yaml,
# and breaks on the first hit. yamllint's OWN discovery order is .yamllint,
# then .yamllint.yaml, then .yamllint.yml — the two agree on position 1 and
# disagree at positions 2 and 3.
#
# The fixture therefore uses exactly that disagreeing pair: strict at
# .yamllint.yml (which CI picks) and permissive at .yamllint.yaml (which
# yamllint picks). A wrapper that delegated to yamllint's discovery — the
# bare `exec yamllint "$@"` regression this case exists to catch — selects
# the permissive file and reports nothing.
#
# An earlier revision used .yamllint + .yamllint.yaml. Both orders select
# .yamllint from that pair, so the case passed for the broken hook too.
# Verified 2026-09-18: with .yml and .yaml both present, bare yamllint is
# silent while CI's order reports truthy.
# ---------------------------------------------------------------------
c3="${TMPROOT}/case3"
_write_case "${c3}"
cat >"${c3}/.yamllint.yml" <<'EOF'
---
extends: default
EOF
cat >"${c3}/.yamllint.yaml" <<'EOF'
---
extends: relaxed
EOF
c3_out="$(cd "${c3}" && YAMLLINT_CANONICAL_CONFIG="${CANONICAL}" bash "${HOOK}" sample.yml 2>&1)"
if grep -q 'truthy' <<<"${c3_out}"; then
  _pass "filename precedence: .yamllint.yml wins over .yamllint.yaml, as in CI"
else
  _fail "filename precedence: .yamllint.yml did not win — resolution order matches yamllint's discovery, not CI's"
  echo "${c3_out}" >&2
fi

# ---------------------------------------------------------------------
# Case 4: missing canonical config (fresh machine, dotfiles cloned but not
# installed). Must warn and fall back to yamllint's defaults, not hand
# yamllint a nonexistent path. Same shape as the fix in dotfiles#343.
#
# The assertion is "warns, and still lints" — NOT "exits 0". The fixture
# carries the truthy value that yamllint's defaults reject, which is precisely
# why the canonical policy exists. Asserting exit 0 would demand the defaults
# accept a file the canonical policy exists to permit.
# ---------------------------------------------------------------------
c4="${TMPROOT}/case4"
_write_case "${c4}"
c4_out="$(cd "${c4}" && YAMLLINT_CANONICAL_CONFIG="${TMPROOT}/does-not-exist.yml" bash "${HOOK}" sample.yml 2>&1)"
if grep -q 'canonical config not found' <<<"${c4_out}"; then
  _pass "missing canonical: warns rather than failing on a nonexistent path"
else
  _fail "missing canonical: expected a warning naming the path"
  echo "${c4_out}" >&2
fi

# The fallback must still LINT. A fallback that silently passes everything
# would turn a missing config into "YAML is never checked on this machine",
# which is the failure mode this hook exists to prevent.
#
# Asserted with a SYNTAX error rather than the truthy fixture. Bare yamllint
# still performs its own XDG discovery, so on a developer machine it finds
# ~/.config/yamllint/config (relaxed) and reports no truthy warning — the
# fallback is genuinely linting, just under relaxed rules. A syntax error is
# rejected by every preset, so it proves the fallback runs without assuming
# which config yamllint happened to discover.
#
# The assertion matches yamllint's parsable finding line specifically —
# `[error] syntax error` — rather than a bare `error`. The regression this
# guards (handing yamllint a nonexistent -c path) makes it die with a Python
# traceback, and a loose pattern risks reading that crash as a successful
# lint. Measured 2026-09-18: that traceback contains neither "syntax error"
# nor "[error]", and exits 1, so rc alone cannot separate the two either.
# Both conditions are asserted: a real lint finding AND rc 1.
c4b="${TMPROOT}/case4b"
mkdir -p "${c4b}"
printf -- '---\nbroken: [unclosed\n' >"${c4b}/broken.yml"
c4b_out="$(cd "${c4b}" && YAMLLINT_CANONICAL_CONFIG="${TMPROOT}/does-not-exist.yml" bash "${HOOK}" broken.yml 2>&1)"
c4b_rc=$?
if ((c4b_rc == 1)) && grep -qE '\[error\] syntax error' <<<"${c4b_out}"; then
  _pass "missing canonical fallback still lints (syntax error reported, rc=1)"
else
  _fail "missing canonical fallback did not lint — a silent pass or a crash (rc=${c4b_rc})"
  echo "${c4b_out}" >&2
fi

# ---------------------------------------------------------------------
# Case 5: no files passed. pre-commit still invokes the hook; it must not
# invent a failure.
# ---------------------------------------------------------------------
c5_out="$(cd "${TMPROOT}" && YAMLLINT_CANONICAL_CONFIG="${CANONICAL}" bash "${HOOK}" 2>&1)"
c5_rc=$?
if ((c5_rc == 0)); then
  _pass "no files: exits clean"
else
  _fail "no files: expected exit 0, got ${c5_rc}"
  echo "${c5_out}" >&2
fi

# ---------------------------------------------------------------------
# Case 6: the deployed config must stay functionally equivalent to the
# upstream CI copy. Byte-identity is NOT asserted: the two files carry
# different header comments by design, and are named for their own consumers
# (~/.config/yamllint/config vs standards/yamllint.yml). Comparing the parsed
# rule sets catches real drift without failing on a comment. Skipped when the
# sibling checkout is absent, so CI and other machines do not fail on a path
# that is not theirs.
# ---------------------------------------------------------------------
UPSTREAM="${YAMLLINT_UPSTREAM_CONFIG:-${HOME}/Developer/github-workflows/standards/yamllint.yml}"
VENDORED="${REPO_ROOT}/yamllint/config"
#
# The comparison runs through yamllint's OWN interpreter, not a bare python3:
# PyYAML is a yamllint dependency and is frequently absent from the system
# python3, in which case a naive check returns empty for both files and
# compares equal — a false pass. Resolving the interpreter from the yamllint
# entry point guarantees PyYAML is importable, and an empty parse is treated
# as an unusable comparator rather than as agreement.
if [[ -f "${UPSTREAM}" ]]; then
  # The shebang may carry flags (pipx writes `#!/path/to/python -E`), so take
  # the interpreter path only — the whole line is not a runnable path.
  _yl_python() {
    local shebang
    shebang="$(head -1 "$(command -v yamllint)" 2>/dev/null)"
    [[ "${shebang}" == '#!'* ]] || return 0
    shebang="${shebang#\#!}"
    printf '%s\n' "${shebang%% *}"
  }
  YL_PY="$(_yl_python)"
  if [[ -n "${YL_PY}" ]] && "${YL_PY}" -c 'import yaml' 2>/dev/null; then
    _rules() { "${YL_PY}" -c 'import sys,yaml; print(yaml.safe_load(open(sys.argv[1])))' "$1" 2>/dev/null; }
    up="$(_rules "${UPSTREAM}")"
    vd="$(_rules "${VENDORED}")"
    if [[ -z "${up}" || -z "${vd}" ]]; then
      _fail "could not parse one of the yamllint configs — comparison is unusable, not a pass"
    elif [[ "${up}" == "${vd}" ]]; then
      _pass "vendored yamllint config is rule-equivalent to upstream"
    else
      _fail "vendored yamllint/config has drifted from ${UPSTREAM}"
      diff -u <(echo "${up}") <(echo "${vd}") >&2 || true
    fi
  else
    echo "  SKIP: no PyYAML-capable interpreter, cannot compare parsed rules"
  fi
else
  echo "  SKIP: upstream checkout not present at ${UPSTREAM}"
fi

if ((fail)); then
  echo "FAIL: lint-yamllint config resolution"
  exit 1
fi
echo "OK: lint-yamllint config resolution"
