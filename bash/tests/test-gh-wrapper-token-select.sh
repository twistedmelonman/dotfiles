#!/usr/bin/env bash
# Per-invocation token selection in bash/gh-wrapper.sh
# (smartwatermelon/claude-wrapper#126, decisions 1-3):
#
#   1. When GH_TOKEN is set and the resolved owner maps to a GH_TOKEN_SWM /
#      GH_TOKEN_NOS / GH_TOKEN_TWM variable that is set, that token is used for
#      the call. It replaces the old owner-mismatch refusal, and the
#      CLAUDE_GH_TOKEN_ROUTER hook is gone.
#   2. `gh api repos/OWNER/...` (with or without a leading slash) resolves
#      OWNER from the endpoint, not from cwd.
#   3. With no owner resolved, the launch token is kept; if the call fails, one
#      stderr line tells the agent to stop and ask instead of guessing. The exit
#      code is unchanged.
#
# Every case runs in BOTH modes: standalone (bash gh-wrapper.sh ...) and
# function (source gh-wrapper.sh; gh ...). Function mode reaches the real gh
# the way production does: `command gh` finds a symlink to the wrapper first on
# PATH, which then finds the stub.
#
# KNOWN-BAD against origin/main: the "cross-owner" cases fail (the call is
# refused), the "api repos/OTHER" cases fail (cwd's token is used), the
# stop-line cases fail (no line), and the router case fails (hook sourced).
#
# All tokens are stub strings. The real per-owner variables are unset first so
# nothing from the caller's environment reaches the stub.
set -uo pipefail
unset CDPATH

TESTS_DIR="$(CDPATH='' cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WRAPPER="${TESTS_DIR}/../gh-wrapper.sh"

WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/gh-token-select-test.XXXXXX")"
trap 'rm -rf "${WORKDIR}"' EXIT

unset GH_TOKEN GITHUB_TOKEN GH_HOST CLAUDE_GH_TOKEN_LOGIN CLAUDE_GH_TOKEN_ROUTER
unset GH_TOKEN_SWM GH_TOKEN_NOS GH_TOKEN_TWM _GH_REVIEW_DONE _gh_wrapper_review_script

GIT=/usr/bin/git
fail=0
_pass() { echo "  PASS: $1"; }
_fail() {
  echo "  FAIL: $1" >&2
  fail=1
}

export HOME="${WORKDIR}/home"
mkdir -p "${HOME}/.config/gh" "${HOME}/neutral-cwd"
cat >"${HOME}/.config/gh/hosts.yml" <<'YAML'
github.com:
    user: twistedmelonman
    oauth_token: fake
YAML
export TMPDIR="${WORKDIR}/tmp"
mkdir -p "${TMPDIR}"

for owner in smartwatermelon twistedmelonman; do
  "${GIT}" init -q "${WORKDIR}/${owner}-repo"
  "${GIT}" -C "${WORKDIR}/${owner}-repo" remote add origin \
    "git@github.com:${owner}/example.git"
done

# The stub records the token it was handed and its argv, then exits with
# STUB_RC (default 0). It never prints the token anywhere but the log.
LOG="${WORKDIR}/gh.log"
STUB_DIR="${WORKDIR}/stub-bin"
mkdir -p "${STUB_DIR}"
cat >"${STUB_DIR}/gh" <<STUB_EOF
#!/usr/bin/env bash
printf 'token=%s|%s\n' "\${GH_TOKEN:-<unset>}" "\$*" >>"${LOG}"
exit "\${STUB_RC:-0}"
STUB_EOF
chmod +x "${STUB_DIR}/gh"

# A PATH entry holding the wrapper as `gh`, ahead of the stub, as
# ~/.local/bin/gh is in production.
WRAP_DIR="${WORKDIR}/wrap-bin"
mkdir -p "${WRAP_DIR}"
ln -s "${WRAPPER}" "${WRAP_DIR}/gh"

# Function-mode drivers, kept in files so no quoted `$` needs escaping.
FN_DRIVER="${WORKDIR}/fn-driver.sh"
{
  printf 'source %q\n' "${WRAPPER}"
  cat <<'DRIVER_EOF'
gh "$@"
DRIVER_EOF
} >"${FN_DRIVER}"
# Compares rather than prints, so no token value is ever echoed.
LEAK_DRIVER="${WORKDIR}/leak-driver.sh"
{
  printf 'source %q\n' "${WRAPPER}"
  cat <<'DRIVER_EOF'
gh pr list >/dev/null 2>&1
[[ "${GH_TOKEN}" == launch-stub ]] && echo unchanged
DRIVER_EOF
} >"${LEAK_DRIVER}"

