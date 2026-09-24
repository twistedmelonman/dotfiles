#!/usr/bin/env bash
# ~/.config/bash/gpush-wrapper.sh
# shellcheck shell=bash
# Canonical implementation of `gpush`: push the current branch, create (or
# reuse) its PR, watch CI, then optionally confirm+merge. Interactive and
# CLI-only — never invoked by non-interactive tooling. Two invocation modes,
# same idea as gh-wrapper.sh but simpler (no identity-switch/merge-bypass
# logic to duplicate, since gpush already goes through the git and gh
# wrappers for anything security-relevant):
#
# Usage: gpush [--no-merge]
#   --no-merge  Stop after CI passes (don't authorize or merge)
#
#   1. Sourced from functions.sh: defines gpush() as a bash function.
#   2. Symlinked as ~/.local/bin/gpush and executed directly: runs gpush
#      with the script's own arguments. This exists purely so gpush can be
#      invoked as a standalone command outside a shell that has
#      functions.sh sourced (e.g. BASH_ENV unset) — gpush has no need for a
#      guard/bypass distinction the way gh does, so this mode is just a
#      thin dispatch, not a separate implementation.

gpush() {
  # Validate arguments
  case "${1:-}" in
    --no-merge) ;;
    "") ;;
    *)
      echo "Usage: gpush [--no-merge]" >&2
      return 1
      ;;
  esac

  local no_merge=false
  if [[ "${1:-}" == "--no-merge" ]]; then
    no_merge=true
  fi

  local GREEN='\033[0;32m'
  local RED='\033[0;31m'
  local BLUE='\033[0;34m'
  local NC='\033[0m'

  # Step 1: Guard — refuse to run on main/master
  local branch
  branch=$(git symbolic-ref --short HEAD 2>/dev/null || echo "")
  if [[ -z "${branch}" || "${branch}" == "main" || "${branch}" == "master" ]]; then
    echo -e "${RED}[gpush]${NC} Refusing to run on ${branch:-detached HEAD}. Create a branch first." >&2
    return 1
  fi
  echo -e "${BLUE}[gpush]${NC} Branch: ${branch}"

  # Step 2: Push
  echo -e "${BLUE}[gpush]${NC} Pushing to origin..."
  if ! git push -u origin HEAD; then
    echo -e "${RED}[gpush]${NC} Push failed." >&2
    return 1
  fi

  # Step 3: Create PR (or detect existing one)
  local pr_number=""
  local pr_output
  echo -e "${BLUE}[gpush]${NC} Creating PR..."
  if pr_output=$(gh pr create --fill 2>&1); then
    # Extract PR number from URL in output (last line is typically the URL)
    pr_number=$(echo "${pr_output}" | grep -oE '/pull/[0-9]+' | tail -1 | grep -oE '[0-9]+')
    if [[ -z "${pr_number}" ]]; then
      echo -e "${RED}[gpush]${NC} Could not parse PR number from create output." >&2
      echo "${pr_output}" >&2
      return 1
    fi
    echo -e "${GREEN}[gpush]${NC} Created PR #${pr_number}"
  else
    # PR may already exist
    if echo "${pr_output}" | grep -qi "already exists"; then
      pr_number=$(gh pr view --json number -q .number 2>/dev/null)
      if [[ -n "${pr_number}" ]]; then
        echo -e "${BLUE}[gpush]${NC} PR #${pr_number} already exists, continuing"
      else
        echo -e "${RED}[gpush]${NC} PR already exists but could not retrieve its number — check 'gh pr view' manually." >&2
        return 1
      fi
    fi
    if [[ -z "${pr_number}" ]]; then
      echo -e "${RED}[gpush]${NC} Failed to create PR:" >&2
      echo "${pr_output}" >&2
      return 1
    fi
  fi

  # Step 4: Watch CI (use gh run watch — gh pr checks fails with PAT errors)
  # Anchor on the pushed commit SHA to avoid watching a stale run from a prior push.
  # A push can trigger multiple workflow runs (e.g. "Claude Blocking Review" +
  # "Dependabot Auto-Merge"). We fetch all runs for the commit, watch each one,
  # and skip runs whose workflow name matches ignorable_when_skipped when their
  # conclusion is "skipped" (e.g. Dependabot workflows on non-Dependabot branches).
  local head_sha
  head_sha=$(git rev-parse HEAD)
  echo -e "${BLUE}[gpush]${NC} Waiting for CI runs on ${head_sha:0:7}..."

  local ignorable_when_skipped=("Dependabot")
  local all_runs=""
  local attempts=0
  while [[ -z "${all_runs}" && ${attempts} -lt 30 ]]; do
    all_runs=$(gh run list --branch "${branch}" --commit "${head_sha}" --json databaseId,name -q '.[] | (.databaseId | tostring) + "\t" + .name' 2>/dev/null || true)
    if [[ -z "${all_runs}" ]]; then
      ((attempts += 1))
      sleep 2
    fi
  done
  if [[ -z "${all_runs}" ]]; then
    echo -e "${RED}[gpush]${NC} No CI runs found for ${head_sha:0:7} after 60s. Check GitHub Actions." >&2
    return 1
  fi

  # Re-poll after a short delay to catch late-registering workflows.
  # Only adopt the result if non-empty — a transient API failure must not
  # discard the known-good first poll.
  sleep 3
  local repoll
  repoll=$(gh run list --branch "${branch}" --commit "${head_sha}" --json databaseId,name -q '.[] | (.databaseId | tostring) + "\t" + .name' 2>/dev/null || true)
  if [[ -n "${repoll}" ]]; then
    all_runs=$(printf '%s\n%s\n' "${all_runs}" "${repoll}" | sort -u -t$'\t' -k1,1)
  fi

  local ci_passed=false
  local ci_failed=false
  local fail_detail=""
  local run_id run_name pattern
  while IFS=$'\t' read -r run_id run_name; do
    [[ -z "${run_id}" ]] && continue
    echo -e "${BLUE}[gpush]${NC} Watching run ${run_id} (${run_name})..."
    timeout 3600 gh run watch "${run_id}" >/dev/null 2>&1 || true

    local run_conclusion
    run_conclusion=$(gh run view "${run_id}" --json conclusion --jq '.conclusion') || {
      echo -e "${RED}[gpush]${NC} Failed to query run ${run_id} status." >&2
      return 1
    }

    if [[ -z "${run_conclusion}" || "${run_conclusion}" == "null" ]]; then
      echo -e "${RED}[gpush]${NC} CI run ${run_id} did not complete within 1 hour — check status manually: gh run view ${run_id}" >&2
      return 1
    fi

    if [[ "${run_conclusion}" == "success" ]]; then
      echo -e "${GREEN}[gpush]${NC} Passed: ${run_name}"
      ci_passed=true
    elif [[ "${run_conclusion}" == "skipped" ]]; then
      local ignorable=false
      for pattern in "${ignorable_when_skipped[@]}"; do
        if [[ "${run_name}" == *"${pattern}"* ]]; then
          ignorable=true
          break
        fi
      done
      if [[ "${ignorable}" == true ]]; then
        echo -e "${BLUE}[gpush]${NC} Ignoring skipped run: ${run_name}"
      else
        ci_failed=true
        fail_detail+="${run_name}: ${run_conclusion}; "
      fi
    else
      ci_failed=true
      fail_detail+="${run_name}: ${run_conclusion}; "
    fi
  done <<<"${all_runs}"

  if [[ "${ci_failed}" == true ]]; then
    fail_detail="${fail_detail%; }"
    echo -e "${RED}[gpush]${NC} CI failed (${fail_detail}). Fix and re-run gpush." >&2
    return 1
  fi
  if [[ "${ci_passed}" == false ]]; then
    echo -e "${RED}[gpush]${NC} No CI runs succeeded (all were skipped). Check GitHub Actions." >&2
    return 1
  fi
  echo -e "${GREEN}[gpush]${NC} CI passed"

  if [[ "${no_merge}" == true ]]; then
    echo -e "${GREEN}[gpush]${NC} --no-merge: stopping after CI. PR #${pr_number} is ready."
    return 0
  fi

  # Step 5: Confirm and authorize merge
  local confirm
  echo ""
  read -r -p "[gpush] Merge PR #${pr_number}? [y/N] " confirm
  if [[ ! "${confirm}" =~ ^[Yy]$ ]]; then
    echo -e "${BLUE}[gpush]${NC} Merge cancelled. PR #${pr_number} is ready for manual merge."
    return 0
  fi

  if ! command -v merge-lock &>/dev/null; then
    echo -e "${RED}[gpush]${NC} merge-lock not found on PATH." >&2
    return 1
  fi
  if ! merge-lock auth "${pr_number}" "gpush"; then
    echo -e "${RED}[gpush]${NC} merge-lock authorization failed." >&2
    return 1
  fi

  # Step 6: Merge (goes through gh wrapper → pre-merge-review.sh)
  echo -e "${BLUE}[gpush]${NC} Merging PR #${pr_number}..."
  if ! gh pr merge "${pr_number}" --squash --delete-branch; then
    echo -e "${RED}[gpush]${NC} Merge failed. Check pre-merge review output above." >&2
    return 1
  fi
  echo -e "${GREEN}[gpush]${NC} PR #${pr_number} merged"

  # Step 7: Cleanup — handle each step independently
  local default_branch
  default_branch=$(git remote show origin 2>/dev/null | awk '/HEAD branch/ {print $NF}')
  default_branch="${default_branch:-main}"
  echo -e "${BLUE}[gpush]${NC} Cleaning up..."
  if ! git switch "${default_branch}"; then
    echo -e "${RED}[gpush]${NC} Failed to switch to ${default_branch}." >&2
    return 1
  fi
  if ! git pull --ff-only; then
    echo -e "${RED}[gpush]${NC} Fast-forward pull of ${default_branch} failed — local branch has diverged from origin. Resolve manually with 'git pull' or 'git rebase'." >&2
    return 1
  fi
  git branch -D "${branch}" 2>/dev/null || true
  echo -e "${GREEN}[gpush]${NC} Done. Back on ${default_branch}."
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  # --- Standalone-executable mode (executed directly, e.g. via the
  # ~/.local/bin/gpush symlink) ---
  set -euo pipefail
  gpush "$@"
else
  # --- Function-definition mode (sourced from functions.sh) ---
  # Deliberately NOT exported — user-facing interactive command only.
  # Subshell/non-bash access is served by the ~/.local/bin/gpush symlink.
  :
fi
