#!/usr/bin/env bash
# Regression test: _gh_wrapper_sync_identity must not report success when
# GH_TOKEN will override the identity it just switched to.
#
# KNOWN-BAD CASE: case 2 below passes against the CURRENT code, because the
# fail-closed check reads hosts.yml (its own output) rather than the auth gh
# will actually use. That inverted assertion is the bug this test pins.
set -uo pipefail
unset CDPATH

TESTS_DIR="$(CDPATH='' cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WRAPPER="${TESTS_DIR}/../gh-wrapper.sh"

WORKDIR="/tmp/gh-token-precedence-test-$$"
mkdir -p "${WORKDIR}"
trap 'rm -rf "${WORKDIR}"' EXIT

GIT=/usr/bin/git
fail=0
_pass() { echo "  PASS: $1"; }
_fail() {
  echo "  FAIL: $1" >&2
  fail=1
}

# Sandbox HOME so the fixture never reads or writes the real hosts.yml.
export HOME="${WORKDIR}/home"
mkdir -p "${HOME}/.config/gh"
cat >"${HOME}/.config/gh/hosts.yml" <<'YAML'
github.com:
    user: twistedmelonman
    oauth_token: fake
YAML

"${GIT}" init -q "${WORKDIR}/repo"
"${GIT}" -C "${WORKDIR}/repo" remote add origin \
  git@github.com:smartwatermelon/example.git

# The driver each case runs: source the wrapper from inside the fixture repo and
# call the function under test. Kept in a file rather than `bash -c` so the
# wrapper path needs no nested quoting.
RUNNER="${WORKDIR}/run-sync.sh"
cat >"${RUNNER}" <<RUNNER_EOF
cd "${WORKDIR}/repo" || exit 1
# shellcheck source=/dev/null
source "${WRAPPER}"
_gh_wrapper_sync_identity
RUNNER_EOF

# Run the driver in a clean child shell with the given VAR=VALUE assignments
# applied. \`env\` is what isolates the environment, so nothing is exported into
# a subshell whose scope is easy to misread.
_sync_under_env() {
  env -u GH_TOKEN -u CLAUDE_GH_TOKEN_LOGIN "$@" bash "${RUNNER}"
}

# Case 1: no GH_TOKEN -> sync succeeds, as it does today.

if _sync_under_env; then
  _pass "no GH_TOKEN: sync succeeds"
else
  _fail "no GH_TOKEN: sync should succeed"
fi

# Case 2: GH_TOKEN belonging to a DIFFERENT identity than the resolved owner
# maps to. Must fail closed. Fails against the current code, which passes.
if _sync_under_env GH_TOKEN="fake-token-for-andrewmrich" \
  CLAUDE_GH_TOKEN_LOGIN="andrewmrich"; then
  _fail "mismatched GH_TOKEN: silently ran as the wrong identity"
else
  _pass "mismatched GH_TOKEN: fails closed"
fi

# Case 3: GH_TOKEN matching the resolved identity -> proceeds.
if _sync_under_env GH_TOKEN="fake-token-for-twistedmelonman" \
  CLAUDE_GH_TOKEN_LOGIN="twistedmelonman"; then
  _pass "matching GH_TOKEN: proceeds"
else
  _fail "matching GH_TOKEN: should proceed"
fi

# Case 3b: GH_TOKEN reporting the pre-rename login is a mismatch now that the
# alias is gone.
if _sync_under_env GH_TOKEN="fake-token-for-smartwatermelon" \
  CLAUDE_GH_TOKEN_LOGIN="smartwatermelon"; then
  _fail "stale smartwatermelon GH_TOKEN: silently accepted"
else
  _pass "stale smartwatermelon GH_TOKEN: fails closed"
fi

# Case 4: expired or revoked GH_TOKEN, with CLAUDE_GH_TOKEN_LOGIN unset so the
# `gh api user` path runs. Must fail closed AND say the identity could not be
# resolved — not that it mismatched.
#
# KNOWN-BAD CASE: this fails against the pre-fix code. `gh api` writes its error
# body to STDOUT, so `2>/dev/null` does not suppress it and the command
# substitution captures `{"message": "Bad credentials", ...}`. token_login is
# therefore non-empty, the "could not be resolved" branch is unreachable, and an
# expired token is reported as an identity MISMATCH — sending the reader to
# "unset GH_TOKEN" when the real fix is to rotate it. Measured against gh 2.99.0.
STUB_DIR="${WORKDIR}/stub-bin"
mkdir -p "${STUB_DIR}"
cat >"${STUB_DIR}/gh" <<'STUB_EOF'
#!/usr/bin/env bash
# Mimic `gh api user` against a rejected token: JSON error body on STDOUT,
# human-readable line on stderr, non-zero exit. Shape verified against the real
# gh 2.99.0 binary.
cat <<'JSON'
{
  "message": "Bad credentials",
  "documentation_url": "https://docs.github.com/rest",
  "status": "401"
}
JSON
echo "gh: Bad credentials (HTTP 401)" >&2
exit 1
STUB_EOF
chmod +x "${STUB_DIR}/gh"

# _gh_wrapper_find_real_gh scans PATH and skips the wrapper itself, so the stub
# is what it finds. Putting it first also keeps the real gh out of reach, which
# is what makes this case hermetic.
# Deliberately NOT shaped like a real `ghp_...` PAT: the secret scanners treat
# that prefix as a hard-coded credential regardless of the value. The guard only
# cares that GH_TOKEN is non-empty, so the shape is irrelevant to the test.
err_output="$(_sync_under_env PATH="${STUB_DIR}:${PATH}" \
  GH_TOKEN="expired-token-fixture" 2>&1)"
rc=$?

if [[ ${rc} -ne 0 ]]; then
  _pass "expired GH_TOKEN: fails closed"
else
  _fail "expired GH_TOKEN: should fail closed"
fi

if [[ "${err_output}" == *"could not be resolved"* ]]; then
  _pass "expired GH_TOKEN: reports a resolution failure"
else
  _fail "expired GH_TOKEN: should report a resolution failure, got: ${err_output}"
fi

# The error body must never be presented as though it were a login name.
if [[ "${err_output}" == *"Bad credentials"* ]]; then
  _fail "expired GH_TOKEN: leaked the raw API error body into the message"
else
  _pass "expired GH_TOKEN: does not echo the raw API error body"
fi

if [[ ${fail} -eq 0 ]]; then
  echo "test-gh-wrapper-gh-token-precedence.sh: all assertions passed"
  exit 0
fi
exit 1
