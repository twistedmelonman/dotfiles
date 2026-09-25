#!/usr/bin/env bash
#shellcheck shell=bash
# Standalone verification for bash/gh-wrapper.sh's owner->identity mapping.
# Run directly: bash bash/tests/test-gh-wrapper-identity.sh
#
# Covers the three-tier mapping in _gh_wrapper_sync_identity:
#   1. Explicitly-claimed owners (both directions), case-insensitively
#      (regression: smartwatermelon/dotfiles#159).
#   2. The Beacon-context heuristic for owners claimed by neither identity
#      (checkout under the beacon dir, or forked from beacon-biosignals).
#   3. The twistedmelonman default for everything else.
set -euo pipefail

unset CDPATH

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
export BASH_CONFIG_DIR="${REPO_ROOT}/bash"

# Clear inherited git repository-selection state before touching any fixture.
# A hook invoked from a linked worktree exports GIT_DIR, which outranks both the
# working directory and `git -C`, so without this the scratch repos below are
# silently redirected at the real checkout (smartwatermelon/dotfiles#239).
_tests_dir="$(CDPATH='' cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/git-env-isolation.sh
source "${_tests_dir}/lib/git-env-isolation.sh"
isolate_git_env

export HOME="/tmp/gh-wrapper-identity-test-home-$$"
mkdir -p "${HOME}/.config/gh"

# GH_TOKEN outranks the keyring identity, so _gh_wrapper_sync_identity fails
# closed when a real token in the developer's environment disagrees with the
# fixture owner each case resolves. That guard is correct; inheriting the
# ambient token here is not. Sandbox it the same way HOME is sandboxed, so the
# cases exercise the hosts.yml path they are written to test.
unset GH_TOKEN GITHUB_TOKEN CLAUDE_GH_TOKEN_LOGIN

# git init inside the sandboxed HOME must not pick up interactive prompts.
export GIT_CONFIG_GLOBAL="${HOME}/.gitconfig"
export GIT_CONFIG_SYSTEM=/dev/null
printf '[user]\n\tname = test\n\temail = test@example.invalid\n' >"${HOME}/.gitconfig"
trap 'rm -rf "${HOME}"' EXIT

# Sourcing (not executing) the file puts it in function-definition mode,
# where _gh_wrapper_sync_identity is defined but gh() itself is not invoked.
#shellcheck source=/dev/null
source "${BASH_CONFIG_DIR}/gh-wrapper.sh"

fail=0

# Stub `command gh auth switch` so we can observe the desired identity
# without touching real gh state. Records the requested user to a file.
switch_log="${HOME}/switch-log"
# _gh_wrapper_sync_identity reaches this only indirectly, via its own
# `command gh auth switch ...` call — shellcheck can't see that call site from
# here, so the stub is routed through an explicit dispatcher that it can.
_test_command_stub() {
  if [[ "$1" == "gh" && "$2" == "auth" && "$3" == "switch" ]]; then
    # args: gh auth switch --hostname github.com --user <desired>
    printf '%s' "${*: -1}" >"${switch_log}"
    return 0
  fi
  builtin command "$@"
}
# Install the stub as the `command` builtin override. Defined via eval so the
# linter doesn't try to trace invocations of a name that only the code under
# test calls.
eval 'command() { _test_command_stub "$@"; }'
# Prove the stub is wired up before relying on it for every assertion below:
# a clean result from a stub that never fired would be meaningless.
_test_command_stub gh auth switch --hostname github.com --user __selftest__
command gh auth switch --hostname github.com --user __selftest__
if [[ "$(cat "${switch_log}" 2>/dev/null || true)" != "__selftest__" ]]; then
  echo "FAIL: command stub is not intercepting 'gh auth switch' — aborting"
  exit 1
fi
rm -f "${switch_log}"

