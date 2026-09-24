#!/usr/bin/env bash
#shellcheck shell=bash
# Standalone verification of `my_prs` / `my_issues` (functions.sh's
# _gh_my_search). Run directly: bash bash/tests/test-my-prs-issues.sh
#
# The contract pinned here:
#   1. One search per org, each with --owner=<org>, --state=open and
#      --archived=false. Never --include-prs: that combination draws an HTTP
#      422 from GitHub.
#   2. Each org's search runs with GH_TOKEN_<ORG> when it is set, and with the
#      caller's own GH_TOKEN (or none) when it is not. A single shared token
#      cannot see private repos in every org, which is why the split exists.
#   3. my_prs adds one --author=@me search; results are de-duplicated by URL.
#   4. Output is sorted newest-updated first; --json emits a JSON array and
#      --text a table. Extra arguments reach gh unchanged.
#   5. A failed org search is reported on stderr and makes the call return
#      non-zero, while the other orgs' results are still printed.
#
# gh is replaced by a shell function that logs its token and argv and prints
# fixture JSON, so nothing here touches the network.
set -euo pipefail
unset CDPATH

REPO_ROOT="$(CDPATH='' cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

fail=0

check() {
  local label="$1" expected="$2" actual="$3"
  if [[ "${expected}" == "${actual}" ]]; then
    echo "  PASS: ${label}"
  else
    echo "  FAIL: ${label} — expected [${expected}], got [${actual}]"
    fail=1
  fi
}

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

# Extract the functions through bash's own parser. HOME points at an empty
# directory so functions.sh does not source the real gh wrapper.
_fn_src="$(HOME="${WORK}" bash --norc --noprofile -c '
  source "$1" >/dev/null 2>&1 || exit 1
  declare -f _gh_my_search my_prs my_issues
' _ "${REPO_ROOT}/bash/functions.sh")"
if [[ -z "${_fn_src}" ]]; then
  echo "FAIL: could not extract _gh_my_search/my_prs/my_issues from functions.sh" >&2
  exit 1
fi
eval "${_fn_src}"

LOG="${WORK}/gh.log"
FAIL_OWNER=""

# Fake gh: one log line per call ("token|args"), then fixture JSON keyed on
# --owner (or on --author=@me for my_prs's extra search).
gh() {
  printf '%s|%s\n' "${GH_TOKEN:-<unset>}" "$*" >>"${LOG}"
  local arg owner=""
  for arg in "$@"; do
    case "${arg}" in
      --owner=*) owner="${arg#--owner=}" ;;
      --author=@me) owner="@me" ;;
    esac
  done
  if [[ -n "${FAIL_OWNER}" && "${owner}" == "${FAIL_OWNER}" ]]; then
    echo "fake gh: simulated failure" >&2
    return 1
  fi
  case "${owner}" in
    twistedmelonman)
      echo '[{"repository":{"nameWithOwner":"twistedmelonman/a"},"number":1,"title":"old","author":{"login":"x"},"labels":[],"updatedAt":"2026-01-01T00:00:00Z","url":"u1","isDraft":false}]'
      ;;
    smartwatermelon)
      echo '[{"repository":{"nameWithOwner":"smartwatermelon/b"},"number":2,"title":"newest","author":{"login":"y"},"labels":[{"name":"bug"}],"updatedAt":"2026-03-01T00:00:00Z","url":"u2","isDraft":true}]'
      ;;
    nightowlstudiollc)
      echo '[{"repository":{"nameWithOwner":"nightowlstudiollc/c"},"number":3,"title":"middle","author":{"login":"z"},"labels":[],"updatedAt":"2026-02-01T00:00:00Z","url":"u3","isDraft":false}]'
      ;;
    @me)
      # u1 duplicates an org result; u9 is an off-org PR.
      echo '[{"repository":{"nameWithOwner":"twistedmelonman/a"},"number":1,"title":"old","author":{"login":"x"},"labels":[],"updatedAt":"2026-01-01T00:00:00Z","url":"u1","isDraft":false},{"repository":{"nameWithOwner":"other/d"},"number":9,"title":"offorg","author":{"login":"x"},"labels":[],"updatedAt":"2025-12-01T00:00:00Z","url":"u9","isDraft":false}]'
      ;;
    *) echo '[]' ;;
  esac
}

