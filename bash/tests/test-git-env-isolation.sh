#!/usr/bin/env bash
# Regression test for smartwatermelon/dotfiles#239: fixture tests must not write
# to the caller's repository when git repository-selection state is inherited.
#
# WHY THIS TEST INJECTS ITS OWN FAILURE CONDITION
#
# Three separate investigations ran the whole suite, and every individual test,
# from both a main checkout and a linked worktree, and found nothing. The bug
# needs a condition none of those runs produced: an inherited GIT_DIR. Git
# exports GIT_DIR into a hook's environment ONLY when the hook runs from a linked
# worktree, and `.project-hooks/pre-push` execs run-tests.sh — so the suite saw
# it in production and never under audit.
#
# A version of this test that merely ran the suite normally would reproduce that
# false negative. It therefore builds a throwaway repo with a linked worktree,
# exports GIT_DIR pointing at the worktree's administrative directory, and runs
# the real fixture tests as subprocesses under that condition.
#
# WHAT MAKES THE ASSERTION MEANINGFUL
#
# The control case below runs the same unguarded operation WITHOUT the isolation
# helper and requires it to contaminate. A test that only checks the guarded path
# would pass just as happily if the injection stopped working, which is how a
# guard rots into decoration.
set -uo pipefail

unset CDPATH

TESTS_DIR="$(CDPATH='' cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

WORKDIR="/tmp/git-env-isolation-test-$$"
mkdir -p "${WORKDIR}"
trap 'chflags -R nouchg "${WORKDIR}" 2>/dev/null || true; rm -rf "${WORKDIR}"' EXIT

fail=0
_pass() { echo "  PASS: $1"; }
_fail() {
  echo "  FAIL: $1" >&2
  fail=1
}

# Real git, bypassing this repo's PATH wrapper: the wrapper enforces
# branch-protection rules that are correct for real work and wrong for a scratch
# fixture, and it mis-parses `init -b <branch>`.
GIT=/usr/bin/git

# Classify core.hooksPath in a config file as "absent", "empty", or its value.
#
# `git config --get` parses the file the way git itself does, unlike
# `grep | cut`, which returned a single space (not empty string) for git's own
# `\thooksPath = ` write and let `[[ -z ]]` pass the exact #239 failure mode
# (dotfiles#304). `-u GIT_DIR/GIT_WORK_TREE/...` keeps this read from picking
# up the inherited GIT_DIR this whole test file injects — `--get -f <file>`
# already targets an explicit file over any repo-selection state, but the
# unset makes that immunity explicit rather than incidental.
#
# "absent" (the key is not set at all) is treated as a clean result, not a
# failure: an absent core.hooksPath means the fixture repo simply has no
# opinion, which is not the contamination the tripwire exists for. Only a key
# that IS present with an empty or whitespace-only value is the #239 failure
# mode (dotfiles#304 confirms this is the intended property: core.hooksPath
# must be non-empty; empty is the failure, absent is not).
hookspath_probe() {
  local config_file="$1" value
  if value="$(env -u GIT_DIR -u GIT_WORK_TREE -u GIT_INDEX_FILE -u GIT_COMMON_DIR \
    "${GIT}" config -f "${config_file}" --get core.hooksPath 2>/dev/null)"; then
    if [[ -z "${value//[[:space:]]/}" ]]; then
      echo "empty"
    else
      echo "${value}"
    fi
  else
    echo "absent"
  fi
}

