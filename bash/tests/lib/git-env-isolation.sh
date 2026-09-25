#!/usr/bin/env bash
# Clear the git environment variables that select which repository a git
# command acts on, so a test's scratch fixtures cannot be redirected at the
# caller's real checkout.
#
# Source this, do not execute it:
#
#   # shellcheck source=lib/git-env-isolation.sh
#   source "$(dirname "${BASH_SOURCE[0]}")/lib/git-env-isolation.sh"
#   isolate_git_env "${WORKDIR}"
#
# WHY THIS EXISTS (smartwatermelon/dotfiles#239)
#
# Git exports GIT_DIR into a hook's environment when — and only when — the hook
# runs from a linked worktree. `.project-hooks/pre-push` execs
# `bash/tests/run-tests.sh`, so every test inherited that GIT_DIR and wrote its
# fixtures into the worktree's administrative git directory. Linked worktrees
# share the common config, so the real checkout was contaminated with
# `core.hooksPath=` (empty), `core.bare=true`, a fake identity, and a bogus
# `upstream` remote.
#
# GIT_DIR takes precedence over BOTH the process working directory AND `git -C`.
# That is the part that makes this a trap rather than an ordinary cwd bug:
#
#   GIT_DIR=/elsewhere/.git git -C /tmp/scratch config user.email x@y.z
#     -> writes to /elsewhere/.git/config, NOT /tmp/scratch
#
# So `cd`-guarding and adding `-C` are both insufficient. The environment has to
# be cleared, and it has to be cleared before the first git call.
#
# WHAT THIS DOES NOT TOUCH
#
# GIT_CONFIG_GLOBAL and GIT_CONFIG_SYSTEM are deliberately left alone. They are
# not repository-selection variables — they are how a test points git at a
# sandboxed global config, which several tests here do on purpose
# (test-gh-wrapper-identity.sh sets both). Clearing them would silently
# un-isolate those tests against the developer's real ~/.gitconfig.
#
# Consequence for callers: source this and call isolate_git_env BEFORE exporting
# your own GIT_CONFIG_GLOBAL / GIT_CONFIG_SYSTEM / HOME sandbox. Order matters
# in one direction only — this function never overwrites them, but a caller that
# sets them first and isolates second is relying on that, which is a fragile
# thing to rely on.
#
# WHY .git/config NO LONGER HAS THE uchg FLAG (twistedmelonman/dotfiles#304)
#
# In early iterations, `.git/config` carried the uchg (immutable) file flag as a
# tripwire for #239. A contaminating write would fail loudly instead of silently
# corrupting state. This isolation helper eliminates the mechanism that
# contamination depended on — it clears GIT_DIR and related variables before
# the first git call, so even an inherited GIT_DIR from a linked-worktree hook
# dispatch cannot reach the real repository. The tripwire is no longer needed.
#
# Evidence this works: test-git-env-isolation.sh injects an inherited GIT_DIR
# and runs fixture tests under that condition. The control case proves the
# injected condition is live (an unguarded write DOES contaminate). The guarded
# cases prove isolation contains the same write. The final check runs the full
# test suite under the same injected GIT_DIR and validates that the shared
# config remains byte-identical throughout.
#
# The uchg flag should NOT be re-added reflexively. If it is re-added, it must
# be a conscious decision to layer defense in depth, not a reflex triggered by
# finding the flag missing.

# Include guard. The array below is `readonly`, so a second source in the same
# process would abort with "readonly variable" — fatal under `set -e`. Today
# every test is dispatched as its own subprocess by run-tests.sh, so that cannot
# happen; the guard means a future caller that sources a test inline does not
# discover this the hard way.
if [[ -n "${_GIT_ENV_ISOLATION_LOADED:-}" ]]; then
  return 0
fi
readonly _GIT_ENV_ISOLATION_LOADED=1

# Variables that redirect repository-local state. Git knows its own list, so ask
# it rather than hardcoding one that silently rots as git versions change:
# `git rev-parse --local-env-vars` is the authoritative enumeration.
#
# The fallback below is NOT a duplicate of that list kept in sync by hand — it
# is a floor for the case where `git rev-parse` is unavailable or fails. It
# deliberately includes GIT_QUARANTINE_PATH and GIT_INTERNAL_SUPER_PREFIX, which
# are NOT in git 2.50's --local-env-vars output but do redirect state in the
# contexts where git sets them (quarantine during receive-pack, super-prefix
# during recursive submodule operations). Union, never intersection: an extra
# unset of a variable this test was never going to use is free, whereas a
# missing one is the bug this file exists to prevent.
readonly _GIT_ENV_FALLBACK=(
  GIT_ALTERNATE_OBJECT_DIRECTORIES
  GIT_COMMON_DIR
  GIT_CONFIG
  GIT_CONFIG_COUNT
  GIT_CONFIG_PARAMETERS
  GIT_DIR
  GIT_GRAFT_FILE
  GIT_IMPLICIT_WORK_TREE
  GIT_INDEX_FILE
  GIT_INTERNAL_SUPER_PREFIX
  GIT_NO_REPLACE_OBJECTS
  GIT_OBJECT_DIRECTORY
  GIT_PREFIX
  GIT_QUARANTINE_PATH
  GIT_REPLACE_REF_BASE
  GIT_SHALLOW_FILE
  GIT_WORK_TREE
)

# isolate_git_env [ceiling_dir]
#
# Unsets every repository-selection variable. If ceiling_dir is given, also sets
# GIT_CEILING_DIRECTORIES so that a git command run from a scratch directory
# cannot walk UP out of it and discover the real repo — which is the other half
# of the containment, and the failure mode that survives even a fully cleared
# environment (a bare `git config` in a directory that is not a repo searches
# parent directories).
isolate_git_env() {
  local ceiling="${1:-}"
  local var
  local -a to_unset=("${_GIT_ENV_FALLBACK[@]}")

  # Ask git for its own list and add anything the fallback missed. Failure here
  # is not fatal: the fallback already covers every variable implicated in #239.
  local git_reported
  if git_reported="$(git rev-parse --local-env-vars 2>/dev/null)"; then
    while IFS= read -r var; do
      [[ -n "${var}" ]] || continue
      to_unset+=("${var}")
    done <<<"${git_reported}"
  fi

  # GIT_CONFIG_KEY_<n> / GIT_CONFIG_VALUE_<n> carry `-c` overrides alongside
  # GIT_CONFIG_COUNT. They are inert once the count is gone, but leaving a
  # partial set behind means a test that later sets its own count inherits
  # someone else's keys. Clear the whole family.
  for var in $(compgen -v 2>/dev/null | grep -E '^GIT_CONFIG_(KEY|VALUE)_[0-9]+$' || true); do
    to_unset+=("${var}")
  done

  unset "${to_unset[@]}"

  if [[ -n "${ceiling}" ]]; then
    export GIT_CEILING_DIRECTORIES="${ceiling}"
  fi
}