echo "Test 1: my_issues with all three per-org tokens set"
: >"${LOG}"
out="$(GH_TOKEN=shared GH_TOKEN_TWM=t1 GH_TOKEN_SWM=t2 GH_TOKEN_NOS=t3 my_issues --json)"
check "three gh calls" "3" "$(wc -l <"${LOG}" | tr -d ' ')"
check "twistedmelonman uses GH_TOKEN_TWM" "1" "$(grep -c '^t1|search issues --owner=twistedmelonman ' "${LOG}")"
check "smartwatermelon uses GH_TOKEN_SWM" "1" "$(grep -c '^t2|search issues --owner=smartwatermelon ' "${LOG}")"
check "nightowlstudiollc uses GH_TOKEN_NOS" "1" "$(grep -c '^t3|search issues --owner=nightowlstudiollc ' "${LOG}")"
check "every call filters open + unarchived" "3" "$(grep -c -- '--state=open --archived=false' "${LOG}")"
check "no --include-prs" "0" "$(grep -c -- '--include-prs' "${LOG}" || true)"
check "sorted newest first" "u2 u3 u1" "$(jq -r 'map(.url) | join(" ")' <<<"${out}")"
# Called in this shell, not in $(...), so a leaked export would be visible.
GH_TOKEN=shared
GH_TOKEN_TWM=t1 my_issues --json >/dev/null
check "caller GH_TOKEN not overwritten" "shared" "${GH_TOKEN}"
unset GH_TOKEN

echo "Test 2: no per-org tokens -> caller's own auth"
: >"${LOG}"
(
  unset GH_TOKEN_TWM GH_TOKEN_SWM GH_TOKEN_NOS
  GH_TOKEN=shared my_issues --json >/dev/null
)
check "all calls use caller GH_TOKEN" "3" "$(grep -c '^shared|' "${LOG}")"
: >"${LOG}"
(
  unset GH_TOKEN GH_TOKEN_TWM GH_TOKEN_SWM GH_TOKEN_NOS
  my_issues --json >/dev/null
)
check "no GH_TOKEN at all -> none set (keyring)" "3" "$(grep -c '^<unset>|' "${LOG}")"

echo "Test 3: my_prs adds an @me search and de-duplicates"
: >"${LOG}"
out="$(my_prs --json)"
check "four gh calls" "4" "$(wc -l <"${LOG}" | tr -d ' ')"
check "one --author=@me call" "1" "$(grep -c -- 'search prs --author=@me' "${LOG}")"
check "duplicate removed, off-org kept, sorted" "u2 u3 u1 u9" "$(jq -r 'map(.url) | join(" ")' <<<"${out}")"
check "isDraft requested for PRs" "4" "$(grep -c -- ',isDraft' "${LOG}")"

echo "Test 4: passthrough arguments and text output"
: >"${LOG}"
out="$(my_issues --text --label bug)"
check "--label reaches gh" "3" "$(grep -c -- '--label bug$' "${LOG}")"
check "--text not passed to gh" "0" "$(grep -c -- '--text' "${LOG}" || true)"
check "summary line" "3 open issues in 3 repos" "$(head -1 <<<"${out}")"
check "row shows number, date, title, labels" "1" \
  "$(grep -c '^  #2     2026-03-01  newest  \[bug\]$' <<<"${out}")"
out="$(my_prs --text)"
check "PR row shows draft and author" "1" \
  "$(grep -c '^  #2     2026-03-01  draft @y  newest  \[bug\]$' <<<"${out}")"
check "piped with no flag -> JSON" "array" "$(my_issues | jq -r type)"

echo "Test 5: one org fails"
: >"${LOG}"
FAIL_OWNER=smartwatermelon
rc=0
out="$(my_issues --json 2>"${WORK}/err")" || rc=$?
FAIL_OWNER=""
check "non-zero exit" "1" "${rc}"
check "error names the org" "1" "$(grep -c 'search failed for smartwatermelon' "${WORK}/err")"
check "other orgs still returned" "u3 u1" "$(jq -r 'map(.url) | join(" ")' <<<"${out}")"

if [[ "${fail}" -ne 0 ]]; then
  echo "FAILED"
  exit 1
fi
echo "All my_prs/my_issues tests passed."