# Build a disposable repo with a linked worktree, and echo the worktree's
# administrative git directory — the value git would export as GIT_DIR.
#
# `-c core.hooksPath=` and `-c init.templateDir=` keep this machine's global
# hooks and templates out of the fixture; without them the developer's real
# commit-msg / pre-commit enforcement runs against scratch commits.
make_fixture() {
  local root="$1"
  mkdir -p "${root}"
  "${GIT}" -c core.hooksPath= -c init.templateDir= -C "${root}" init -q -b trunk
  "${GIT}" -C "${root}" -c user.email=fixture@example.invalid \
    -c user.name=Fixture -c core.hooksPath= \
    commit -q --allow-empty -m "fixture base"
  # The worktree lives inside the fixture, so cleanup is a single rm -rf and the
  # sanctioned-path worktree policy is not involved.
  "${GIT}" -C "${root}" -c core.hooksPath= worktree add -q --detach \
    "${root}/linked" >/dev/null 2>&1
  # A linked worktree's .git is a file reading `gitdir: <admin dir>`. Parse it
  # strictly: a malformed file would otherwise yield a wrong path and cascade
  # into a confusing assertion failure somewhere else entirely.
  local admin_dir
  admin_dir="$(sed -n 's/^gitdir: //p' "${root}/linked/.git")"
  if [[ -z "${admin_dir}" || ! -d "${admin_dir}" ]]; then
    echo "make_fixture: could not resolve worktree admin dir from ${root}/linked/.git" >&2
    return 1
  fi
  printf '%s\n' "${admin_dir}"
}

config_fingerprint() {
  # The COMMON config, which linked worktrees share — this is the file that was
  # contaminated in the incident.
  #
  # `md5` is macOS-only. On a runner without it every call returned the literal
  # "MISSING", which compares equal to itself — so before == after always held,
  # the control assertion ("an unguarded write DOES contaminate") always failed,
  # and the test aborted with a misleading error instead of testing anything
  # (smartwatermelon/dotfiles#252). CI is macos-latest today, so this has not
  # bitten yet; it would the moment a ubuntu runner is added.
  #
  # cksum is POSIX and present on both platforms. A missing or unreadable file
  # must NOT collapse to a constant, or the vacuous-comparison bug returns, so
  # the failure branch emits a value unique to that path and file.
  local config="$1/.git/config"
  if [[ ! -r "${config}" ]]; then
    printf 'UNREADABLE:%s\n' "${config}"
    return 0
  fi
  cksum <"${config}"
}

# --------------------------------------------------------------------------
echo "Case: hookspath_probe catches git's own empty-value write (known-bad)"
# --------------------------------------------------------------------------
# Reproduces the exact bug this file's #239 check had: git writes an empty
# value as `\thooksPath = `, not as an absent key. A detector that reads that
# line with `grep | cut -d'=' -f2` gets a single space back, `[[ -z ]]` is
# false, and the check passes on the exact contamination it exists to catch.
selftest_config="${WORKDIR}/hookspath-selftest.git-config"
mkdir -p "${WORKDIR}"
"${GIT}" config -f "${selftest_config}" core.hooksPath ""

selftest_result="$(hookspath_probe "${selftest_config}")"
if [[ "${selftest_result}" == "empty" ]]; then
  _pass "hookspath_probe reports 'empty' for git's own empty-value write"
else
  _fail "hookspath_probe reported '${selftest_result}' for git's own empty-value write, wanted 'empty'"
fi

# Show the old pipeline would have wrongly passed this exact fixture: it
# returns a single space, which `[[ -z ]]` does not treat as empty.
old_pipeline_value="$(grep '^[[:space:]]*hooksPath[[:space:]]*=' "${selftest_config}" | cut -d'=' -f2)"
if [[ -z "${old_pipeline_value}" ]]; then
  _fail "old grep|cut pipeline unexpectedly saw an empty value too — the regression this self-test guards against is gone; update the comment above"
else
  _pass "old grep|cut pipeline would have wrongly reported non-empty ('${old_pipeline_value}'), confirming this is the #239 regression the new probe fixes"
fi

