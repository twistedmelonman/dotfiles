#!/usr/bin/env bash
# shellcheck shell=bash
# Standalone verification for bash/gpush-wrapper.sh's failed-CI detail
# (_gpush_print_failure_detail). Run directly:
#   bash bash/tests/test-gpush-wrapper-failure-detail.sh
#
# smartwatermelon/dev-env#113: when a CI run fails, gpush printed only
# "CI failed (Standards Check: failure)". It must also print what the run
# reported: the failed job's check-run annotations (titled, oldest first,
# notices and the runner's exit-code line dropped), bounded in length, with a
# fallback to the "##[error]" lines of the failed-step log when there are no
# annotations, and the job URL.
#
# gpush runs end to end against stub `git` and `gh` binaries on PATH, so no
# real remote or GitHub state is touched. The stub gh evaluates each -q/--jq
# expression with the real jq, so the wrapper's own filters are what is tested.
# The fixture JSON shapes (annotation fields, newest-first order, the job
# databaseId doubling as the check-run id) were measured 2026-09-25 against
# twistedmelonman/claude-config run 35944355297 and its job 107458893019.
set -uo pipefail

unset CDPATH
# functions.sh defines `gh` and `git` shell functions that would win over the
# PATH stubs if a child bash sourced it through BASH_ENV.
unset BASH_ENV

REPO_ROOT="$(CDPATH='' cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
_tests_dir="$(CDPATH='' cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/git-env-isolation.sh
source "${_tests_dir}/lib/git-env-isolation.sh"
isolate_git_env

WRAPPER="${GPUSH_WRAPPER_UNDER_TEST:-${REPO_ROOT}/bash/gpush-wrapper.sh}"

if ! command -v jq >/dev/null 2>&1; then
  echo "FAIL: jq is required by the stub gh and is not installed"
  exit 1
fi

WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/gpush-failure-detail.XXXXXX")" || exit 1
trap 'rm -rf "${WORKDIR}"' EXIT
STUBS="${WORKDIR}/stubs"
mkdir -p "${STUBS}"

cat >"${STUBS}/git" <<'STUB'
#!/usr/bin/env bash
case "$1" in
  symbolic-ref) echo "feature-x" ;;
  rev-parse) echo "abcdef1234567890abcdef1234567890abcdef12" ;;
  *) exit 0 ;;
esac
STUB

# sleep is stubbed so the wrapper's re-poll delay does not slow the test.
cat >"${STUBS}/sleep" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB

# The stub gh reads its fixtures from STUB_DIR:
#   conclusion        the run conclusion
#   jobs.json         `gh run view --json jobs` payload
#   annotations.json  check-run annotations payload
#   log.txt           `gh run view --log-failed` output
# and appends each invocation to STUB_DIR/calls.
cat >"${STUBS}/gh" <<'STUB'
#!/usr/bin/env bash
echo "$*" >>"${STUB_DIR}/calls"
q=""
args=("$@")
for ((i = 0; i < ${#args[@]}; i++)); do
  case "${args[i]}" in
    -q | --jq) q="${args[i + 1]}" ;;
  esac
done
filter() {
  if [[ -n "${q}" ]]; then jq -r "${q}"; else cat; fi
}
case "$1 $2" in
  "pr create") echo "https://github.com/o/r/pull/7" ;;
  "run list") printf '101\tStandards Check\n' ;;
  "run watch") exit 0 ;;
  "run view")
    if [[ " $* " == *" --log-failed "* ]]; then
      cat "${STUB_DIR}/log.txt"
    elif [[ " $* " == *" conclusion "* ]]; then
      cat "${STUB_DIR}/conclusion"
    else
      filter <"${STUB_DIR}/jobs.json"
    fi
    ;;
  "api repos/{owner}/{repo}/check-runs/555/annotations") filter <"${STUB_DIR}/annotations.json" ;;
  *)
    echo "stub gh: unexpected call: $*" >&2
    exit 1
    ;;