MARKER="${WORKDIR}/router-ran"
ROUTER="${WORKDIR}/router.sh"
printf 'touch %q\n' "${MARKER}" >"${ROUTER}"

# _run MODE CWD [VAR=VALUE ...] -- GH-ARGS...
# Sets rc, err, and logged (the token the stub received on its last call).
_run() {
  local mode="$1" cwd="$2"
  shift 2
  local assigns=()
  while [[ "$1" != "--" ]]; do
    assigns+=("$1")
    shift
  done
  shift
  : >"${LOG}"
  if [[ "${mode}" == "standalone" ]]; then
    (cd "${cwd}" && env "${assigns[@]}" PATH="${STUB_DIR}:${PATH}" \
      bash "${WRAPPER}" "$@") >/dev/null 2>"${WORKDIR}/err"
  else
    (cd "${cwd}" && env "${assigns[@]}" PATH="${WRAP_DIR}:${STUB_DIR}:${PATH}" \
      bash "${FN_DRIVER}" "$@") >/dev/null 2>"${WORKDIR}/err"
  fi
  rc=$?
  err="$(cat "${WORKDIR}/err")"
  logged="$(tail -1 "${LOG}" 2>/dev/null | sed -E 's/^token=([^|]*)\|.*/\1/')"
}

SWM="${WORKDIR}/smartwatermelon-repo"
TWM="${WORKDIR}/twistedmelonman-repo"
NEUTRAL="${HOME}/neutral-cwd"
STOP_LINE="Stop and ask Andrew for help"