# --------------------------------------------------------------------------
echo "Case: control — an unguarded fixture write DOES contaminate"
# --------------------------------------------------------------------------
# Establishes that the injected condition is real. If this stops contaminating,
# every assertion below becomes vacuous and this test must fail loudly rather
# than reporting green.
control_root="${WORKDIR}/control"
control_gitdir="$(make_fixture "${control_root}")"
control_before="$(config_fingerprint "${control_root}")"
mkdir -p "${WORKDIR}/control-scratch"
# Run the unguarded sequence in a child with GIT_DIR set in its environment
# only. `env VAR=x cmd` scopes the variable to that one process, which is what
# the incident looked like, and keeps it out of this script's own environment.
cat >"${WORKDIR}/control.sh" <<'CONTROL'
set -u
cd "$1" || exit 1
/usr/bin/git -c core.hooksPath= -c init.templateDir= init -q -b main
/usr/bin/git config core.hooksPath ""
/usr/bin/git config user.email "test@example.com"
CONTROL
env GIT_DIR="${control_gitdir}" "${BASH}" "${WORKDIR}/control.sh" \
  "${WORKDIR}/control-scratch" >/dev/null 2>&1
control_after="$(config_fingerprint "${control_root}")"

if [[ "${control_before}" == "${control_after}" ]]; then
  _fail "control did not contaminate — the injected GIT_DIR condition is no longer reproducing, so the guarded cases below prove nothing"
else
  _pass "control contaminates as expected (injection is live)"
fi

# --------------------------------------------------------------------------
echo "Case: the isolation helper contains the same write"
# --------------------------------------------------------------------------
guard_root="${WORKDIR}/guarded"
guard_gitdir="$(make_fixture "${guard_root}")"
guard_before="$(config_fingerprint "${guard_root}")"
guard_scratch="${WORKDIR}/guarded-scratch"
mkdir -p "${guard_scratch}"
# Same sequence, same injected GIT_DIR, but sourcing the helper first.
cat >"${WORKDIR}/guarded.sh" <<'GUARDED'
set -u
# shellcheck source=/dev/null
source "$2"
isolate_git_env "$1"
cd "$1" || exit 1
/usr/bin/git -c core.hooksPath= -c init.templateDir= init -q -b main
/usr/bin/git config core.hooksPath ""
/usr/bin/git config user.email "test@example.com"
/usr/bin/git config user.name "Test"
GUARDED
env GIT_DIR="${guard_gitdir}" "${BASH}" "${WORKDIR}/guarded.sh" \
  "${guard_scratch}" "${TESTS_DIR}/lib/git-env-isolation.sh" >/dev/null 2>&1
guard_after="$(config_fingerprint "${guard_root}")"

if [[ "${guard_before}" == "${guard_after}" ]]; then
  _pass "common config byte-identical with the helper applied"
else
  _fail "helper did not contain the write; config changed"
fi

# The fixture values must still land SOMEWHERE — isolation that also breaks the
# test's purpose is not a fix.
scratch_email="$("${GIT}" -C "${guard_scratch}" config --local --get user.email 2>/dev/null || true)"
if [[ "${scratch_email}" == "test@example.com" ]]; then
  _pass "fixture values landed in the scratch repo, where they belong"
else
  _fail "scratch repo did not receive its own fixture config"
fi

# --------------------------------------------------------------------------
echo "Case: real fixture tests run clean under an inherited GIT_DIR"
# --------------------------------------------------------------------------
# The end-to-end assertion: invoke the actual tests that caused the incident,
# under the actual triggering condition, and require the shared config to be
# untouched.
# Every test that creates or mutates a git fixture, not only the two that were
# the incident's confirmed sources. A guard that regresses in any of them
# reintroduces the same failure, and the runner-level clear in run-tests.sh does
# not protect a test invoked directly.
#
# Derived from the tests that source the isolation helper, so a newly guarded
# test joins this list automatically rather than silently falling out of
# coverage. test-git-env-isolation.sh (this file) is excluded: it invokes the
# others, and probing itself would recurse.
guarded_list="$(grep -l 'isolate_git_env' "${TESTS_DIR}"/test-*.sh | sort || true)"
self_name="${BASH_SOURCE[0]##*/}"
guarded_tests=()
while IFS= read -r candidate; do
  [[ -n "${candidate}" ]] || continue
  [[ "${candidate##*/}" == "${self_name}" ]] && continue
  guarded_tests+=("${candidate##*/}")
