#!/usr/bin/env bash
#shellcheck shell=bash
# Standalone verification of the pre-push hook's bounded command runner.
# Run directly: bash bash/tests/test-pre-push-scan-timeout.sh
#
# The hook's Semgrep stage reaches the network. Unbounded, a slow or
# unreachable backend blocks a push indefinitely instead of degrading — first
# observed as the test suite appearing to hang when run from a linked
# worktree, where no warm Semgrep cache exists
# (smartwatermelon/dotfiles#251). The same stall can hit a real push on a slow
# network, so the bound lives in the hook itself.
#
# run_bounded is extracted from the hook and driven directly. Both of its
# implementations are exercised: GNU `timeout` when present, and the watchdog
# fallback for stock macOS, which ships no `timeout` (it arrives with Homebrew
# coreutils). Testing only whichever one this machine happens to have would
# leave the other silently unverified.
# `set -e` guards fixture setup, where a failing mktemp/chmod must abort loudly
# rather than let the cases run against a half-built fixture and report
# confusing results. It is lifted before the behavioral cases below, which
# deliberately capture non-zero exits from run_bounded and would otherwise
# abort the script on the first expected failure.
set -euo pipefail
unset CDPATH

REPO_ROOT="$(CDPATH='' cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HOOK="${REPO_ROOT}/git/hooks/pre-push"

fail=0
case_out=""

_pass() { echo "  PASS: $1"; }
_fail() {
  echo "  FAIL: $1" >&2
  fail=1
}