for mode in standalone function; do
  echo "--- ${mode} mode"

  # (1) Cross-owner: GH_TOKEN authenticates as someone else, but the owner's
  # own token is available. origin/main refuses; now the owner token is used.
  _run "${mode}" "${SWM}" GH_TOKEN=launch-stub CLAUDE_GH_TOKEN_LOGIN=andrewmrich \
    GH_TOKEN_SWM=swm-stub GH_TOKEN_TWM=twm-stub -- pr list
  if [[ "${rc}" -eq 0 && "${logged}" == "swm-stub" ]]; then
    _pass "${mode}: cross-owner call selects GH_TOKEN_SWM"
  else
    _fail "${mode}: cross-owner call: rc=${rc} token=${logged} err=${err}"
  fi

  # Selection skips the `gh api user` identity lookup entirely: with no
  # CLAUDE_GH_TOKEN_LOGIN, the stub would otherwise be called for it first.
  _run "${mode}" "${SWM}" GH_TOKEN=launch-stub GH_TOKEN_SWM=swm-stub -- pr list
  if [[ "${rc}" -eq 0 && "$(wc -l <"${LOG}" | tr -d ' ')" == "1" && "${logged}" == "swm-stub" ]]; then
    _pass "${mode}: selection makes no identity round-trip"
  else
    _fail "${mode}: expected one stub call with swm-stub, rc=${rc} log=$(cat "${LOG}")"
  fi

  # cwd owner selects its own token.
  _run "${mode}" "${TWM}" GH_TOKEN=launch-stub CLAUDE_GH_TOKEN_LOGIN=twistedmelonman GH_TOKEN_TWM=twm-stub \
    GH_TOKEN_SWM=swm-stub -- pr list
  if [[ "${rc}" -eq 0 && "${logged}" == "twm-stub" ]]; then
    _pass "${mode}: cwd owner selects GH_TOKEN_TWM"
  else
    _fail "${mode}: cwd owner: rc=${rc} token=${logged} err=${err}"
  fi

  # -R beats cwd.
  _run "${mode}" "${TWM}" GH_TOKEN=launch-stub CLAUDE_GH_TOKEN_LOGIN=twistedmelonman GH_TOKEN_TWM=twm-stub \
    GH_TOKEN_NOS=nos-stub -- issue list -R nightowlstudiollc/x
  if [[ "${rc}" -eq 0 && "${logged}" == "nos-stub" ]]; then
    _pass "${mode}: -R owner selects GH_TOKEN_NOS"
  else
    _fail "${mode}: -R owner: rc=${rc} token=${logged} err=${err}"
  fi

  # (2) gh api repos/OWNER/... routes on the endpoint, not cwd.
  for endpoint in repos/smartwatermelon/x/pulls /repos/smartwatermelon/x/pulls; do
    _run "${mode}" "${TWM}" GH_TOKEN=launch-stub CLAUDE_GH_TOKEN_LOGIN=twistedmelonman GH_TOKEN_TWM=twm-stub \
      GH_TOKEN_SWM=swm-stub -- api -X GET "${endpoint}" --jq .
    if [[ "${rc}" -eq 0 && "${logged}" == "swm-stub" ]]; then
      _pass "${mode}: api ${endpoint} selects GH_TOKEN_SWM"
    else
      _fail "${mode}: api ${endpoint}: rc=${rc} token=${logged} err=${err}"
    fi
  done

  # A placeholder owner is not an owner: gh fills it from cwd, so do we.
  _run "${mode}" "${TWM}" GH_TOKEN=launch-stub CLAUDE_GH_TOKEN_LOGIN=twistedmelonman GH_TOKEN_TWM=twm-stub \
    GH_TOKEN_SWM=swm-stub -- api 'repos/{owner}/{repo}/pulls'
  if [[ "${rc}" -eq 0 && "${logged}" == "twm-stub" ]]; then
    _pass "${mode}: api repos/{owner}/... falls back to cwd"
  else
    _fail "${mode}: api placeholder: rc=${rc} token=${logged} err=${err}"
  fi

  # No GH_TOKEN: the keyring stays in charge; a per-owner var alone does not
  # route the call.
  _run "${mode}" "${SWM}" GH_TOKEN_SWM=swm-stub -- pr list
  if [[ "${rc}" -eq 0 && "${logged}" == "<unset>" ]]; then
    _pass "${mode}: no GH_TOKEN leaves the keyring in charge"
  else
    _fail "${mode}: no GH_TOKEN: rc=${rc} token=${logged}"
  fi

  # Owner token unset: the old refusal still applies to a mismatched login.
  _run "${mode}" "${SWM}" GH_TOKEN=launch-stub CLAUDE_GH_TOKEN_LOGIN=andrewmrich \
    GH_TOKEN_TWM=twm-stub -- pr list
  if [[ "${rc}" -ne 0 && "${err}" == *"Failing closed"* && ! -s "${LOG}" ]]; then
    _pass "${mode}: owner token unset still fails closed on a mismatch"
  else
    _fail "${mode}: owner token unset: rc=${rc} err=${err}"
  fi

  # (3) No owner: launch token kept; failure prints the stop line; rc intact.
  _run "${mode}" "${NEUTRAL}" GH_TOKEN=launch-stub GH_TOKEN_SWM=swm-stub \
    STUB_RC=3 -- api user
  if [[ "${rc}" -eq 3 && "${logged}" == "launch-stub" && "${err}" == *"${STOP_LINE}"* ]]; then
    _pass "${mode}: unresolved owner failure prints the stop line, rc 3 kept"
  else
    _fail "${mode}: unresolved failure: rc=${rc} token=${logged} err=${err}"
  fi
  if [[ "$(grep -c "${STOP_LINE}" "${WORKDIR}/err")" == "1" ]]; then
    _pass "${mode}: stop line printed exactly once"
  else
    _fail "${mode}: stop line count: $(grep -c "${STOP_LINE}" "${WORKDIR}/err")"
  fi
  _run "${mode}" "${NEUTRAL}" GH_TOKEN=launch-stub -- api user
  if [[ "${rc}" -eq 0 && "${err}" != *"${STOP_LINE}"* ]]; then
    _pass "${mode}: unresolved owner success prints nothing"
  else
    _fail "${mode}: unresolved success: rc=${rc} err=${err}"
  fi
  _run "${mode}" "${SWM}" GH_TOKEN=launch-stub CLAUDE_GH_TOKEN_LOGIN=twistedmelonman GH_TOKEN_SWM=swm-stub \
    STUB_RC=3 -- pr list
  if [[ "${rc}" -eq 3 && "${err}" != *"${STOP_LINE}"* ]]; then
    _pass "${mode}: routed failure does not print the stop line"
  else
    _fail "${mode}: routed failure: rc=${rc} err=${err}"
  fi

  # The router hook is gone.
  rm -f "${MARKER}"
  _run "${mode}" "${NEUTRAL}" GH_TOKEN=launch-stub \
    CLAUDE_GH_TOKEN_ROUTER="${ROUTER}" -- api user
  if [[ ! -e "${MARKER}" ]]; then
    _pass "${mode}: CLAUDE_GH_TOKEN_ROUTER is not sourced"
  else
    _fail "${mode}: CLAUDE_GH_TOKEN_ROUTER was sourced"
  fi
done

# Function mode must not leak the selected token into the caller's shell.
after="$(cd "${SWM}" && env GH_TOKEN=launch-stub GH_TOKEN_SWM=swm-stub \
  PATH="${WRAP_DIR}:${STUB_DIR}:${PATH}" bash "${LEAK_DRIVER}")"
if [[ "${after}" == "unchanged" ]]; then
  _pass "function: caller's GH_TOKEN is unchanged after the call"
else
  _fail "function: caller's GH_TOKEN changed after the call"
fi

if [[ ${fail} -eq 0 ]]; then
  echo "test-gh-wrapper-token-select.sh: all assertions passed"
  exit 0
fi
exit 1