done <<<"${guarded_list}"

if ((${#guarded_tests[@]} == 0)); then
  _fail "no guarded tests discovered — the probe set is empty, so the loop below proves nothing"
fi

for test_name in "${guarded_tests[@]}"; do
  test_path="${TESTS_DIR}/${test_name}"
  if [[ ! -f "${test_path}" ]]; then
    _fail "${test_name}: not found"
    continue
  fi

  probe_root="${WORKDIR}/probe-${test_name%.sh}"
  probe_gitdir="$(make_fixture "${probe_root}")"
  before="$(config_fingerprint "${probe_root}")"
  head_before="$("${GIT}" -C "${probe_root}" rev-parse HEAD 2>/dev/null || echo none)"

  # Subprocess, so the test's own `set -e` and traps stay contained.
  GIT_DIR="${probe_gitdir}" "${BASH}" "${test_path}" >/dev/null 2>&1
  test_status=$?

  after="$(config_fingerprint "${probe_root}")"
  head_after="$("${GIT}" -C "${probe_root}" rev-parse HEAD 2>/dev/null || echo none)"

  if [[ "${before}" == "${after}" ]]; then
    _pass "${test_name}: shared config unchanged"
  else
    _fail "${test_name}: shared config was modified"
    "${GIT}" -C "${probe_root}" config --local --list 2>/dev/null | sed 's/^/      /' >&2
  fi

  # core.bare=true is the contaminant the old detector missed entirely.
  probe_bare="$("${GIT}" -C "${probe_root}" config --local --get core.bare 2>/dev/null || true)"
  if [[ "${probe_bare}" == "true" ]]; then
    _fail "${test_name}: set core.bare=true on the fixture repo"
  else
    _pass "${test_name}: core.bare not set to true"
  fi

  # core.hooksPath is the property that the uchg flag on .git/config was
  # protecting. The incident left core.hooksPath empty in the shared config,
  # silently disabling commit-time review (#239). This check validates that
  # the git environment isolation guard prevents that contamination.
  #
  # Read with `git config -f <file> --get` (via hookspath_probe), not
  # `grep | cut`, which returned a single space — not empty — for git's own
  # empty-value write and let the #239 failure mode pass silently
  # (dotfiles#304). An empty or missing core.hooksPath in the shared config
  # is the exact failure mode the tripwire was guarding against; "absent" is
  # not treated as a failure — see hookspath_probe's comment for why.
  probe_hooks_status="$(hookspath_probe "${probe_root}/.git/config")"
  case "${probe_hooks_status}" in
    empty)
      _fail "${test_name}: core.hooksPath is empty in shared config (the #239 failure mode)"
      ;;
    absent)
      _pass "${test_name}: core.hooksPath not set in shared config (no contamination)"
      ;;
    *)
      _pass "${test_name}: core.hooksPath is non-empty in shared config"
      ;;
  esac

  if "${GIT}" -C "${probe_root}" remote 2>/dev/null | grep -qx upstream; then
    _fail "${test_name}: added an 'upstream' remote to the fixture repo"
  else
    _pass "${test_name}: no stray upstream remote"
  fi

  # The incident also left fixture commits in the worktree's reflog and detached
  # its HEAD.
  if [[ "${head_before}" == "${head_after}" ]]; then
    _pass "${test_name}: fixture HEAD unchanged"
  else
    _fail "${test_name}: moved the fixture repo's HEAD (${head_before} -> ${head_after})"
  fi

  # The test must still pass under isolation — a guard that breaks the test it
  # protects has traded one failure for another.
  if [[ "${test_status}" -eq 0 ]]; then
    _pass "${test_name}: still passes with GIT_DIR inherited"
  else
    _fail "${test_name}: failed (exit ${test_status}) under an inherited GIT_DIR"
  fi
done

echo
if [[ "${fail}" -eq 0 ]]; then
  echo "ALL CHECKS PASSED"
  exit 0
fi
echo "FAILURES PRESENT" >&2
exit 1