# Extract the runner through bash's own parser rather than slicing the hook
# with a text pattern, following test-allup-continue-state.sh
# (smartwatermelon/dotfiles#208).
#
# A `sed '/start/,/^}/p'` range would stop at the first column-0 `}`. That is
# correct only while no line inside run_bounded's body is itself a bare `}` —
# a nested block or case arm closing at column 0 would truncate the extraction
# mid-function, and brace counting cannot tell the two apart either. Asking
# bash is the only approach immune to how the source happens to be formatted.
#
# The hook runs its checks at source time, so it cannot be sourced directly.
# The function's text is isolated first, parsed in a clean subshell, and then
# reprinted by `declare -f` — so what this test drives is what bash parsed,
# not what a regex guessed at.
# Brace-balance from the function header to its true close, so the slice ends at
# run_bounded's own `}` regardless of indentation — unlike a
# `sed '/start/,/^}/p'` range, which stops at the first column-0 `}` and would
# truncate mid-function if a nested block ever closed there.
#
# Comments are stripped before counting. Counting raw characters treats a `{` in
# a comment or URL as structure, which skews the depth and makes the slice
# over-run into whatever follows the function
# (smartwatermelon/dotfiles#260). Verified against a body carrying
# `# see https://example.com/{path`, which over-ran before this and does not now.
#
# The stripping is only for the COUNT; the printed lines are the originals, so
# the extracted body is byte-identical to the source.
#
# `sub(/#.*/, "")` also strips a `#` inside a quoted string, which would
# under-count a brace that really is structure. That is the safe direction: it
# can only end the slice early, and bash then fails to parse the truncation, so
# the guards below report which stage failed rather than the test running on a
# partial function. Verified by hiding an unbalanced `}` in a string inside
# run_bounded: the test fails with an explicit message naming the extraction.
# A shell-accurate tokenizer is not worth writing here. bash then parses it and
# `declare -f` reprints it, so what the cases drive is a function bash accepted,
# not a region awk guessed at.
_raw_body="$(awk '
  /^run_bounded\(\)/ { collecting = 1 }
  collecting {
    print
    counted = $0
    sub(/#.*/, "", counted)
    n = gsub(/\{/, "{", counted); depth += n
    n = gsub(/\}/, "}", counted); depth -= n
    if (depth == 0 && seen_open) { exit }
    if (depth > 0) { seen_open = 1 }
  }
' "${HOOK}")"

# `|| RUNNER_SRC=""`, because a bare command-substitution assignment that exits
# non-zero would abort the script under `set -e` — silently, before the
# diagnostic guards below could say why. A truncated slice must produce an
# explanation, not an empty exit 1.
RUNNER_SRC="$(bash --norc --noprofile -c '
  eval "$1" || exit 1
  declare -f run_bounded
' _ "${_raw_body}" 2>/dev/null)" || RUNNER_SRC=""

if [[ -n "${RUNNER_SRC}" ]]; then
  _timeout_default="$(grep -E '^SEMGREP_TIMEOUT_SECS=' "${HOOK}" | head -1)" || _timeout_default=""
  RUNNER_SRC="$(printf '%s\n%s\n' "${_timeout_default}" "${RUNNER_SRC}")"
fi

if [[ -z "${RUNNER_SRC}" ]]; then
  echo "FAIL: could not extract run_bounded from ${HOOK}" >&2
  echo "      (it may have been renamed or removed — the Semgrep scan would" >&2
  echo "       then be unbounded again, which is #251)" >&2
  exit 1
fi
# Guard against a partial extraction that would silently under-test.
if [[ "${RUNNER_SRC}" != *"run_bounded"* ]]; then
  echo "FAIL: extracted block does not define run_bounded()" >&2
  exit 1
fi
# Guard against a partial extraction that would silently under-test: the
# parsed body must retain the 124 expiry normalization the cases assert on.
if [[ "${RUNNER_SRC}" != *"124"* ]]; then
  echo "FAIL: extracted run_bounded lacks the 124 expiry normalization" >&2
  echo "      (extraction truncated, or the expiry contract changed)" >&2
  exit 1
fi

# Confirm the hook actually ROUTES its scans through the runner. A runner that
# exists but is not called leaves the scan unbounded while this test reports
# green — the defect class that made #251 invisible in the first place.
echo "Case: the hook routes its Semgrep scans through the bounded runner"
scan_calls="$(grep -cE '^[[:space:]]*(if ! )?run_bounded .* semgrep ' "${HOOK}")"
if ((scan_calls >= 2)); then
  _pass "both the token and fallback scans call run_bounded (${scan_calls} sites)"
else
  _fail "expected 2 bounded semgrep call sites, found ${scan_calls}"
fi
if grep -qE '^[[:space:]]*semgrep (ci|scan|")' "${HOOK}"; then
  _fail "an unbounded bare 'semgrep' invocation remains in the hook"
else
  _pass "no unbounded bare 'semgrep' invocation remains"
fi

# ---------------------------------------------------------------
# Behavioral cases, run against both implementations
# ---------------------------------------------------------------
# force_fallback=1 shadows `command -v` so run_bounded cannot find
# timeout/gtimeout and must take its watchdog branch.
#
# The driver is written to a file rather than passed as a single-quoted `-c`
# string. A quoted script body containing parameter expansions is read as an
# unexpanded expression (SC2016) by the linter, and this repo resolves such
# findings rather than suppressing them.
WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/pre-push-timeout-test.XXXXXX")"
trap 'rm -rf "${WORKDIR}"' EXIT

DRIVER="${WORKDIR}/driver.sh"
cat >"${DRIVER}" <<'DRIVER_EOF'
#!/usr/bin/env bash
# Args: <force_fallback> <budget_secs> <command...>
force_fallback="$1"
secs="$2"
shift 2

source "${RUNNER_FILE}"

if [[ "${force_fallback}" == "1" ]]; then
  command() {
    if [[ "$1" == "-v" && ( "$2" == "timeout" || "$2" == "gtimeout" ) ]]; then
      return 1
    fi
    builtin command "$@"
  }
fi

start=${SECONDS}
# The command's own output goes to /dev/null, NOT to this script's stdout.
#
# This driver runs inside a command substitution, so its stdout is a pipe the
# caller reads until every writer closes it. A command that leaves a child
# behind — which the watchdog fallback does, since it kills a pid rather than
# a process group (dotfiles#350) — leaves that child holding the pipe open.
# The caller then blocks for the child's full lifetime even though
# run_bounded returned promptly.
#
# Measured before this redirect: the SIGTERM-ignoring case returned rc=124 in
# 4s of measured time while the command substitution took 60s to close. Three
# such cases were 180s of this file's 197s runtime. Only the line below is
# read by the caller, so discarding the command's output costs no coverage.
run_bounded "${secs}" "$@" >/dev/null 2>&1
rc=$?
echo "${rc} $((SECONDS - start))"
DRIVER_EOF
chmod +x "${DRIVER}"

RUNNER_FILE="${WORKDIR}/runner.sh"
printf '%s\n' "${RUNNER_SRC}" >"${RUNNER_FILE}"
export RUNNER_FILE

TEST_BASH="${BASH:-bash}"

run_case() {
  "${TEST_BASH}" "${DRIVER}" "$@"
}

# Wall clock for the whole command substitution, set by every run_case call
# below via _timed.
#
# This is deliberately measured OUTSIDE the pipe, because the driver's own
# elapsed count is measured inside it and cannot see the failure it needs to
# report. When an orphaned child held the pipe open (dotfiles#350), the driver
# reported 4s while the caller blocked for 60s — and every assertion in this
# file passed, because all of them read the driver's number. A test that
# cannot observe its own 15x overrun has a blind spot exactly where its
# subject matter is.
#
# Every timing case below asserts on BOTH: the inner number for run_bounded's
# behavior, this one for what the caller actually experienced.
CASE_WALL=0
_timed() {
  local _t0=${SECONDS}
  case_out="$(_timed_inner "$@")"
  CASE_WALL=$((SECONDS - _t0))
}
# Indirection so `_timed` can wrap an environment-prefixed call the same way
# it wraps a bare one.
_timed_inner() {
  if [[ "$1" == *=* ]]; then
    local _assign="$1"
    shift
    env "${_assign}" "${TEST_BASH}" "${DRIVER}" "$@"
  else
    run_case "$@"
  fi
}

# Fixture setup is complete. The cases below assert on non-zero exit codes as
# their subject matter, so `-e` must not apply to them.
set +e

for mode in timeout fallback; do
  force=0
  label="GNU timeout"
  if [[ "${mode}" == "fallback" ]]; then
    force=1
    label="watchdog fallback"
  fi

  echo "Case: run_bounded behavior — ${label}"

  # A command that outlives its budget is terminated and reported as 124,
  # matching coreutils' expiry convention.
  #
  # Budget 1s against a 10s command. The budget cannot go below 1: the
  # watchdog's wait loop polls in `sleep 1` steps, so a sub-second budget is
  # not representable on that path. 10s for the command keeps a clear ratio
  # against the budget while bounding how long a leaked child could linger.
  _timed "${force}" 1 sleep 10
  read -r rc elapsed <<<"${case_out}"
  if [[ "${rc}" == "124" ]]; then
    _pass "${label}: an over-budget command exits 124"
  else
    _fail "${label}: over-budget command exited ${rc}, expected 124"
  fi
  # The assertion is "bounded", not "bounded precisely". The ceiling is well
  # clear of the 1s budget plus SIGKILL escalation, but far below the 10s the
  # command would run unbounded — so a loaded runner cannot flake it, while a
  # genuinely unbounded run still fails. `SECONDS` has 1-second granularity,
  # which the margin absorbs.
  if ((elapsed <= 6)); then
    _pass "${label}: terminated near the budget (${elapsed}s of a 10s command)"
  else
    _fail "${label}: took ${elapsed}s for a 1s budget — not actually bounded"
  fi
  if ((CASE_WALL <= 6)); then
    _pass "${label}: the caller also returned in ${CASE_WALL}s"
  else
    _fail "${label}: run_bounded reported ${elapsed}s but the caller blocked ${CASE_WALL}s — a child outlived the kill (#350)"
  fi

  # Success and failure statuses must pass through untouched, or the hook
  # would misread a clean scan as an infrastructure error and vice versa.
  case_out="$(run_case "${force}" 10 true)"
  read -r rc _ <<<"${case_out}"
  if [[ "${rc}" == "0" ]]; then
    _pass "${label}: a successful command still reports 0"
  else
    _fail "${label}: successful command reported ${rc}, expected 0"
  fi

  case_out="$(run_case "${force}" 10 false)"
  read -r rc _ <<<"${case_out}"
  if [[ "${rc}" == "1" ]]; then
    _pass "${label}: a failing command's status passes through"
  else
    _fail "${label}: failing command reported ${rc}, expected 1"
  fi

  # An under-budget command must return as soon as it finishes rather than
  # waiting out the whole budget.
  _timed "${force}" 5 sleep 1
  read -r rc elapsed <<<"${case_out}"
  # The point is that the watchdog does not hold the budget open after the
  # command finishes. Returning in well under the 5s budget proves that; the
  # margin absorbs `SECONDS`' 1-second granularity and shell overhead on a
  # saturated runner.
  if [[ "${rc}" == "0" ]] && ((elapsed < 4)); then
    _pass "${label}: returns when the command finishes (${elapsed}s of a 5s budget)"
  else
    _fail "${label}: exit ${rc} after ${elapsed}s — expected 0 in well under 5s"
  fi
  if ((CASE_WALL < 4)); then
    _pass "${label}: the caller also returned early (${CASE_WALL}s)"
  else
    _fail "${label}: caller blocked ${CASE_WALL}s on a 1s command — a child outlived it (#350)"
  fi
done

# ---------------------------------------------------------------
# The SIGKILL escalation branch
# ---------------------------------------------------------------
# The cases above all terminate on SIGTERM, so the grace loop exits early and
# the `kill -KILL` line never runs. That left the escalation branch with no
# coverage at all: a future edit could break it and every test would still pass
# (smartwatermelon/dotfiles#262).
#
# A command that IGNORES SIGTERM forces the escalation. It must still be
# terminated, and within the grace budget rather than running to its own length.
echo "Case: run_bounded escalates to SIGKILL for a SIGTERM-ignoring command"

IGNORER="${WORKDIR}/ignores-sigterm.sh"
cat >"${IGNORER}" <<'IGNORER_EOF'
#!/usr/bin/env bash
# Survives SIGTERM; only SIGKILL can stop this.
#
# The `sleep` is a foreground CHILD of this script, and it does NOT die with
# it on the watchdog path. An earlier version of this comment claimed the
# opposite — "killing this script tears it down with it... none left behind"
# — and that is measurably false: `kill -KILL <script-pid>` leaves the sleep
# running, because the watchdog signals a pid rather than a process group.
# That is the hook defect tracked in dotfiles#350; GNU `timeout` signals the
# group and does tear it down, which is why only the fallback path was slow.
#
# The child shape is kept deliberately rather than collapsed into an `exec`:
# semgrep spawns workers, so a fixture whose children outlive it is the
# representative case, and #350's eventual fix needs it to assert against.
# The driver redirects this command's output away from the caller's pipe, so
# a leaked child no longer holds the command substitution open.
trap '' TERM
sleep 10
IGNORER_EOF
chmod +x "${IGNORER}"

for mode in timeout fallback; do
  force=0
  label="GNU timeout"
  if [[ "${mode}" == "fallback" ]]; then
    force=1
    label="watchdog fallback"
  fi

  _timed "${force}" 1 "${IGNORER}"
  read -r rc elapsed <<<"${case_out}"

  # GNU timeout reports 124 on expiry; the fallback normalizes SIGKILL's 137 to
  # 124 itself. Either way the caller must see the expiry code.
  if [[ "${rc}" == "124" ]]; then
    _pass "${label}: a SIGTERM-ignoring command is still reported as expired"
  else
    _fail "${label}: SIGTERM-ignoring command exited ${rc}, expected 124"
  fi

  # The escalation must actually land. Unterminated, the command runs 10s.
  # 1s budget + 2s default grace lands near 3s, so a ceiling of 6 separates a
  # working escalation from one that never fires without depending on exact
  # scheduling.
  if ((elapsed <= 6)); then
    _pass "${label}: escalation killed it in ${elapsed}s, not its full 10s"
  else
    _fail "${label}: took ${elapsed}s — the SIGKILL escalation did not land"
  fi
  if ((CASE_WALL <= 6)); then
    _pass "${label}: the caller also returned in ${CASE_WALL}s"
  else
    _fail "${label}: run_bounded reported ${elapsed}s but the caller blocked ${CASE_WALL}s — the killed command left a child holding the pipe (#350)"
  fi
done

# ---------------------------------------------------------------
# A signal death inside the budget is not an expiry
# ---------------------------------------------------------------
# The fallback used to relabel any 143/137 as 124, so a command killed by an
# external SIGTERM well inside its budget was reported as a timeout
# (smartwatermelon/dotfiles#266).
#
# The fixture signals ITSELF rather than the test hunting for the process with
# pkill. Both `pkill -f "sleep N"` and `pkill -x -n sleep` were tried and are
# unreliable here: -f also matches the driver shells, which carry the command in
# their own argv, and -n races against the test's own helper sleeps. A
# self-signalling fixture needs no process discovery at all, so the case cannot
# flake on which process the pattern happened to match.
echo "Case: an external signal inside the budget is not reported as expiry"

SELF_SIGNALLER="${WORKDIR}/self-sigterm.sh"
cat >"${SELF_SIGNALLER}" <<'SIGNALLER_EOF'
#!/usr/bin/env bash
# Dies by SIGTERM after 1s, well inside any budget this case uses. Stands in for
# any external kill — an operator, an OOM reaper, a parent tearing down.
sleep 1
kill -TERM $$
sleep 10
SIGNALLER_EOF
chmod +x "${SELF_SIGNALLER}"

_timed 1 10 "${SELF_SIGNALLER}"
read -r rc elapsed <<<"${case_out}"

if [[ "${rc}" == "143" ]]; then
  _pass "watchdog fallback: a SIGTERM inside the budget reports 143, not the expiry code"
elif [[ "${rc}" == "124" ]]; then
  _fail "watchdog fallback: a signal death was mislabelled as an expiry (124)"
else
  _fail "watchdog fallback: signal death reported ${rc}, expected 143"
fi

if ((elapsed < 5)); then
  _pass "watchdog fallback: returned on the signal (${elapsed}s), not at the 10s budget"
else
  _fail "watchdog fallback: took ${elapsed}s — did not return on the signal"
fi
if ((CASE_WALL < 5)); then
  _pass "watchdog fallback: the caller also returned on the signal (${CASE_WALL}s)"
else
  _fail "watchdog fallback: caller blocked ${CASE_WALL}s — a child outlived the signalled process (#350)"
fi

# ---------------------------------------------------------------
# run_bounded must survive its caller returning
# ---------------------------------------------------------------
# A `trap ... RETURN` set inside run_bounded is NOT scoped to run_bounded: it
# stays armed and fires again when the CALLER returns, when the function's
# `local` is out of scope and `set -u` aborts with "expiry_marker: unbound
# variable". That shipped and turned CI red while every local run passed,
# because this machine has coreutils `timeout` and never took the branch that
# set the trap (smartwatermelon/dotfiles#268).
#
# The cases above all invoke run_bounded at the top level, so none of them would
# have caught it. This one calls it from inside a function and then returns,
# under `set -eu`, which is how the hook actually uses it.
echo "Case: run_bounded does not corrupt its caller's scope"

SCOPE_PROBE="${WORKDIR}/scope-probe.sh"
cat >"${SCOPE_PROBE}" <<SCOPE_EOF
set -euo pipefail
source "${RUNNER_FILE}"
outer() {
  run_bounded 5 true
  echo "inner-ok"
}
outer
echo "caller-ok"
SCOPE_EOF

for mode in timeout fallback; do
  label="GNU timeout"
  probe_path="${PATH}"
  if [[ "${mode}" == "fallback" ]]; then
    label="watchdog fallback"
    # Strip the directories carrying timeout/gtimeout, reproducing a stock macOS
    # box — which is exactly what the CI runner is, and where this bug lived.
    probe_path="/usr/bin:/bin"
  fi

  if scope_out="$(PATH="${probe_path}" "${TEST_BASH}" "${SCOPE_PROBE}" 2>&1)"; then
    if [[ "${scope_out}" == *"caller-ok"* ]]; then
      _pass "${label}: the caller returns normally after run_bounded"
    else
      _fail "${label}: caller did not complete — output: ${scope_out}"
    fi
  else
    _fail "${label}: run_bounded aborted its caller — output: ${scope_out}"
  fi
done

# ---------------------------------------------------------------
# The fallback grace budget honors SEMGREP_TIMEOUT_KILL_GRACE
# ---------------------------------------------------------------
# The GNU path passes this variable to `timeout --kill-after`, but the fallback
# grace loop used to hardcode 20 iterations (2s at 0.1s per step) and ignore it
# entirely. Raising the variable had no effect on the fallback path, so the two
# branches disagreed about the same knob (smartwatermelon/dotfiles#279).
#
# Measured against a SIGTERM-ignoring command, which is the only input that
# reaches the escalation loop at all. A raised grace must visibly outlast the
# 2s default before SIGKILL lands.
#
# The grace cannot be scaled below 1: run_bounded validates it against
# `^[0-9]+$` and multiplies by 10 for its 0.1s poll steps, so a fractional
# value is rejected and falls back to the default — which would make this
# case assert the default against itself. 4s is the smallest raised value
# that stays separable from the 2s default at `SECONDS`' 1-second
# granularity: 1s budget + 4s grace lands near 5s against the default's ~3s.
echo "Case: the fallback grace loop honors SEMGREP_TIMEOUT_KILL_GRACE"

_timed SEMGREP_TIMEOUT_KILL_GRACE=4 1 1 "${IGNORER}"
read -r rc elapsed <<<"${case_out}"

if [[ "${rc}" == "124" ]]; then
  _pass "watchdog fallback: a raised grace still reports the expiry code"
else
  _fail "watchdog fallback: expected 124 with a raised grace, got ${rc}"
fi

# 1s budget + 4s grace = ~5s. The hardcoded 2s grace would land near 3s, so a
# lower bound of 4s separates the two without depending on exact scheduling.
if ((elapsed >= 4)); then
  _pass "watchdog fallback: grace of 4s was honored (escalated at ${elapsed}s)"
else
  _fail "watchdog fallback: escalated at ${elapsed}s — the grace loop ignored SEMGREP_TIMEOUT_KILL_GRACE"
fi

# A non-numeric value must not break the arithmetic under `set -e`; it falls
# back to the same 2s default the GNU path uses.
_timed SEMGREP_TIMEOUT_KILL_GRACE=bogus 1 1 "${IGNORER}"
read -r rc elapsed <<<"${case_out}"

if [[ "${rc}" == "124" ]]; then
  _pass "watchdog fallback: a non-numeric grace falls back instead of aborting"
else
  _fail "watchdog fallback: non-numeric grace exited ${rc}, expected 124"
fi

# The fallback must land near the 2s DEFAULT, not run to the command's full
# length. Without this, "falls back" is asserted only by the exit code, which
# a grace loop that ignored the value entirely would also satisfy.
if ((elapsed <= 6)); then
  _pass "watchdog fallback: non-numeric grace used the default (${elapsed}s)"
else
  _fail "watchdog fallback: took ${elapsed}s — did not fall back to the 2s default"
fi

echo
if ((fail)); then
  echo "SOME CHECKS FAILED" >&2
  exit 1
fi
echo "test-pre-push-scan-timeout: all cases passed"