assert_desired() {
  local label="$1" current_user="$2" repo_arg="$3" expected="$4"
  rm -f "${switch_log}"
  cat >"${HOME}/.config/gh/hosts.yml" <<EOF
github.com:
    user: ${current_user}
EOF
  if _gh_wrapper_sync_identity --repo "${repo_arg}" pr list; then
    :
  else
    echo "FAIL: ${label} — _gh_wrapper_sync_identity returned non-zero"
    fail=1
    return
  fi
  local got
  got="$(cat "${switch_log}" 2>/dev/null || true)"
  if [[ "${current_user}" == "${expected}" ]]; then
    # No switch should have been attempted.
    if [[ -z "${got}" ]]; then
      echo "PASS: ${label} (no switch needed, stayed on ${current_user})"
    else
      echo "FAIL: ${label} — unexpected switch attempted to '${got}'"
      fail=1
    fi
  else
    if [[ "${got}" == "${expected}" ]]; then
      echo "PASS: ${label} (switched to ${expected})"
    else
      echo "FAIL: ${label} — expected switch to '${expected}', got '${got}'"
      fail=1
    fi
  fi
}

# Same as assert_desired, but runs the check from inside a given directory so
# the cwd-sensitive Beacon-context signals (checkout path, upstream remote)
# come into play. Restores the previous cwd afterward.
assert_desired_in() {
  local dir="$1"
  shift
  local prev
  prev="$(pwd)"
  cd "${dir}"
  assert_desired "$@"
  cd "${prev}"
}

# Isolate the heuristic: point the beacon dir at a path that does not exist
# unless a test deliberately creates it, and run from a directory that is not
# a git repo, so no stray cwd remote leaks into owner resolution.
export GH_WRAPPER_BEACON_DIR="${HOME}/Developer/beacon-biosignals"
mkdir -p "${HOME}/neutral-cwd"
cd "${HOME}/neutral-cwd"

# --- Tier 1: explicitly-claimed owners -------------------------------------
# These win in both directions and must never depend on cwd. "Wrong current"
# fixtures use andrewmrich, not twistedmelonman: twistedmelonman/dotfiles is
# claimed by twistedmelonman regardless of which of the three org logins
# hosts.yml currently holds.
assert_desired "twistedmelonman dotfiles" "andrewmrich" "twistedmelonman/dotfiles" "twistedmelonman"
assert_desired "lowercase nightowlstudiollc" "andrewmrich" "nightowlstudiollc/kebab-tax" "twistedmelonman"
assert_desired "lowercase twistedmelonman" "andrewmrich" "twistedmelonman/old-archived" "twistedmelonman"
assert_desired "already twistedmelonman stays" "twistedmelonman" "twistedmelonman/dotfiles" "twistedmelonman"
assert_desired "beacon-biosignals org" "twistedmelonman" "beacon-biosignals/somerepo" "andrewmrich"
# The git-pkgs-proxy case: a fork created during Beacon work, owned by
# andrewmrich rather than the beacon-biosignals org.
assert_desired "andrewmrich personal fork" "twistedmelonman" "andrewmrich/git-pkgs-proxy" "andrewmrich"

# Case-insensitivity across all claimed owners
# (regression: smartwatermelon/dotfiles#159).
assert_desired "mixed-case SmartWatermelon" "andrewmrich" "SmartWatermelon/dotfiles" "twistedmelonman"
assert_desired "upper-case NIGHTOWLSTUDIOLLC" "andrewmrich" "NIGHTOWLSTUDIOLLC/kebab-tax" "twistedmelonman"
assert_desired "mixed-case TwistedMelonMan" "andrewmrich" "TwistedMelonMan/old-archived" "twistedmelonman"
assert_desired "mixed-case Beacon-BioSignals" "twistedmelonman" "Beacon-BioSignals/somerepo" "andrewmrich"
assert_desired "mixed-case AndrewMRich" "twistedmelonman" "AndrewMRich/git-pkgs-proxy" "andrewmrich"

# Post-rename: the old login is just another wrong identity.
assert_desired "stale smartwatermelon hosts.yml is switched" "smartwatermelon" "twistedmelonman/dotfiles" "twistedmelonman"

