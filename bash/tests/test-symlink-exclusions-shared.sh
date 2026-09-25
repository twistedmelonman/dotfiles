#!/usr/bin/env bash
#shellcheck shell=bash
# Standalone verification that the ~/.config symlink exclusion list has
# exactly one definition, and that both consumers reach it. Run directly:
# bash bash/tests/test-symlink-exclusions-shared.sh
#
# Regression coverage for smartwatermelon/dotfiles#225: the exclusion list was
# maintained as two independent `case` blocks (install.sh's _is_excluded and
# lib-symlink-repair.sh's _repair_is_excluded) that drifted by eight patterns.
# Neither drift direction was visible at runtime — one produced symlinks the
# repair hook refused to manage, the other recreated links install.sh never
# intended — so nothing failed until someone added a matching file.
#
# The fix collapses both into git/hooks/lib-symlink-exclusions.sh. These cases
# keep it collapsed:
#   1. Only the shared lib defines the exclusion patterns.
#   2. Both consumers source it rather than redefining it.
#   3. The repair lib resolves it from the DEPLOYED hook context, where the
#      sourced path is a symlink into the repo — the resolution mode the
#      pre-commit hook actually uses.
#   4. A missing shared lib fails closed (excludes everything) rather than
#      open (managing files it shouldn't touch).
set -euo pipefail

REPO_ROOT="$(CDPATH='' cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SHARED_LIB="${REPO_ROOT}/git/hooks/lib-symlink-exclusions.sh"
REPAIR_LIB="${REPO_ROOT}/git/hooks/lib-symlink-repair.sh"
INSTALLER="${REPO_ROOT}/install.sh"

WORKDIR="/tmp/symlink-exclusions-test-$$"
mkdir -p "${WORKDIR}"
trap 'rm -rf "${WORKDIR}"' EXIT

fail=0

_pass() { echo "  PASS: $1"; }
_fail() {
  echo "  FAIL: $1" >&2
  fail=1
}

# --- Case 1: the shared lib exists and defines the function --------------
echo "Case: shared exclusion lib is the single definition"
if [[ -f "${SHARED_LIB}" ]]; then
  _pass "git/hooks/lib-symlink-exclusions.sh exists"
else
  _fail "shared exclusion lib missing at ${SHARED_LIB}"
  exit 1
fi

if grep -q '^_symlink_is_excluded() {' "${SHARED_LIB}"; then
  _pass "shared lib defines _symlink_is_excluded()"
else
  _fail "shared lib does not define _symlink_is_excluded()"
fi

# --- Case 2: no consumer redefines the list ------------------------------
# A second `case` block over exclusion patterns anywhere else is exactly the
# duplication #225 was about. Catch a returning definition by name.
for consumer in "${INSTALLER}" "${REPAIR_LIB}"; do
  if grep -qE '^_(repair_)?is_excluded\(\) \{|^_symlink_is_excluded\(\) \{' "${consumer}"; then
    _fail "$(basename "${consumer}") redefines the exclusion function — the list has forked again"
  else
    _pass "$(basename "${consumer}") does not redefine the exclusion function"
  fi
done

# --- Case 3: both consumers source the shared lib ------------------------
for consumer in "${INSTALLER}" "${REPAIR_LIB}"; do
  if grep -q 'lib-symlink-exclusions.sh' "${consumer}"; then
    _pass "$(basename "${consumer}") references the shared exclusion lib"
  else
    _fail "$(basename "${consumer}") does not source the shared exclusion lib"
  fi
done

# --- Case 4: resolution works from the deployed (symlinked) hook context --
# The pre-commit hook sources ~/.config/git/hooks/lib-symlink-repair.sh, which
# is a symlink into the repo. Bash reports the symlink in BASH_SOURCE, so a
# naive sibling lookup would search the deployed directory. Reproduce that
# layout exactly: a deployed dir holding ONLY a symlink to the repair lib.
echo "Case: resolution from the deployed hook context"
DEPLOYED="${WORKDIR}/deployed"
mkdir -p "${DEPLOYED}"
ln -s "${REPAIR_LIB}" "${DEPLOYED}/lib-symlink-repair.sh"

deployed_out="$(
  REPO_DIR="${REPO_ROOT}" bash -c '
    set -euo pipefail
    source "$1/lib-symlink-repair.sh"
    declare -F _symlink_is_excluded >/dev/null || { echo "UNDEFINED"; exit 0; }
    # A file that must be symlinked, and three that must not.
    _symlink_is_excluded "bash/main.sh"   && { echo "OVER-EXCLUDES"; exit 0; }
    _symlink_is_excluded "Makefile"       || { echo "MISSES-Makefile"; exit 0; }
    _symlink_is_excluded "bash/x.example" || { echo "MISSES-example"; exit 0; }
    _symlink_is_excluded "docs/plan.md"   || { echo "MISSES-docs"; exit 0; }
    echo "OK"
  ' _ "${DEPLOYED}" 2>/dev/null
)"

if [[ "${deployed_out}" == "OK" ]]; then
  _pass "repair lib resolves the shared list through its own symlink"
else
  _fail "deployed-context resolution returned '${deployed_out}' (expected OK)"
fi

# --- Case 5: a missing shared lib fails closed ---------------------------
# Copy (not symlink) the repair lib somewhere with no sibling and no REPO_DIR,
# so every resolution candidate misses. It must then exclude everything rather
# than fall through and start managing arbitrary files.
echo "Case: missing shared list fails closed"
ISOLATED="${WORKDIR}/isolated"
mkdir -p "${ISOLATED}"
cp "${REPAIR_LIB}" "${ISOLATED}/lib-symlink-repair.sh"