esac
STUB
chmod +x "${STUBS}"/*

# Sources the wrapper under test ($1) and runs gpush with the rest.
cat >"${WORKDIR}/run-gpush.sh" <<'RUNNER'
# shellcheck source=/dev/null
source "$1"
shift
gpush "$@"
RUNNER

JOBS_JSON='{"jobs":[
  {"databaseId":554,"name":"setup","conclusion":"success","url":"https://github.com/o/r/actions/runs/101/job/554"},
  {"databaseId":555,"name":"standards-check / run-standards-check","conclusion":"failure","url":"https://github.com/o/r/actions/runs/101/job/555"}
]}'

fail=0
_pass() { echo "PASS: $1"; }
_fail() {
  echo "FAIL: $1"
  fail=1
}

# new_case <name>: make a fresh fixture dir with a failed run and the jobs list.
new_case() {
  CASE_DIR="${WORKDIR}/$1"
  mkdir -p "${CASE_DIR}"
  echo "failure" >"${CASE_DIR}/conclusion"
  printf '%s\n' "${JOBS_JSON}" >"${CASE_DIR}/jobs.json"
  echo '[]' >"${CASE_DIR}/annotations.json"
  : >"${CASE_DIR}/log.txt"
}

# run_gpush [args...]: run gpush in a clean child bash with the stubs first on
# PATH. Sets OUT (stdout+stderr, colour codes stripped) and RC.
run_gpush() {
  OUT="$(STUB_DIR="${CASE_DIR}" PATH="${STUBS}:${PATH}" /usr/bin/env bash \
    "${WORKDIR}/run-gpush.sh" "${WRAPPER}" "$@" 2>&1)"
  RC=$?
  OUT="$(printf '%s' "${OUT}" | sed $'s/\033\\[[0-9;]*m//g')"
}

contains() { [[ "${OUT}" == *"$1"* ]]; }

# Case 1: annotations in the post-#176 standards-check format. The API returns
# them newest first; the linter's own titled, multi-line annotation must be
# printed, before the summary line, without notices or the exit-code line.
new_case annotations
cat >"${CASE_DIR}/annotations.json" <<'JSON'
[
  {"path":".github","start_line":75,"annotation_level":"failure","title":"","message":"Process completed with exit code 1."},
  {"path":".github","start_line":74,"annotation_level":"failure","title":"","message":"standards-check failed: shellcheck"},
  {"path":".github","start_line":69,"annotation_level":"notice","title":"","message":"no Markdown files"},
  {"path":".github","start_line":58,"annotation_level":"failure","title":"shellcheck","message":"shellcheck found problems\nIn scripts/foo.sh line 3:\necho $1\n     ^-- SC2086 (info): Double quote to prevent globbing and word splitting."},
  {"path":".github","start_line":1,"annotation_level":"notice","title":"","message":"The ubuntu-latest label will migrate to Ubuntu 26"}
]
JSON
run_gpush
if [[ ${RC} -ne 0 ]]; then _pass "failed CI still exits non-zero"; else _fail "failed CI exited 0"; fi
if contains "CI failed (Standards Check: failure)"; then
  _pass "summary line is kept"
else
  _fail "summary line missing"
fi
if contains "shellcheck: shellcheck found problems" && contains "SC2086"; then
  _pass "linter annotation title and finding are printed"
else
  _fail "linter annotation title or finding missing"
fi
if contains "standards-check failed: shellcheck"; then
  _pass "final error annotation is printed"
else
  _fail "final error annotation missing"
fi
if contains "no Markdown files" || contains "ubuntu-latest" || contains "Process completed with exit code"; then
  _fail "notice or exit-code annotations were printed"
else
  _pass "notices and the exit-code line are dropped"
fi
line_linter="$(printf '%s\n' "${OUT}" | grep -n 'SC2086' | head -1 | cut -d: -f1)"
line_summary="$(printf '%s\n' "${OUT}" | grep -n 'standards-check failed: shellcheck' | head -1 | cut -d: -f1)"
if [[ -n "${line_linter}" && -n "${line_summary}" && "${line_linter}" -lt "${line_summary}" ]]; then
  _pass "annotations are printed oldest first"
else
  _fail "annotations are not in emitted order (linter line ${line_linter:-none}, summary line ${line_summary:-none})"
fi
if contains "Details: https://github.com/o/r/actions/runs/101/job/555"; then
  _pass "failed job URL is printed"
else
  _fail "failed job URL missing"
fi
if grep -q 'check-runs/554' "${CASE_DIR}/calls"; then
  _fail "a successful job was queried for annotations"
else
  _pass "only the failed job is queried"
fi
if [[ "${fail}" -ne 0 ]]; then
  printf '%s\n' "${OUT}" | sed 's/^/    /'
fi

# Case 2: no annotations -> the "##[error]" lines of the failed-step log.
new_case log-fallback
cat >"${CASE_DIR}/log.txt" <<'LOG'
standards-check / run-standards-check	UNKNOWN STEP	2026-09-24T01:46:08.1Z [command]/usr/bin/git checkout noise
standards-check / run-standards-check	UNKNOWN STEP	2026-09-24T01:46:08.3Z ##[error]shellcheck found problems
standards-check / run-standards-check	UNKNOWN STEP	2026-09-24T01:46:08.4Z ##[error]Process completed with exit code 1.
LOG
run_gpush
if contains "shellcheck found problems" && ! contains "checkout noise" && ! contains "Process completed with exit code"; then
  _pass "empty annotations fall back to the log's error lines only"
else
  _fail "log fallback printed the wrong lines"
  printf '%s\n' "${OUT}" | sed 's/^/    /'
fi

# Case 3: output is bounded. A 100-line annotation prints at most 40 lines.
new_case bounded
jq -n '[{"path":".github","start_line":5,"annotation_level":"failure","title":"shellcheck",
  "message":([range(1;101)] | map("finding-\(.)") | join("\n"))}]' >"${CASE_DIR}/annotations.json"
run_gpush
if contains "finding-39" && ! contains "finding-41" && contains "more line(s) not shown"; then
  _pass "long annotations are cut to the line limit with a count"
else
  _fail "long annotations were not bounded"
fi

# Case 4: a passing run prints no failure detail and queries no annotations.
new_case success
echo "success" >"${CASE_DIR}/conclusion"
run_gpush --no-merge
if [[ ${RC} -eq 0 ]] && ! contains "reported:" && ! grep -q 'annotations' "${CASE_DIR}/calls"; then
  _pass "a passing run prints no failure detail"
else
  _fail "a passing run printed failure detail or failed (rc=${RC})"
  printf '%s\n' "${OUT}" | sed 's/^/    /'
fi

if [[ "${fail}" -ne 0 ]]; then
  echo "FAILED"
  exit 1
fi
echo "All gpush-wrapper failure-detail tests passed"