# --- Tier 3: default ---------------------------------------------------------
# An owner claimed by neither identity, with no Beacon context, defaults to
# twistedmelonman.
assert_desired "unclaimed owner defaults to twistedmelonman" "andrewmrich" "someotherorg/somerepo" "twistedmelonman"

# --- Tier 2: Beacon-context heuristic ----------------------------------------
# Only consulted for owners claimed by neither identity.

# Signal 1: checkout lives under the beacon dir.
beacon_repo="${GH_WRAPPER_BEACON_DIR}/thirdparty-tool"
mkdir -p "${beacon_repo}"
git -C "${beacon_repo}" init -q
assert_desired_in "${beacon_repo}" "unclaimed owner, checkout under beacon dir" \
  "twistedmelonman" "someotherorg/thirdparty-tool" "andrewmrich"

# A sibling dir sharing the prefix must NOT match.
sibling_repo="${GH_WRAPPER_BEACON_DIR}-scratch/thirdparty-tool"
mkdir -p "${sibling_repo}"
git -C "${sibling_repo}" init -q
assert_desired_in "${sibling_repo}" "prefix-sibling dir does not count as beacon" \
  "andrewmrich" "someotherorg/thirdparty-tool" "twistedmelonman"

# Signal 2: forked from the beacon-biosignals org, checkout anywhere.
fork_repo="${HOME}/elsewhere/forked-tool"
mkdir -p "${fork_repo}"
git -C "${fork_repo}" init -q
git -C "${fork_repo}" remote add upstream "git@github.com:beacon-biosignals/forked-tool.git"
assert_desired_in "${fork_repo}" "unclaimed owner, upstream is beacon-biosignals" \
  "twistedmelonman" "someotherorg/forked-tool" "andrewmrich"

# An upstream pointing somewhere else must NOT match.
other_fork="${HOME}/elsewhere/other-fork"
mkdir -p "${other_fork}"
git -C "${other_fork}" init -q
git -C "${other_fork}" remote add upstream "git@github.com:unrelated/other-fork.git"
assert_desired_in "${other_fork}" "unrelated upstream does not count as beacon" \
  "andrewmrich" "someotherorg/other-fork" "twistedmelonman"

# --- Tier 1 beats Tier 2 -----------------------------------------------------
# An explicitly-claimed owner is authoritative even from inside a beacon
# checkout: the heuristic must not hijack a repo you clearly own. This keeps
# `gh -R twistedmelonman/dotfiles ...` meaning the same thing from any
# directory (twistedmelonman/dotfiles#135).
assert_desired_in "${beacon_repo}" "claimed owner beats beacon cwd" \
  "andrewmrich" "twistedmelonman/dotfiles" "twistedmelonman"

cd "${HOME}/neutral-cwd"

# --- --owner (gh search etc.) ------------------------------------------------
# A single --owner names the owner the call acts on, so it must beat a Beacon
# cwd remote; -R still beats --owner; an owner list falls back to cwd.
# Run from a checkout whose origin is beacon-biosignals, so cwd alone would
# resolve to andrewmrich and a pass proves --owner was read.
assert_desired_args() {
  local label="$1" current_user="$2" expected="$3"
  shift 3
  rm -f "${switch_log}"
  printf 'github.com:\n    user: %s\n' "${current_user}" >"${HOME}/.config/gh/hosts.yml"
  _gh_wrapper_sync_identity "$@" || true
  local got
  got="$(cat "${switch_log}" 2>/dev/null || true)"
  [[ -z "${got}" ]] && got="${current_user}"
  if [[ "${got}" == "${expected}" ]]; then
    echo "PASS: ${label} (${expected})"
  else
    echo "FAIL: ${label} — expected '${expected}', got '${got}'"
    fail=1
  fi
}
beacon_origin="${HOME}/elsewhere/beacon-origin"
mkdir -p "${beacon_origin}"
git -C "${beacon_origin}" init -q
git -C "${beacon_origin}" remote add origin "git@github.com:beacon-biosignals/somerepo.git"
cd "${beacon_origin}"
assert_desired_args "cwd alone resolves to beacon (control)" "twistedmelonman" "andrewmrich" \
  search issues --state=open
