#!/usr/bin/env bash
#shellcheck shell=bash
# Standalone verification that `_claude_update` does not try to update
# plugins synced from claude.ai.
# Run directly: bash bash/tests/test-claude-update-skip-synced.sh
#
# `claude plugin list --json` also returns plugins synced from the claude.ai
# account (`"scope": "synced"`, ids like `pr-review@synced`). They have no
# marketplace behind them, so `claude plugin update` always fails on them:
# "This plugin is synced from your claude.ai account with no marketplace
# backing — it cannot be updated here." Claude Code refreshes them from
# claude.ai on its own, so `updates` must skip them instead of logging a
# failure for each one on every run.
#
# The test runs the real function against a stub `claude` binary in a
# throwaway HOME, and records which plugin ids reach `plugin update`.
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

if ! command -v jq &>/dev/null; then
  echo "FAIL: jq is required (the function under test needs it)" >&2
  exit 1
fi

# Same extraction as test-gem-update-no-document.sh: let bash's parser print
# the function instead of slicing the file with a text pattern.
_fn_src="$(bash --norc --noprofile -c '
  source "$1" >/dev/null 2>&1 || exit 1
  declare -f _claude_update
' _ "${REPO_ROOT}/bash/functions.sh")"
if [[ -z "${_fn_src}" ]]; then
  echo "FAIL: could not extract _claude_update from functions.sh" >&2
  echo "      (the function may have been renamed or removed)" >&2
  exit 1
fi

tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT
fake_home="${tmp}/home"
mkdir -p "${fake_home}/.local/bin"
calls="${tmp}/update-calls"
: >"${calls}"

# Stub claude: `plugin list --json` returns one plugin of each kind, and
# `plugin update <id>` records the id. Everything else succeeds silently.
cat >"${fake_home}/.local/bin/claude" <<EOF
#!/usr/bin/env bash
if [[ "\$1 \$2" == "plugin list" ]]; then
  cat <<'JSON'
[
  {"id": "local-plugin@some-marketplace", "scope": "user", "enabled": true},
  {"id": "disabled-plugin@some-marketplace", "scope": "user", "enabled": false},
  {"id": "cloud-plugin@synced", "scope": "synced", "enabled": true}
]
JSON
elif [[ "\$1 \$2" == "plugin update" ]]; then
  printf '%s\n' "\$3" >>"${calls}"
fi
exit 0
EOF
chmod +x "${fake_home}/.local/bin/claude"

output="$(
  HOME="${fake_home}" bash --norc --noprofile -c '
    _notif() { printf "%s\n" "$*"; }
    _update_log() { cat >/dev/null; }
    eval "$1"
    _claude_update
  ' _ "${_fn_src}" 2>&1
)"

echo "Case: marketplace plugins are still updated"
if grep -qx 'local-plugin@some-marketplace' "${calls}"; then
  check "enabled user-scope plugin reaches plugin update" "yes" "yes"
else
  check "enabled user-scope plugin reaches plugin update" "yes" "no"
fi

echo "Case: synced plugins are skipped"
if grep -qx 'cloud-plugin@synced' "${calls}"; then
  check "synced plugin does not reach plugin update" "yes" "no"
else
  check "synced plugin does not reach plugin update" "yes" "yes"
fi

echo "Case: disabled plugins are still skipped"
if grep -qx 'disabled-plugin@some-marketplace' "${calls}"; then
  check "disabled plugin does not reach plugin update" "yes" "no"
else
  check "disabled plugin does not reach plugin update" "yes" "yes"
fi

echo "Case: the skip is visible in the log"
# Match the id AND "skipped" on one line: the pre-fix "<id> updated" line
# also names the plugin, so the id alone would pass against the bug.
if grep -q 'cloud-plugin@synced.*skipped' <<<"${output}"; then
  check "skipped synced plugin is named in the output" "yes" "yes"
else
  check "skipped synced plugin is named in the output" "yes" "no"
fi

echo
if [[ "${fail}" -eq 0 ]]; then
  echo "test-claude-update-skip-synced: all cases passed"
else
  echo "test-claude-update-skip-synced: FAILURES above"
  printf '%s\n' "--- function output ---" "${output}"
fi
exit "${fail}"