isolated_out="$(
  bash -c '
    set -euo pipefail
    unset REPO_DIR
    source "$1/lib-symlink-repair.sh" 2>/dev/null
    if _symlink_is_excluded "bash/main.sh"; then echo "CLOSED"; else echo "OPEN"; fi
  ' _ "${ISOLATED}" 2>/dev/null
)"

if [[ "${isolated_out}" == "CLOSED" ]]; then
  _pass "unresolvable list excludes everything rather than managing files"
else
  _fail "missing shared list failed OPEN — repair would manage unintended files"
fi

# --- Case 6: the unified list covers both historical lists ---------------
# Both pre-#225 lists are subsets of the union. Assert the union is intact so a
# future edit cannot quietly drop a pattern one side used to carry.
echo "Case: unified list covers both historical lists"
# shellcheck source=git/hooks/lib-symlink-exclusions.sh
source "${SHARED_LIB}"

must_exclude=(
  ".github/workflows/ci.yml" ".gitignore" "bash/.gitignore" "Brewfile"
  "README.md" "bash/README.md" "install.sh" "docs/plans/x.md"
  "LICENSE" "LICENSE.md" "CLAUDE.md" "bash/CLAUDE.md" "MEMORY.md"
  "bash/MEMORY.md" ".claude/settings.json" ".pre-commit-config.yaml"
  "bash/x.test.sh" "bash/x.spec.js" "bash/x.bats" "tests/x.sh" "test/x.sh"
  "bash/beacon.sh.example" "git/gitconfig-beacon.example"
  "Makefile" ".editorconfig" ".gitattributes" "CONTRIBUTING.md"
  "CHANGELOG.md" "CHANGELOG"
)
missing=0
for pattern in "${must_exclude[@]}"; do
  if ! _symlink_is_excluded "${pattern}"; then
    _fail "unified list no longer excludes '${pattern}'"
    missing=1
  fi
done
((missing == 0)) && _pass "all ${#must_exclude[@]} historical patterns still excluded"

# And it must not have grown so broad it swallows real config.
overreach=0
must_include=(
  "bash/main.sh" "bash/env.sh" "git/config" "git/hooks/pre-commit"
  "vim/vimrc" "btop/btop.conf" "liquidpromptrc"
)
for pattern in "${must_include[@]}"; do
  if _symlink_is_excluded "${pattern}"; then
    _fail "unified list wrongly excludes real config '${pattern}'"
    overreach=1
  fi
done
((overreach == 0)) && _pass "real config paths are still symlinked"

# --- Case 7: nested test directories are excluded ------------------------
# A bash `case` glob does not cross directory levels, so `tests/*` matches
# only at the repo root. Before #227 that let every file under bash/tests/
# get symlinked into ~/.config/bash/tests. These cases pin the `*/tests/*`
# and `*/test/*` patterns that close it.
echo "Case: nested test directories are excluded"
nested_missing=0
nested_must_exclude=(
  "bash/tests/test-foo.sh"
  "bash/tests/run-tests.sh"
  "git/test/helper.sh"
  "a/b/tests/deep.sh"
)
for pattern in "${nested_must_exclude[@]}"; do
  if ! _symlink_is_excluded "${pattern}"; then
    _fail "nested test path '${pattern}' is not excluded — it would be symlinked into ~/.config"
    nested_missing=1
  fi
done
((nested_missing == 0)) && _pass "all ${#nested_must_exclude[@]} nested test paths excluded"

# The patterns must not swallow config that merely has "test" in a path
# segment — only a directory named exactly `test` or `tests` counts.
nested_overreach=0
nested_must_include=(
  "bash/testing-utils.sh"
  "git/latest/config"
  "bash/tests.sh"
  # Directory-segment cases: a *directory* whose name merely contains "test"
  # is not a test dir. `*/tests/*` correctly won't match these, but nothing
  # pinned that until now — a future edit widening the glob to `*test*/*`
  # would silently stop symlinking real config, and no test would catch it
  # (smartwatermelon/dotfiles#245). Each case below was checked by hand
  # against that widened glob when it was added — all three matched it, so
  # each would fail here if the glob were widened. That check was author-time,
  # not an assertion in this file; what protects the behavior from here on is
  # the loop below.
  "bash/testing/config.sh"
  "a/test-utils/b.sh"
  "bash/contest/c.sh"
)
for pattern in "${nested_must_include[@]}"; do
  if _symlink_is_excluded "${pattern}"; then
    _fail "nested test patterns wrongly exclude real config '${pattern}'"
    nested_overreach=1
  fi
done
((nested_overreach == 0)) && _pass "paths merely containing 'test' are still symlinked"

# --- Case 8: deployed template files are not repo-doc README/CLAUDE.md ---
# git/template/.claude-template/README.md is a file this repo DEPLOYS (via
# post-checkout's `cp -r`) into every project's scaffolded .claude/ dir. It is
# not a doc ABOUT this repo, so the generic `*/README.md` / `*/CLAUDE.md`
# repo-doc rules must not swallow it (dotfiles#356). install.sh and
# lib-symlink-repair.sh both gate on this same function, so a fix here fixes
# both consumers.
echo "Case: deployed template files are not excluded as repo docs"
template_missing=0
template_must_include=(
  "git/template/.claude-template/README.md"
  "git/template/.claude-template/config.sh.template"
)
for pattern in "${template_must_include[@]}"; do
  if _symlink_is_excluded "${pattern}"; then
    _fail "template file '${pattern}' is wrongly excluded — it will never deploy"
    template_missing=1
  fi
done
((template_missing == 0)) && _pass "template files under git/template/ are still symlinked"

echo ""
if ((fail != 0)); then
  echo "test-symlink-exclusions-shared: SOME CHECKS FAILED" >&2
  exit 1
fi

echo "test-symlink-exclusions-shared: all cases passed"