assert_desired_args "--owner=ORG beats beacon cwd" "andrewmrich" "twistedmelonman" \
  search issues --owner=nightowlstudiollc
assert_desired_args "--owner ORG (two args) beats beacon cwd" "andrewmrich" "twistedmelonman" \
  search prs --owner smartwatermelon --state open
assert_desired_args "owner list falls back to cwd" "twistedmelonman" "andrewmrich" \
  search issues --owner=smartwatermelon,nightowlstudiollc
assert_desired_args "-R beats --owner" "twistedmelonman" "andrewmrich" \
  search issues --owner=smartwatermelon -R beacon-biosignals/x
assert_desired_args "--owner after -- is ignored" "twistedmelonman" "andrewmrich" \
  search issues -- --owner=smartwatermelon
cd "${HOME}/neutral-cwd"

# --- Missing-beacon-dir warning ----------------------------------------------
# An explicitly-configured beacon dir that doesn't exist must warn on stderr;
# an unset default that doesn't exist must stay silent (the normal state on a
# personal machine with no Beacon work).
assert_warns() {
  local label="$1" expect_warn="$2" explicit="$3" dir="$4"
  local out
  cat >"${HOME}/.config/gh/hosts.yml" <<EOF
github.com:
    user: twistedmelonman
EOF
  # A separate `bash -c` process per case, not a subshell: the warning latches
  # via _GH_WRAPPER_BEACON_DIR_WARNED and the explicit-vs-default decision is
  # made at source time, so each case needs a genuinely fresh shell to be a
  # real test rather than an artifact of ordering.
  if [[ "${explicit}" == "1" ]]; then
    out=$(GH_WRAPPER_BEACON_DIR="${dir}" bash -c '
      source "$1/gh-wrapper.sh"
      _gh_wrapper_is_beacon_context 2>&1 >/dev/null || true
    ' _ "${BASH_CONFIG_DIR}" 2>&1)
  else
    # Unset override, and point HOME at a pristine dir so the default path
    # resolves to something absent.
    # `unset` in the child rather than `env -u`, so the linter can still see
    # the positional hand-off into `bash -c`.
    out=$(HOME="${dir}" bash -c '
      unset GH_WRAPPER_BEACON_DIR
      source "$1/gh-wrapper.sh"
      _gh_wrapper_is_beacon_context 2>&1 >/dev/null || true
    ' _ "${BASH_CONFIG_DIR}" 2>&1)
  fi
  if [[ "${expect_warn}" == "1" ]]; then
    if [[ "${out}" == *"GH_WRAPPER_BEACON_DIR is set to"* ]]; then
      echo "PASS: ${label} (warned)"
    else
      echo "FAIL: ${label} — expected a warning, got: '${out}'"
      fail=1
    fi
  else
    if [[ -z "${out}" ]]; then
      echo "PASS: ${label} (silent)"
    else
      echo "FAIL: ${label} — expected silence, got: '${out}'"
      fail=1
    fi
  fi
}

# A directory this test creates itself. Deriving it from the ambient
# GH_WRAPPER_BEACON_DIR would mean an empty/unset value silently collapses
# this case into a duplicate of the unset-default case below — still passing,
# but no longer testing explicit+present at all.
beacon_dir_present="${HOME}/explicit-beacon-present"
mkdir -p "${beacon_dir_present}"
mkdir -p "${HOME}/pristine-home"
assert_warns "explicit beacon dir missing warns" 1 1 "${HOME}/no-such-beacon-dir"
assert_warns "explicit beacon dir present is silent" 0 1 "${beacon_dir_present}"
# The personal-machine case: no override set, default path absent -> silent.
assert_warns "unset default missing stays silent" 0 0 "${HOME}/pristine-home"

exit "${fail}"
