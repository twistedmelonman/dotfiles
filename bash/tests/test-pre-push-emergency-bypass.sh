#!/usr/bin/env bash
#shellcheck shell=bash
# Standalone verification of the pre-push hook's EMERGENCY=1 bypass.
# Run directly: bash bash/tests/test-pre-push-emergency-bypass.sh
#
# EMERGENCY=1 skips the project-local extension stage — where repos put their
# test suites — so a declared emergency does not pay the suite's runtime
# (smartwatermelon/dev-env#112). The risk with any bypass is that it is wider
# than intended, or that it quietly stops gating anything at all, so the
# behavior is pinned here rather than left to inspection.
#
# run_project_extensions is extracted from the hook and driven directly, with
# `git` and the loggers stubbed. Extracting keeps the test from needing a real
# push, while still exercising the hook's own source rather than a copy that
# can drift.
#
# Four cases, because the two obvious ones cannot distinguish a working gate
# from a broken one:
#   A  unset      -> extension RUNS      (baseline: the stage works at all)
#   B  =1         -> extension SKIPPED   (the feature)
#   C  =0         -> extension RUNS      (not "any value is truthy")
#   D  unset+fail -> push BLOCKED        (the gate still blocks when off)
# Without C, a mistakenly always-skipping gate passes A and B. Without D, a
# gate that swallowed failures would look identical to a working one.
set -euo pipefail
unset CDPATH

REPO_ROOT="$(CDPATH='' cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HOOK="${REPO_ROOT}/git/hooks/pre-push"

if [[ ! -f "${HOOK}" ]]; then
  echo "FAIL: hook not found at ${HOOK}" >&2
  exit 1
fi

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

mkdir -p "${WORK}/fakerepo/.project-hooks"

# Build a harness around the real function body. `git` is stubbed to report the
# fixture as the repo root, so no actual repository is required.
build_harness() {
  {
    echo 'set -uo pipefail'
    echo 'log() { echo "[log] $*"; }'
    echo 'log_warning() { echo "[warn] $*"; }'
    printf 'git() { echo "%s/fakerepo"; }\n' "${WORK}"
    sed -n '/^run_project_extensions() {/,/^}/p' "${HOOK}"
    echo 'run_project_extensions'
    echo 'echo "RC=$?"'
  } >"${WORK}/harness.sh"
}

write_extension() {
  # $1: exit code the fake suite returns
  printf '#!/usr/bin/env bash\necho "SUITE RAN"\nexit %s\n' "$1" \
    >"${WORK}/fakerepo/.project-hooks/pre-push"
  chmod +x "${WORK}/fakerepo/.project-hooks/pre-push"
}

build_harness

# Guard: the extraction must actually have found the function. An empty or
# malformed harness would otherwise "pass" every case by doing nothing.
if ! grep -q 'run_project_extensions()' "${WORK}/harness.sh"; then
  echo "FAIL: could not extract run_project_extensions from ${HOOK}" >&2
  exit 1
fi

set +e
failures=0

check() {
  # $1: label  $2: expected-substring  $3: actual output  $4: want|wantnot
  local label="$1" needle="$2" actual="$3" mode="$4"
  if [[ "${mode}" == "want" ]]; then
    if grep -qF "${needle}" <<<"${actual}"; then
      echo "  PASS: ${label}"
    else
      echo "  FAIL: ${label} — expected to find '${needle}'"
      echo "${actual}" | sed 's/^/        /'
      failures=$((failures + 1))
    fi
  else
    if grep -qF "${needle}" <<<"${actual}"; then
      echo "  FAIL: ${label} — did not expect '${needle}'"
      echo "${actual}" | sed 's/^/        /'
      failures=$((failures + 1))
    else
      echo "  PASS: ${label}"
    fi
  fi
}

echo "Case A: EMERGENCY unset — extension runs"
write_extension 0
out_a="$(bash "${WORK}/harness.sh" 2>&1)"
check "suite ran" "SUITE RAN" "${out_a}" want
check "returned 0" "RC=0" "${out_a}" want

echo "Case B: EMERGENCY=1 — extension skipped"
out_b="$(EMERGENCY=1 bash "${WORK}/harness.sh" 2>&1)"
check "suite did NOT run" "SUITE RAN" "${out_b}" wantnot
check "bypass announced" "EMERGENCY=1" "${out_b}" want
check "returned 0" "RC=0" "${out_b}" want

echo "Case C: EMERGENCY=0 — extension runs (not any-value)"
out_c="$(EMERGENCY=0 bash "${WORK}/harness.sh" 2>&1)"
check "suite ran" "SUITE RAN" "${out_c}" want

echo "Case D: failing suite, no emergency — still blocks"
write_extension 1
out_d="$(bash "${WORK}/harness.sh" 2>&1)"
check "failure reported" "failed — fix before pushing" "${out_d}" want
check "did not reach RC line (hook exited)" "RC=" "${out_d}" wantnot

echo
if ((failures > 0)); then
  echo "FAILED: ${failures} assertion(s)"
  exit 1
fi
echo "PASSED: all assertions"
