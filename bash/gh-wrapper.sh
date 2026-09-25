#!/usr/bin/env bash
# ~/.config/bash/gh-wrapper.sh
# shellcheck shell=bash
# Canonical implementation of the `gh` identity auto-switch, PR-merge guard
# (pre-merge review + REST/GraphQL merge-bypass blocking), and off-org draft
# enforcement (`gh pr create` targeting a repo outside
# smartwatermelon/nightowlstudiollc is forced to --draft, no opt-out). One
# file, two invocation modes:
#
#   1. Sourced from functions.sh: defines gh() as a bash function. This wins
#      over PATH lookup for any bash process — interactive shells (via
#      .bash_profile -> main.sh) and non-interactive ones too, since
#      ~/.claude/settings.json sets BASH_ENV=~/.config/bash/functions.sh so
#      Claude Code's own Bash tool sources it as well.
#   2. Symlinked as ~/.local/bin/gh and executed directly: acts as a
#      standalone wrapper. This is the fallback for anything that reaches
#      `gh` without going through a bash process that has BASH_ENV in
#      effect — GUI apps, LaunchAgents/cron with a stripped environment,
#      editor git integrations, other language runtimes shelling out to
#      `gh`, etc.
#
# _GH_REVIEW_DONE guards against running pre-merge-review.sh twice when both
# layers fire in the same call chain: the bash function runs first, then
# calls `command gh`, which (since ~/.local/bin is early in PATH) finds this
# same file again in standalone-wrapper mode.

# Deliberately NOT defaulted from ${HOME} here. This file is sourced once, but
# ${HOME} at source time is not necessarily ${HOME} at call time: anything that
# reassigns HOME afterwards -- test harnesses above all -- would still get the
# sourcing user's path and silently run the REAL hook instead of the mock under
# test. The variable is also exported below, so a stale value propagates into
# every child process, including test runners started from an interactive
# shell. Resolved per call by _gh_wrapper_review_script_path instead; set this
# variable explicitly to override the location.
: "${_gh_wrapper_review_script:=}"

# Resolve the pre-merge review script at call time.
#
# An explicit non-empty ${_gh_wrapper_review_script} wins, so callers (and
# tests) can point this anywhere. Otherwise the location is derived from the
# CURRENT ${HOME}, which is what makes a sandboxed HOME work.
_gh_wrapper_review_script_path() {
  if [[ -n "${_gh_wrapper_review_script}" ]]; then
    printf '%s\n' "${_gh_wrapper_review_script}"
  else
    printf '%s\n' "${HOME}/.claude/hooks/pre-merge-review.sh"
  fi
}

# Resolves the repo owner a gh invocation is acting on: an explicit -R/--repo
# target on the command line takes precedence (that's the repo the call
# actually acts on), falling back to cwd's git remote only when no such flag
# is given. This keeps behavior consistent regardless of which repo checkout
# the caller happens to be sitting in — see smartwatermelon/dotfiles#135.
#
# Shared by _gh_wrapper_sync_identity (identity auto-switch) and
# _gh_wrapper_force_draft_for_off_org (draft enforcement) so the two checks
# can never drift on what "owner" means for a given invocation — prints the
# resolved owner (raw case) on stdout, or nothing if it can't be resolved.
#
# `--owner X` (gh search, gh project, ...) names the owner too, and sits
# between the two: -R still wins, but a single --owner beats cwd, so
# `gh search issues --owner=nightowlstudiollc` resolves the same from a Beacon
# checkout as from anywhere else. A comma-separated owner list could span both
# identities, so it is ignored and cwd decides, as before.
_gh_wrapper_resolve_owner() {
  local repo_flag_value owner_flag_value skip_next="" arg remote_url owner

  repo_flag_value=""
  owner_flag_value=""
  for arg in "$@"; do
    [[ "${arg}" == "--" ]] && break
    if [[ "${skip_next}" == "repo" ]]; then
      repo_flag_value="${arg}"
      break
    fi
    if [[ "${skip_next}" == "owner" ]]; then
      owner_flag_value="${arg}"
      skip_next=""
      continue
    fi
    case "${arg}" in
      -R | --repo) skip_next="repo" ;;
      --repo=*)
        repo_flag_value="${arg#--repo=}"
        break
        ;;
      -R*)
        repo_flag_value="${arg#-R}"
        break
        ;;
      --owner) skip_next="owner" ;;
      --owner=*) owner_flag_value="${arg#--owner=}" ;;
      *) ;;
    esac
  done

  if [[ -z "${repo_flag_value}" && -n "${owner_flag_value}" && "${owner_flag_value}" != *,* ]]; then
    printf '%s\n' "${owner_flag_value}"
    return 0
  fi

  # `gh api` takes no -R; the repo it acts on is in the endpoint. The first
  # argument shaped like `repos/OWNER/...` (leading slash optional) names the
  # owner. Anchoring on `repos/` keeps flag values (`-X GET`, `-f k=v`,
  # `--jq .x`) from matching. A `{owner}` placeholder is not an owner: gh fills
  # it from cwd, so cwd decides, as below. smartwatermelon/claude-wrapper#126.
  if [[ -z "${repo_flag_value}" && "${1:-}" == "api" ]]; then
    local api_owner_re='^/?repos/([^/{}]+)(/|$)'
    for arg in "${@:2}"; do
      [[ "${arg}" == "--" ]] && break
      if [[ "${arg}" =~ ${api_owner_re} ]]; then
        printf '%s\n' "${BASH_REMATCH[1]}"
        return 0
      fi
    done
  fi

  if [[ -n "${repo_flag_value}" ]]; then
    # -R/--repo takes OWNER/REPO or a full URL; owner is always the first
    # path segment after stripping any host/scheme prefix.
    owner=$(printf '%s\n' "${repo_flag_value}" | sed -E 's#^(git@[^:]+:|[a-zA-Z]+://[^/]+/)##; s#/.*##')
  else
    remote_url=$(command git config --get remote.origin.url 2>/dev/null)
    [[ -z "${remote_url}" ]] && return 0
    owner=$(printf '%s\n' "${remote_url}" | sed -E 's#^(git@[^:]+:|[a-zA-Z]+://[^/]+/)##; s#/.*##')
  fi
  [[ -z "${owner}" ]] && return 0
  printf '%s\n' "${owner}"
}

# Directory whose subtree marks a checkout as Beacon work. Built from ${HOME}
# so it resolves on any machine regardless of username (the work machine's
# home is /Users/arich, this one's is /Users/andrewrich — same layout, so the
# same default is correct for both). No trailing slash —
# _gh_wrapper_is_beacon_context appends its own when matching.
#
# Whether a missing beacon dir is worth warning about depends on whether the
# caller set it explicitly: an explicitly-configured path that doesn't exist is
# a misconfiguration, while an unset default that doesn't exist is just a
# machine with no Beacon work on it (the normal personal-machine state).
#
# That distinction is evaluated lazily, at check time, rather than being cached
# in a variable here. A cached flag would be exported into subshells and go
# stale the moment anything set GH_WRAPPER_BEACON_DIR after this file was
# sourced — the stale value then silently decides whether the warning fires.
# _gh_wrapper_beacon_dir_is_explicit re-derives it from the live environment on
# every call, so setting the variable at any point behaves identically.
_gh_wrapper_beacon_dir_is_explicit() {
  [[ "${GH_WRAPPER_BEACON_DIR:-}" != "${_GH_WRAPPER_BEACON_DIR_DEFAULT}" ]]
}

# bash/env.sh is the canonical definition of BEACON_WORKDIR, but this file
# also runs in standalone-wrapper mode (LaunchAgents/cron/GUI apps with a
# stripped environment) where env.sh was never sourced, so the default is
# spelled out here as a fallback. Keep the two in sync.
_GH_WRAPPER_BEACON_DIR_DEFAULT="${BEACON_WORKDIR:-${HOME}/Developer/beacon-biosignals}"
: "${GH_WRAPPER_BEACON_DIR:=${_GH_WRAPPER_BEACON_DIR_DEFAULT}}"

# Second-tier signal for the "Beacon work, but not under the beacon-biosignals
# org" case: repos created/forked during Beacon work that live under a
# personal or third-party owner (e.g. andrewmrich/git-pkgs-proxy, a fork of an
# unrelated upstream). Owner name alone can't classify those, so fall back to
# where the checkout lives and what it was forked from.
#
# Two signals, checked in order:
#   1. The repo's toplevel is inside ${GH_WRAPPER_BEACON_DIR}.
#   2. An `upstream` remote pointing at the beacon-biosignals org.
#
# Both are cwd-relative by nature, so this is only consulted for owners that
# aren't explicitly claimed by either identity (see _gh_wrapper_sync_identity).
# Returns 0 (true) if this looks like Beacon work.
_gh_wrapper_is_beacon_context() {
  local toplevel upstream_url upstream_owner

  # Signal 1: checkout location. Compare canonicalized paths so symlinked
  # checkouts and trailing-slash differences don't produce false negatives.
  # An explicitly-configured beacon dir that doesn't exist means the path
  # signal can never fire — warn rather than silently falling through to the
  # default identity, which is the same class of wrong-identity bug this
  # mapping exists to prevent. Warn once per process so it stays a signal
  # rather than noise on every unclaimed-owner invocation.
  if [[ ! -d "${GH_WRAPPER_BEACON_DIR}" && -z "${_GH_WRAPPER_BEACON_DIR_WARNED:-}" ]] \
    && _gh_wrapper_beacon_dir_is_explicit; then
    # Deliberately not exported: the latch is per-process, so a subshell that
    # inherits the exported gh() gets one warning of its own rather than
    # inheriting a "already warned" state it never saw output for.
    _GH_WRAPPER_BEACON_DIR_WARNED=1
    echo "[gh] WARNING: GH_WRAPPER_BEACON_DIR is set to '${GH_WRAPPER_BEACON_DIR}' but that directory does not exist." >&2
    echo "[gh] The Beacon checkout-path signal cannot fire; identity may fall back to the default." >&2
  fi

  toplevel=$(command git rev-parse --show-toplevel 2>/dev/null)
  if [[ -n "${toplevel}" && -d "${GH_WRAPPER_BEACON_DIR}" ]]; then
    local real_top real_beacon
    real_top=$(realpath "${toplevel}" 2>/dev/null || printf '%s' "${toplevel}")
    real_beacon=$(realpath "${GH_WRAPPER_BEACON_DIR}" 2>/dev/null || printf '%s' "${GH_WRAPPER_BEACON_DIR}")
    # Match the dir itself or anything beneath it, but not a sibling whose
    # name merely shares the prefix (…/beacon-biosignals-scratch).
    if [[ "${real_top}" == "${real_beacon}" || "${real_top}" == "${real_beacon}/"* ]]; then
      return 0
    fi
  fi

  # Signal 2: forked from the beacon-biosignals org. Uses the same
  # host/scheme-stripping shape as _gh_wrapper_resolve_owner.
  upstream_url=$(command git config --get remote.upstream.url 2>/dev/null)
  if [[ -n "${upstream_url}" ]]; then
    upstream_owner=$(printf '%s\n' "${upstream_url}" | sed -E 's#^(git@[^:]+:|[a-zA-Z]+://[^/]+/)##; s#/.*##')
    [[ "${upstream_owner,,}" == "beacon-biosignals" ]] && return 0
  fi

  return 1
}

# The keyring login gh will use: the `user:` under `github.com:` in hosts.yml.
# Empty when no host entry exists.
_gh_wrapper_keyring_login() {
  awk '/^github\.com:/{f=1} f && /^ *user:/{print $2; exit}' "${HOME}/.config/gh/hosts.yml" 2>/dev/null | tr -d "\"'"
}

# Every login the keyring holds for github.com, one per line: the keys of the
# `users:` block. Those keys sit one indent level deeper than `users:` itself,
# which is what separates them from siblings like `user:` and `git_protocol:`.
# Empty when the block is absent (older hosts.yml files omit it).
_gh_wrapper_keyring_users() {
  awk '
    /^github\.com:/ { host = 1; next }
    /^[^[:space:]]/ { host = 0; users = 0; login_indent = 0; next }
    host && match($0, /^[[:space:]]*users:[[:space:]]*$/) {
      users = 1
      login_indent = 0
      users_indent = index($0, "u") - 1
      next
    }
    users && match($0, /^[[:space:]]*[^[:space:]#][^:]*:/) {
      indent = match($0, /[^[:space:]]/) - 1
      if (indent <= users_indent) { users = 0; next }
      # A login key sits at the first indent level inside the block. Anything
      # deeper is that login`s own settings (oauth_token:, git_protocol:), not
      # another account.
      if (login_indent == 0) { login_indent = indent }
      if (indent != login_indent) { next }
      key = $0
      sub(/^[[:space:]]*/, "", key)
      sub(/:.*$/, "", key)
      print key
    }
  ' "${HOME}/.config/gh/hosts.yml" 2>/dev/null | tr -d "\"'"
}

# The login to hand `gh auth switch`. `desired` may not exist in the keyring
# yet, and switching to an account gh does not have fails outright. Prefer the
# keyring's own casing when a case-insensitive match is held, else `desired`
# unchanged so the caller still fails closed with its own message.
_gh_wrapper_resolve_switch_target() {
  local desired="$1"
  local held_logins
  held_logins="$(_gh_wrapper_keyring_users)" || held_logins=""

  local held
  while IFS= read -r held; do
    [[ -z "${held}" ]] && continue
    if [[ "${held,,}" == "${desired,,}" ]]; then
      printf '%s' "${held}"
      return 0
    fi
  done <<<"${held_logins}"

  printf '%s' "${desired}"
}

# The environment variable holding the fine-grained token for `owner`, or
# nothing for an owner without one. claude-wrapper exports all three into an
# agent session (_load_owner_gh_tokens); functions.sh's my_issues/my_prs use
# the same names. The mapping is by resource owner, not by login.
_gh_wrapper_owner_token_var() {
  case "${1,,}" in
    smartwatermelon) printf '%s\n' GH_TOKEN_SWM ;;
    nightowlstudiollc) printf '%s\n' GH_TOKEN_NOS ;;
    twistedmelonman) printf '%s\n' GH_TOKEN_TWM ;;
    *) ;;
  esac
}

# gh has one active account per host (not per repo), unlike git+SSH which
# already resolves the right identity per remote via ~/.ssh/config host
# aliases. This keeps gh in sync with that same per-repo intent.
#
# Mapping, in precedence order:
#   1. Owners explicitly claimed by an identity win outright, in BOTH
#      directions — smartwatermelon/nightowlstudiollc/twistedmelonman ->
#      twistedmelonman, beacon-biosignals/andrewmrich -> andrewmrich. An
#      explicitly-owned repo means the same thing no matter which directory
#      you invoke gh from, preserving the cwd-independence established in
#      smartwatermelon/dotfiles#135.
#   2. Otherwise (an owner claimed by neither — a third-party org, an
#      upstream you've been added to), consult the Beacon-context heuristic:
#      checkout under the beacon dir, or forked from beacon-biosignals.
#   3. Otherwise, default to twistedmelonman. This is the personal-default
#      environment; Beacon work is the specifically-marked exception.
#
# Local-only (reads/writes gh's config file, no network), so it's cheap to
# run on every invocation. Caveat: this mutates global gh state, so
# concurrent shells working in different-owner repos at the same time can
# race each other.
#
# Token selection (smartwatermelon/claude-wrapper#126). When GH_TOKEN is set
# and the resolved owner has its own fine-grained token in the environment
# (see _gh_wrapper_owner_token_var), that token is used for this one call.
# This function is the only place that decides it: it records the chosen
# variable NAME in _gh_wrapper_token_var, and each mode applies it only to the
# real gh process -- never exported into the caller's shell. A fine-grained
# PAT binds to exactly one resource owner, so the launch token acting on any
# other owner is a 403 at best; selection replaces the old owner-mismatch
# refusal wherever a matching token exists. With GH_TOKEN unset, the keyring
# stays in charge and nothing is selected.
_gh_wrapper_sync_identity() {
  local owner desired current

  _gh_wrapper_token_var=""
  owner="$(_gh_wrapper_resolve_owner "$@")"
  [[ -z "${owner}" ]] && return 0

  # smartwatermelon is the ORG (2026-09 migration); nightowlstudiollc is the
  # other org; twistedmelonman is the personal account that owns both and
  # keeps the archived repos and forks. All three resolve to the person.
  #
  # Still asserted, not verified: nothing here confirms the twistedmelonman
  # gh account is actually authorized against either org's repos. A `gh auth
  # status` check cross-referencing the account's authorized orgs would
  # confirm it; left as a future enhancement rather than scope creep here.
  case "${owner,,}" in
    smartwatermelon | nightowlstudiollc | twistedmelonman) desired="twistedmelonman" ;;
    beacon-biosignals | andrewmrich) desired="andrewmrich" ;;
    *)
      if _gh_wrapper_is_beacon_context; then
        desired="andrewmrich"
      else
        desired="twistedmelonman"
      fi
      ;;
  esac

  # The owner's own token, when one is set, is the answer outright: it was
  # issued for this owner, so there is no identity left to check and no
  # `gh api user` round-trip to pay.
  if [[ -n "${GH_TOKEN:-}" ]]; then
    local owner_token_var
    owner_token_var="$(_gh_wrapper_owner_token_var "${owner}")"
    if [[ -n "${owner_token_var}" && -n "${!owner_token_var:-}" ]]; then
      _gh_wrapper_token_var="${owner_token_var}"
    fi
  fi

  # No owner token to select (an owner outside the three, or its variable is
  # unset): GH_TOKEN is used as given. It outranks the keyring identity that
  # `gh auth switch` selects, so the hosts.yml check below verifies this
  # function's own output rather than the auth `gh` will actually use. When
  # the token represents a different identity than the resolved owner needs,
  # fail closed instead of silently acting as the wrong account.
  #
  # CLAUDE_GH_TOKEN_LOGIN names the identity GH_TOKEN authenticates as. The
  # test fixture sets it directly. In production it is unset, so the `gh api
  # user` fallback below resolves it — one network call per invocation. See
  # Step 11: session-level caching is a known follow-up, deliberately not
  # built here.
  if [[ -n "${GH_TOKEN:-}" && -z "${_gh_wrapper_token_var}" ]]; then
    local token_login="${CLAUDE_GH_TOKEN_LOGIN:-}"
    # Why resolution failed, so the advice below can match the actual cause
    # instead of guessing "expired". Three paths reach the same dead end and
    # they need different fixes: no real gh on PATH, the API call failing
    # (expired/revoked), and the call succeeding with output that is not a
    # login (something on PATH answered as gh but is not gh).
    local unresolved_reason="api_failed"

    if [[ -z "${token_login}" ]]; then
      # NOT `command gh`: ~/.local/bin/gh is this same wrapper and precedes
      # the real binary in PATH, so `command` re-enters this function.
      # _gh_wrapper_find_real_gh scans PATH while skipping this file.
      local real_gh
      if real_gh="$(_gh_wrapper_find_real_gh)"; then
        # Exit status, not output emptiness, decides success here. `gh api`
        # writes its error body to STDOUT, so a rejected token yields
        # `{"message": "Bad credentials", ...}` — non-empty, and mistaken for a
        # login name by any check that only tests for emptiness. Discard the
        # output unless the call actually succeeded.
        local api_out
        if api_out="$(GH_TOKEN="${GH_TOKEN}" "${real_gh}" api user --jq .login 2>/dev/null)"; then
          token_login="${api_out}"
        else
          unresolved_reason="api_failed"
        fi
      else
        unresolved_reason="no_real_gh"
      fi
    fi

    # A login is a single GitHub username: alphanumerics and hyphens, nothing
    # else. Anything multi-line or punctuated is an error body that reached here
    # some other way, and must never be compared against `desired` as though it
    # named an identity.
    if [[ -n "${token_login}" && ! "${token_login}" =~ ^[A-Za-z0-9-]+$ ]]; then
      token_login=""
      # The call SUCCEEDED and returned something that is not a login, so the
      # token is not the suspect — whatever answered as `gh` is. A test suite
      # that stubs `gh` on PATH hits this, because the PATH scan below finds
      # the stub (smartwatermelon/scripts#177).
      unresolved_reason="bad_output"
    fi

    if [[ -z "${token_login}" ]]; then
      echo "[gh] ERROR: GH_TOKEN is set but its identity could not be resolved" >&2
      echo "[gh] Refusing to run: GH_TOKEN overrides 'gh auth switch', so the" >&2
      echo "[gh] identity check cannot be trusted." >&2

      # Never echo the captured output itself. A shadowing binary can print
      # anything, including a credential, and this goes to stderr in every
      # session; the resolved path is what identifies the culprit anyway.
      case "${unresolved_reason}" in
        bad_output)
          echo "[gh] The identity lookup SUCCEEDED but did not return a login name," >&2
          echo "[gh] so the token is probably fine — something on PATH is answering" >&2
          echo "[gh] as 'gh' but is not gh. Resolved to:" >&2
          echo "[gh]   ${real_gh:-<unknown>}" >&2
          echo "[gh] Fix: remove that entry from PATH. If it is a test stub, unset" >&2
          echo "[gh] GH_TOKEN for the test so this check is skipped." >&2
          echo "[gh] Inspect with: type -a gh" >&2
          ;;
        no_real_gh)
          echo "[gh] No real 'gh' binary was found in PATH (see the error above)," >&2
          echo "[gh] so the identity could not be checked at all." >&2
          echo "[gh] Fix: install gh, or repair PATH. Inspect with: type -a gh" >&2
          ;;
        *)
          echo "[gh] Most likely the token is expired or revoked. Check with:" >&2
          echo "[gh]   gh api -i user | grep -i token-expiration" >&2
          echo "[gh] Fix: rotate the token, or unset GH_TOKEN to use the keyring" >&2
          echo "[gh] identity." >&2
          ;;
      esac
      return 1
    fi

    if [[ "${token_login,,}" != "${desired,,}" ]]; then
      echo "[gh] ERROR: GH_TOKEN authenticates as '${token_login}' but repo owner '${owner}' requires '${desired}'" >&2
      echo "[gh] GH_TOKEN takes precedence over 'gh auth switch', so this would" >&2
      echo "[gh] run as the wrong identity. Failing closed." >&2
      echo "[gh] Fix: unset GH_TOKEN to use the keyring identity for this repo." >&2
      return 1
    fi
  fi

  current="$(_gh_wrapper_keyring_login)"

  if [[ -n "${current}" && "${current,,}" != "${desired,,}" ]]; then
    # Not `desired` verbatim: `gh auth switch` matches logins by exact casing
    # and fails for an account it does not hold. Resolve to the keyring's own
    # casing when held; otherwise pass `desired` through so the switch fails
    # and we fail closed below.
    local target
    target="$(_gh_wrapper_resolve_switch_target "${desired}")"
    if ! command gh auth switch --hostname github.com --user "${target}" >/dev/null 2>&1; then
      echo "[gh] ERROR: failed to switch identity to '${target}' (repo owner: '${owner}') — refusing to run as '${current}' instead" >&2
      echo "[gh] If '${target}' is not authenticated on this machine, run: gh auth login --hostname github.com" >&2
      echo "[gh] Failing closed rather than acting on '${owner}' as the wrong identity." >&2
      return 1
    fi
  fi
}

# Find the real `gh` binary, skipping ourselves. Only meaningful in
# standalone-wrapper mode.
_gh_wrapper_find_real_gh() {
  local self
  self="$(realpath "${BASH_SOURCE[0]}")"

  local IFS=':'
  local dir candidate candidate_real
  for dir in ${PATH}; do
    candidate="${dir}/gh"
    if [[ -x "${candidate}" ]]; then
      candidate_real="$(realpath "${candidate}" 2>/dev/null || true)"
      if [[ -n "${candidate_real}" ]] && [[ "${candidate_real}" != "${self}" ]]; then
        printf '%s\n' "${candidate}"
        return 0
      fi
    fi
  done

  printf '[gh-wrapper] Error: Could not find real gh binary in PATH\n' >&2
  return 1
}

# Blocks REST/GraphQL PR-merge bypass vectors that skip pre-merge-review.sh
# and the merge-lock check entirely. Returns 1 if the call should be blocked.
_gh_wrapper_block_bypass() {
  if [[ "${1:-}" == "api" ]] && printf '%s\n' "$*" | grep -qE 'pulls/[0-9]+/merge([[:space:]]|$|[^[:alnum:]_])'; then
    echo "[gh] BLOCKED: Direct REST API PR merge bypasses pre-merge review and merge authorization." >&2
    echo "[gh] This endpoint skips pre-merge-review.sh and the merge-lock check." >&2
    echo "[gh] Use 'gh pr merge <number>' instead." >&2
    echo "[gh] If gh pr merge fails, report the failure and ask the human to merge manually." >&2
    return 1
  fi

  if [[ "${1:-}" == "api" ]] && printf '%s\n' "$*" | grep -qE 'graphql.*mergePullRequest[[:space:]]*\('; then
    echo "[gh] BLOCKED: GraphQL mergePullRequest mutation bypasses pre-merge review and merge authorization." >&2
    echo "[gh] Use 'gh pr merge <number>' instead." >&2
    echo "[gh] If gh pr merge fails, report the failure and ask the human to merge manually." >&2
    return 1
  fi

  return 0
}

# Runs pre-merge-review.sh if this call is `gh pr merge`. Returns 1 to block.
# Parses args past known two-token global flags to find the actual
# subcommand, handling both `gh pr merge NNN` and `gh -R owner/repo pr merge
# NNN`.
#
# $1: "strict" or "warn" — how to react if the review script is missing.
# "strict" (standalone-wrapper mode) fails closed, since that mode is the
# fallback safety net for callers with no other guard layer. "warn"
# (function mode) matches the original bash-function behavior of warning
# and proceeding, since a bash session has other opportunities to catch a
# misconfigured review script.
_gh_wrapper_maybe_review() {
  local missing_script_mode="$1"
  shift

  local sub="" subsub="" skip_next=0 arg
  for arg in "$@"; do
    # -- end-of-options sentinel: everything after it is positional, even if
    # it looks like a flag. Mirrors the fix pattern from PR #146
    # (_gh_wrapper_sync_identity) for smartwatermelon/dotfiles#153.
    [[ "${arg}" == "--" ]] && break
    if [[ "${skip_next}" == "1" ]]; then
      skip_next=0
      continue
    fi
    case "${arg}" in
      -R | --repo | --hostname | --config-dir | --token) skip_next=1 ;;
      # Combined short-flag form (-Rowner/repo): the value is embedded in
      # this same token, so there's no next arg to skip — just consume this
      # one token without treating it as `sub`. See PR #146 / issue #153.
      -R*) ;;
      --*=*) ;; # --flag=value: single token, no separate value to skip
      -*) ;;    # other single-token flags: skip
      *)
        if [[ -z "${sub}" ]]; then
          sub="${arg}"
        else
          subsub="${arg}"
          break
        fi
        ;;
    esac
  done

  if [[ "${sub}" == "pr" && "${subsub}" == "merge" ]]; then
    local _review_script
    _review_script="$(_gh_wrapper_review_script_path)"
    if [[ -x "${_review_script}" ]]; then
      "${_review_script}" "$@" || return 1
    elif [[ "${missing_script_mode}" == "strict" ]]; then
      echo "[gh] ERROR: pre-merge review script not found or not executable: ${_review_script}" >&2
      echo "[gh] Refusing to proceed with an unguarded merge." >&2
      return 1
    else
      echo "[gh] Warning: pre-merge review script not found or not executable" >&2
      echo "[gh] Expected: ${_review_script}" >&2
      echo "[gh] Proceeding without review..." >&2
    fi
  fi
  return 0
}

# Hard, mechanical guard: a PR created against a repo outside the two orgs
# this environment is scoped to (smartwatermelon/nightowlstudiollc) must
# land as a draft, unconditionally — no AI judgement call, no opt-out flag,
# no environment-variable escape hatch. Later promotion out of draft is a
# manual, human-only action via the GitHub UI; this function only concerns
# itself with creation time. See smartwatermelon/dotfiles#174.
#
# Bash can't let a function reassign the caller's positional params, so this
# prints the (possibly modified) argument list, NUL-separated, on stdout; the
# caller rebuilds its array with `mapfile -d ''`. NUL (not newline) because
# argument values themselves may contain embedded newlines (e.g. a multi-line
# --body) — a newline delimiter can't be told apart from one inside a value,
# which shreds such args into multiple positional params downstream. NUL
# cannot appear in a shell argument, so it's an unambiguous separator. Prints
# nothing for zero args (callers already guard with `[[ "$#" -gt 0 ]]`
# accordingly); otherwise always prints at least the original args,
# NUL-separated, so callers can unconditionally replace their arg array
# from the output.
#
# Parses args with the same sub/subsub walk as _gh_wrapper_maybe_review, so
# `pr create` detection can't drift between the two.
_gh_wrapper_force_draft_for_off_org() {
  local sub="" subsub="" skip_next=0 arg owner

  for arg in "$@"; do
    [[ "${arg}" == "--" ]] && break
    if [[ "${skip_next}" == "1" ]]; then
      skip_next=0
      continue
    fi
    case "${arg}" in
      -R | --repo | --hostname | --config-dir | --token) skip_next=1 ;;
      -R*) ;;
      --*=*) ;;
      -*) ;;
      *)
        if [[ -z "${sub}" ]]; then
          sub="${arg}"
        else
          subsub="${arg}"
          break
        fi
        ;;
    esac
  done

  if [[ "${sub}" == "pr" && "${subsub}" == "create" ]]; then
    owner="$(_gh_wrapper_resolve_owner "$@")"
    if [[ -n "${owner}" ]]; then
      case "${owner,,}" in
        smartwatermelon | nightowlstudiollc | twistedmelonman) ;; # in-org: no change
        *)
          # Off-org target: force --draft. Don't bother deduplicating if the
          # caller already passed --draft (or --draft=false, which gh doesn't
          # support as a real flag) — an extra --draft is harmless, and the
          # point is nothing the caller does can produce a non-draft PR here.
          printf '%s\0' "$@"
          printf -- '--draft\0'
          return 0
          ;;
      esac
    fi
  fi

  # printf with zero operands still runs its format string once, emitting a
  # single stray NUL for `"$@"` empty — guard so zero args truly produces
  # zero bytes of output, matching `mapfile -d ''`'s empty-array behavior.
  [[ "$#" -gt 0 ]] && printf '%s\0' "$@"
  return 0
}

# --- approval gate: gh api fields ----------------------------------------------
# Classify the fields of a `gh api` call for _gh_wrapper_approval_gate. Sets
# that function's locals `inline` and `files` (bash scoping is dynamic, so a
# callee sees its caller's locals); it is not meant to be called on its own.
#
# The one verifiable form is `-F/--field body=@<path>`: that makes gh read the
# value from the file, so the file's bytes are what gets posted. `-f` and
# `--raw-field` never expand `@`, so `-f body=@/x` posts the literal string and
# counts as inline. A GraphQL `query` that is a mutation setting a `body:`
# argument carries its text inline too. Fields not named body -- state, labels,
# titles -- are not prose and pass.
#
# NOT covered: `--input <json>`, which carries a body inside a JSON document.
# Blocking it outright would also block ruleset and protection writes that
# carry no prose. Same limit as hook-block-personify.sh.
_gh_wrapper_api_body_fields() {
  local arg flag="" field key val skip_next=0
  local gql_body_re='mutation.*[^[:alnum:]_]body[[:space:]]*:'
  for arg in "$@"; do
    [[ "${arg}" == "--" ]] && break
    if [[ "${skip_next}" == "1" ]]; then
      skip_next=0
      continue
    fi
    field=""
    if [[ -n "${flag}" ]]; then
      field="${arg}"
    else
      case "${arg}" in
        -X | --method | -H | --header | -q | --jq | -t | --template | --input | --cache | -p | --preview | --hostname)
          skip_next=1
          ;;
        -f | -F | --field | --raw-field)
          flag="${arg}"
          continue
          ;;
        --field=* | --raw-field=*)
          flag="${arg%%=*}"
          field="${arg#*=}"
          ;;
        -f?* | -F?*)
          flag="${arg:0:2}"
          field="${arg:2}"
          ;;
        *) ;;
      esac
    fi
    if [[ -n "${field}" ]]; then
      key="${field%%=*}"
      val="${field#*=}"
      if [[ "${field}" == *=* && "${key}" == "body" ]]; then
        if [[ ("${flag}" == "-F" || "${flag}" == "--field") && "${val}" == @* ]]; then
          files+=("${val#@}")
        else
          inline=1
        fi
      elif [[ "${key}" == "query" && "${val}" =~ ${gql_body_re} ]]; then
        inline=1
      fi
    fi
    flag=""
  done
  return 0
}

# --- approval gate -------------------------------------------------------------
# Refuse to write PR or issue body text unless Andrew has visually approved
# those exact bytes. Approval lives on disk in gate-review's approved/
# directory; this asks gate-review whether the body file hashes to something
# approved.
#
# An earlier version of this function read PERSONIFY_OK from the environment.
# That channel is DEAD and must not be reintroduced: the Bash tool runs in a
# process that does not inherit the interactive shell's environment, so an
# env-var ack is unsatisfiable by the human, not merely strict. Measured
# 2026-09-18. See hook-block-personify.sh for the full note.
#
# Manual-invocation half; ~/.claude/scripts/hook-block-personify.sh covers the
# Bash-tool path. Redundant by design, so neither one being bypassed lets text
# through. The rule enforced here is deliberately identical to the hook's, so
# the human learns one rule and not two:
#
#   --body-file/-F with an ABSOLUTE path -> verifiable, checked
#   --body/-b "inline text"              -> blocked, nothing to hash
#   a RELATIVE path or ~/... or $VAR/... -> blocked, resolved against a cwd
#       this function and gh may disagree about
#
# TITLES stay ungated -- one line by nature. A subcommand carrying no body flag
# passes, so `gh pr edit --add-label` and `gh pr review --approve` are unaffected.
#
# Fails CLOSED when gate-review.sh is absent, matching hook-block-personify.sh.
# A redundant pair whose halves disagree about the unverifiable case is not
# redundant. A machine without claude-config installed cannot write PR bodies
# through this wrapper; that is the intended outcome, not an oversight.
#
# `gh pr review` follows the same body rule as `gh pr edit`. `gh api` is gated
# when it sends a field named `body` or a GraphQL mutation with a body argument
# (claude-config#548); see _gh_wrapper_api_body_fields.
#
# Same arg walk as _gh_wrapper_force_draft_for_off_org so detection cannot drift.
_gh_wrapper_approval_gate() {
  local sub="" subsub="" skip_next=0 arg
  local body_file="" inline=0 want_path=0

  for arg in "$@"; do
    [[ "${arg}" == "--" ]] && break
    if [[ "${skip_next}" == "1" ]]; then
      skip_next=0
      continue
    fi
    if [[ "${want_path}" == "1" ]]; then
      body_file="${arg}"
      want_path=0
      continue
    fi
    case "${arg}" in
      -R | --repo | --hostname | --config-dir | --token) skip_next=1 ;;
      -b | --body) inline=1 ;;
      --body=* | -b=*) inline=1 ;;
      -F | --body-file) want_path=1 ;;
      --body-file=*) body_file="${arg#*=}" ;;
      -F*) body_file="${arg#-F}" ;;
      -R*) ;;
      --*=*) ;;
      -*) ;;
      *)
        if [[ -z "${sub}" ]]; then
          sub="${arg}"
        elif [[ -z "${subsub}" ]]; then
          subsub="${arg}"
        fi
        ;;
    esac
  done

  local -a files=()
  case "${sub}/${subsub}" in
    pr/create | pr/comment | pr/edit | pr/review | issue/create | issue/comment | issue/edit)
      [[ -n "${body_file}" ]] && files=("${body_file}")
      ;;
    api/*)
      # -F means --field here, not --body-file: discard the generic walk's
      # reading and classify the fields instead.
      inline=0
      _gh_wrapper_api_body_fields "$@"
      ;;
    *) return 0 ;;
  esac

  # No body flag at all: no prose is being written. Titles and labels pass.
  if [[ "${inline}" == "0" && "${#files[@]}" == "0" ]]; then
    return 0
  fi

  local gate="${HOME}/.claude/scripts/gate-review.sh"
  local reason=""

  # Time-boxed suspension: Andrew writes ~/.claude/gate-review/SUSPENDED by
  # hand, holding the last day it applies. gate-review.sh owns the parsing and
  # prints a notice when it lets a body through, so this layer and
  # hook-block-personify.sh cannot disagree about what counts. A missing
  # gate-review.sh is not a suspension; it falls through and blocks below. So
  # does a gate-review.sh from before `suspended` existed: it rejects the
  # unknown subcommand with exit 1, which reads as "not suspended". Its stderr
  # is shown only on success, so that older version's usage error does not
  # print on every gated call.
  local notice=""
  if [[ -x "${gate}" ]] && notice="$("${gate}" suspended 2>&1 >/dev/null)"; then
    [[ -n "${notice}" ]] && printf '%s\n' "${notice}" >&2
    return 0
  fi

  if [[ "${inline}" == "1" ]]; then
    reason="text given inline; only a file can be verified"
  else
    # Every named file must verify: an approved first body must not carry an
    # unapproved second one through.
    for body_file in "${files[@]}"; do
      if [[ "${body_file}" != /* ]]; then
        reason="path '${body_file}' is not absolute; gh and this gate would resolve it differently"
      elif [[ ! -f "${body_file}" ]]; then
        reason="no such file: ${body_file}"
      elif [[ ! -x "${gate}" ]]; then
        reason="gate-review.sh missing at ${gate}; cannot verify"
      elif ! "${gate}" check "${body_file}"; then
        reason="the bytes in ${body_file} do not match anything approved"
      fi
      [[ -n "${reason}" ]] && break
    done
    [[ -n "${reason}" ]] || return 0
  fi

  local rerun="gh ${sub} ${subsub} --title t --body-file ${HOME}/.claude/gate-review/approved/<label>"
  [[ "${sub}" == "api" ]] \
    && rerun="gh api ${subsub} -F body=@${HOME}/.claude/gate-review/approved/<label>"

  {
    echo "[gh] 🛑 BLOCKED: ${sub} ${subsub} body has not been visually approved."
    echo "[gh]"
    echo "[gh]   reason: ${reason}"
    echo "[gh]"
    echo "[gh] Every PR and issue body must be read and approved in the editor"
    echo "[gh] before it is written. To do that:"
    echo "[gh]"
    echo "[gh]   1. Write the body to a file."
    echo "[gh]   2. ${gate} stage <label> <file>"
    echo "[gh]   3. ${gate} open"
    echo "[gh]   4. Andrew reads the batch and types APPROVED in the STATUS line."
    echo "[gh]   5. Re-run against the APPROVED file, absolute path:"
    echo "[gh]        ${rerun}"
    echo "[gh]"
    echo "[gh]      Use the approved copy, not the file you staged: if he edited"
    echo "[gh]      the text in the editor, his edits are what he approved and"
    echo "[gh]      the original no longer matches."
    echo "[gh]"
    echo "[gh] Approval is his to give. Staging and opening on his behalf is fine;"
    echo "[gh] typing the word for him is not."
  } >&2
  return 1
}

# --- F4: scope-error hint ------------------------------------------------------
# GH_TOKEN (the CCCLI PAT) and the keyring token are the same login; only the
# scopes differ. When gh fails because the active token lacks a scope, say
# exactly how to re-run the one command with the other token. Detection is
# gh's own ScopesSuggestion text, so there is no command classifier to get
# wrong. Design: dev-env docs/superpowers/specs/2026-09-03-org-migration-design.md.
#
# Never widen the PAT: it is exported into every session, so a scope added
# there applies to every call rather than the one that needed it.

# Print the scope named in a captured stderr file, or nothing. The character
# class accepts either quote style, so the hint keeps working whichever one gh
# emits; pinning a single one would silently disable it if that ever changed.
# Measured against gh 2.x (2026-09), which uses "...".
_gh_wrapper_scope_from_file() {
  grep -oE "needs the [\"'][A-Za-z0-9:_]+[\"'] scope" "$1" 2>/dev/null \
    | head -1 | sed -E "s/needs the [\"']([^\"']+)[\"'] scope/\1/"
}

# Re-quote argv for display, replacing the VALUE of any flag that routinely
# carries a secret with <redacted>. The hint is printed to stderr, which lands
# in terminal scrollback, CI logs and transcripts — echoing `--body ghp_...`
# back would copy a live credential into all three. Redaction is by flag name,
# not by pattern-matching the value: guessing what a secret looks like fails
# open on every format not anticipated, whereas the flag says outright that
# whatever follows it is a value the caller chose to pass secretly.
#
# Flags covered (gh's real pairings: -b/--body, -F/--field, -f/--raw-field,
# -H/--header) in all three spellings pflag accepts: `--body VALUE` and
# `-b VALUE` (value in the next argument), `--body=VALUE` (value after `=`),
# and the stuck short form `-bVALUE` (value glued to the flag letter). A
# literal `--` ends flag parsing, as in the other argv scanners in this file.
#
# For the key=value flags (-f/-F/--field/--raw-field) only the part after the
# first `=` is redacted, so `-f body=SECRET` prints as `-f body=<redacted>`:
# the key names the API field and is not secret, and keeping it leaves the
# suggested command recognizable. A value with no `=` is redacted whole.
_gh_wrapper_redact_argv() {
  local out="" arg redact_next="" past_dashdash=0
  for arg in "$@"; do
    if [[ -n "${redact_next}" ]]; then
      out+="$(_gh_wrapper_redact_value "${redact_next}" "${arg}") "
      redact_next=""
      continue
    fi
    if [[ "${past_dashdash}" == "1" ]]; then
      out+="$(printf '%q ' "${arg}")"
      continue
    fi
    case "${arg}" in
      --)
        past_dashdash=1
        out+="-- "
        ;;
      -b | --body | -H | --header)
        redact_next=whole
        out+="$(printf '%q ' "${arg}")"
        ;;
      -f | -F | --field | --raw-field)
        redact_next=keyed
        out+="$(printf '%q ' "${arg}")"
        ;;
      --body=* | --header=*)
        # %q with no trailing space: the `=` must abut the flag name, and
        # `printf '%q '` would wedge a space in between.
        out+="$(printf '%q' "${arg%%=*}")=$(_gh_wrapper_redact_value whole "${arg#*=}") "
        ;;
      --field=* | --raw-field=*)
        out+="$(printf '%q' "${arg%%=*}")=$(_gh_wrapper_redact_value keyed "${arg#*=}") "
        ;;
      -b?* | -H?*)
        out+="${arg:0:2}$(_gh_wrapper_redact_value whole "${arg:2}") "
        ;;
      -f?* | -F?*)
        out+="${arg:0:2}$(_gh_wrapper_redact_value keyed "${arg:2}") "
        ;;
      *) out+="$(printf '%q ' "${arg}")" ;;
    esac
  done
  printf '%s' "${out% }"
}

# Redact one flag value. mode=whole replaces all of it; mode=keyed keeps a
# leading `key=` and replaces what follows (or the whole value if it has no
# `=`). The kept key is re-quoted so the result stays pasteable.
_gh_wrapper_redact_value() {
  local mode="$1" value="$2"
  if [[ "${mode}" == "keyed" && "${value}" == *=* ]]; then
    printf '%q=<redacted>' "${value%%=*}"
  else
    printf '<redacted>'
  fi
}

# Print the hint for `scope`, quoting the original argv back so the suggested
# command can be pasted verbatim (secret-bearing flag values excepted — see
# _gh_wrapper_redact_argv).
_gh_wrapper_print_scope_hint() {
  local scope="$1"
  shift
  local cmd
  cmd="$(_gh_wrapper_redact_argv "$@")"
  # gh reads GH_TOKEN first, then GITHUB_TOKEN. Name whichever is actually set:
  # telling someone to unset GH_TOKEN when GITHUB_TOKEN is what authenticated
  # them is advice that cannot work, and `gh auth refresh` is equally useless
  # here — it rewrites the keyring token, which an env-var token overrides.
  # The caller only reaches this function when one of the two is set.
  local token_var="GH_TOKEN"
  if [[ -z "${GH_TOKEN:-}" ]]; then
    token_var="GITHUB_TOKEN"
  fi
  local keyring
  keyring="$(_gh_wrapper_keyring_login)"
  # The login stays on the same line as its label: a reader grepping the
  # hint for the account name should find it next to the word naming it,
  # not wrapped onto the following line.
  echo "[gh] ${token_var} is set and lacks the '${scope}' scope." >&2
  echo "[gh] The keyring identity for ${keyring:-<none in hosts.yml>} has it." >&2
  echo "[gh] Re-run this one command without ${token_var}:" >&2
  echo "[gh]   env -u ${token_var} gh ${cmd}" >&2
  echo "[gh] (Do not add the scope to the CCCLI PAT — it is exported into every session.)" >&2
}

# Run the real gh. stderr goes to the terminal live AND to a temp file; stdout
# is untouched. On non-zero exit, a scope error in the file triggers the hint.
# The real exit code is returned.
#
# Not `exec`: the hint needs gh's exit status and stderr after it returns.
# Only called when an env-var token is set (see the standalone branch): the
# tee pipe costs gh's stderr its TTY and can reorder stderr against stdout,
# which is acceptable in an agent session and not at a human's terminal.
_gh_wrapper_run_with_scope_hint() {
  local real_gh="$1"
  shift
  local errfile rc=0
  # No temp file means no detection, but the command itself must still run —
  # degrade to a plain passthrough rather than failing the call.
  if ! errfile="$(mktemp "${TMPDIR:-/tmp}/gh-wrapper-stderr.XXXXXX")"; then
    "${real_gh}" "$@"
    return $?
  fi
  # A signal that kills the wrapper mid-run skips the rm -f at the bottom and
  # leaves one temp file behind per interrupted run.
  #
  # RETURN alone does NOT fix that: measured, a RETURN trap does not fire when
  # the shell is killed by SIGTERM — the process dies without unwinding the
  # function. An explicit signal trap is required. RETURN is kept for the
  # ordinary paths (including the `return` below), and the signal handler
  # re-raises after cleanup so the caller still sees a signal death (128+n)
  # rather than a normal exit.
  #
  # The handler also forwards the signal to gh. Before F4 the wrapper exec'd
  # gh, so a signal aimed at "the gh process" hit gh. Now that pid is the
  # wrapper's; without forwarding, gh would run on as an orphan after the
  # wrapper died. Ctrl-C already reaches the whole foreground process group,
  # so this matters for a targeted kill (`timeout gh ...`, `kill <pid>`).
  #
  # gh runs in the BACKGROUND and the wrapper `wait`s for it. This is not
  # optional: bash defers a trapped signal until a foreground command
  # finishes (measured — a SIGTERM to the wrapper during a foreground
  # `gh | tee` pipeline was not acted on until gh exited on its own, so the
  # handler could neither forward nor clean up). Only `wait` returns at once
  # on a trapped signal, running the handler immediately. The explicit `<&0`
  # is defensive: only a job-control (interactive) shell gives a background
  # child /dev/null as stdin, and this path runs non-interactively — but the
  # function is exported, so it is kept correct for a sourced caller too.
  # Non-interactive bash starts background children with SIGINT ignored (Go
  # leaves an ignored signal ignored), so INT is forwarded as TERM. `kill` is
  # guarded because `set -e` applies inside the handler.
  #
  # stderr goes through a process substitution running tee: gh writes to a
  # dynamically allocated fd ({errfd}, so a repeat call in one shell cannot
  # clobber a still-open fd and orphan the previous tee), tee copies to the
  # file and the real stderr. gh gets the fd closed so it does not inherit
  # the write end. After gh exits the fd is closed and tee is waited for, so
  # the file is complete before it is read. tee buffers, so a PARTIAL-line
  # write to stderr — gh's interactive prompts, which deliberately omit the
  # trailing newline — can surface after stdout that was written later.
  # Whole lines are unaffected, and stdout bypasses the pipe entirely.
  local gh_pid="" tee_pid="" errfd=""
  trap 'rm -f "${errfile}"' RETURN
  trap '[[ -n "${gh_pid}" ]] && kill -TERM "${gh_pid}" 2>/dev/null; rm -f "${errfile}"; trap - TERM HUP INT; kill -s TERM $$' TERM HUP INT
  exec {errfd}> >(tee "${errfile}" >&2 || true)
  tee_pid=$!
  "${real_gh}" "$@" 2>&"${errfd}" {errfd}>&- <&0 &
  gh_pid=$!
  # `|| rc=$?` keeps `set -e` (standalone mode) from aborting on a failing gh
  # before rc is read.
  wait "${gh_pid}" || rc=$?
  gh_pid=""
  exec {errfd}>&-
  wait "${tee_pid}" 2>/dev/null || true
  if [[ "${rc}" -ne 0 ]]; then
    local scope
    scope="$(_gh_wrapper_scope_from_file "${errfile}")"
    if [[ -n "${scope}" ]]; then
      _gh_wrapper_print_scope_hint "${scope}" "$@"
    fi
    # No owner resolved means no token was selected: this ran with the
    # launch-directory GH_TOKEN, which may belong to another owner. An agent
    # that sees the failure tends to start trying the other GH_TOKEN_* values;
    # stop it instead. Same resolver as selection, so the two cannot disagree
    # on "no owner". The exit code is not changed.
    # smartwatermelon/claude-wrapper#126 decision 3.
    if [[ -n "${GH_TOKEN:-}" && -z "$(_gh_wrapper_resolve_owner "$@")" ]]; then
      echo "[gh] No repo owner could be resolved, so this ran with the launch-directory GH_TOKEN and failed. Stop and ask Andrew for help; do not guess a different token." >&2
    fi
  fi
  rm -f "${errfile}"
  return "${rc}"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  # --- Standalone-wrapper mode (executed directly, e.g. via the
  # ~/.local/bin/gh symlink) ---
  set -euo pipefail

  # Note whether this is a help request, but the REST/GraphQL bypass block
  # below must run regardless — `gh api pulls/123/merge --help` must not
  # escape it by appending --help.
  _gh_wrapper_help=0
  for _gh_wrapper_arg in "$@"; do
    if [[ "${_gh_wrapper_arg}" == "--help" || "${_gh_wrapper_arg}" == "-h" ]]; then
      _gh_wrapper_help=1
      break
    fi
  done

  # Safe to skip all four checks when _GH_REVIEW_DONE is set: that only
  # happens when function mode already ran them before calling `command gh`
  # (which lands here). If a future change ever sets _GH_REVIEW_DONE before
  # running those checks in function mode, this skip becomes unsafe — keep
  # the two in lockstep.
  # Set by _gh_wrapper_sync_identity; applied just before gh runs, below.
  _gh_wrapper_token_var=""
  if [[ -z "${_GH_REVIEW_DONE:-}" ]]; then
    # Don't auto-switch identity while the user is managing accounts
    # directly, or for --help/-h — informational calls shouldn't mutate
    # global auth state.
    if [[ "${1:-}" != "auth" && "${_gh_wrapper_help}" != "1" ]]; then
      _gh_wrapper_sync_identity "$@" || exit 1
    fi
    _gh_wrapper_block_bypass "$@" || exit 1

    _gh_wrapper_approval_gate "$@" || exit 1
    if [[ "${_gh_wrapper_help}" != "1" ]]; then
      _gh_wrapper_maybe_review strict "$@" || exit 1
      # Off-org `gh pr create` must land as a draft — hard, mechanical,
      # no opt-out. Rebuild the positional params from the (possibly
      # --draft-appended) output; a function can't reassign "$@" directly.
      # NUL-delimited via process substitution (mapfile -d '' requires it —
      # command substitution can't carry NUL bytes at all; bash discards
      # them outright, so the NUL contract is structurally impossible
      # through `$(...)`). `|| true` is just to satisfy shellcheck SC2312
      # (don't mask a pipeline component's exit status): the function
      # always returns 0, so there's no real status being discarded. Only
      # rebuild when there's at least one original arg.
      if [[ "$#" -gt 0 ]]; then
        mapfile -t -d '' _gh_wrapper_new_args < <(_gh_wrapper_force_draft_for_off_org "$@" || true)
        # The function is contractually guaranteed to emit at least as many
        # elements as it received (it only ever appends --draft, never
        # drops args). A short rebuild means the producer failed partway
        # through — trust nothing and refuse rather than silently exec'ing
        # gh with a truncated command line (which could drop --draft itself).
        if [[ "${#_gh_wrapper_new_args[@]}" -lt "$#" ]]; then
          echo "[gh] ERROR: internal arg rebuild truncated; refusing to proceed" >&2
          exit 1
        fi
        set -- "${_gh_wrapper_new_args[@]}"
      fi
    fi
  fi

  # Only needed for the final gh invocation below — computed here (after the
  # _GH_REVIEW_DONE-guarded checks above) rather than unconditionally at the
  # top of this block, so we don't do a needless PATH scan before knowing
  # this call is going to pass those checks.
  REAL_GH="$(_gh_wrapper_find_real_gh)"
  # Defensive: _gh_wrapper_find_real_gh currently fails hard on lookup
  # failure (and set -e aborts the assignment), but if it ever returns 0
  # with empty output we'd otherwise run "" "$@" and produce a confusing
  # low-level "command not found" error. Check explicitly instead.
  if [[ -z "${REAL_GH}" ]]; then
    echo "[gh] ERROR: could not locate real gh binary on PATH" >&2
    exit 1
  fi

  # Apply the token _gh_wrapper_sync_identity selected, for the real gh only.
  # Set here, after the review hook, so both modes hand that hook the same
  # token (function mode applies it only on its final `command gh`). Entered
  # from function mode (_GH_REVIEW_DONE), this is "" and GH_TOKEN already
  # carries the selection.
  if [[ -n "${_gh_wrapper_token_var}" ]]; then
    GH_TOKEN="${!_gh_wrapper_token_var}"
    export GH_TOKEN
  fi

  # The F4 scope hint exists for one situation: an env-var token (GH_TOKEN, or
  # GITHUB_TOKEN as gh's fallback) is overriding the keyring and lacks a scope
  # the keyring token has. Only then is there anything to say beyond what gh
  # already prints (`gh auth refresh -s <scope>`). And the hint is for an
  # agent session, which cannot act on gh's own message: a human reading a
  # terminal can. So stderr is captured only when BOTH hold — an env token is
  # set AND stderr is not a terminal. Capturing costs gh its stderr TTY (colors,
  # and the interactive prompts of `gh auth login` / `gh pr create`, which
  # render on stderr) and lets tee reorder stderr against stdout; a human with
  # GH_TOKEN exported in an interactive shell must not pay that on every call.
  #
  # Otherwise, exec as before: gh owns the terminal outright and the wrapper
  # process is gone. Only this standalone path runs the hint — function mode
  # reaches it through `command gh`, which lands right here. If ~/.local/bin/gh
  # is not on PATH, no hint is printed; that is the documented limit.
  if [[ -z "${GH_TOKEN:-}" && -z "${GITHUB_TOKEN:-}" ]] || [[ -t 2 ]]; then
    exec "${REAL_GH}" "$@"
  fi
  _gh_wrapper_rc=0
  _gh_wrapper_run_with_scope_hint "${REAL_GH}" "$@" || _gh_wrapper_rc=$?
  exit "${_gh_wrapper_rc}"
else
  # --- Function-definition mode (sourced from functions.sh) ---
  gh() {
    # Note whether this is a help request, but the REST/GraphQL bypass block
    # below must run regardless — `gh api pulls/123/merge --help` must not
    # escape it by appending --help.
    local help=0 arg
    # Local, so _gh_wrapper_sync_identity's selection (dynamic scope) lives
    # only as long as this call.
    local _gh_wrapper_token_var=""
    for arg in "$@"; do
      if [[ "${arg}" == "--help" || "${arg}" == "-h" ]]; then
        help=1
        break
      fi
    done

    # Don't auto-switch identity while the user is managing accounts
    # directly, or for --help/-h — informational calls shouldn't mutate
    # global auth state.
    if [[ "${1:-}" != "auth" && "${help}" != "1" ]]; then
      _gh_wrapper_sync_identity "$@" || return 1
    fi

    _gh_wrapper_block_bypass "$@" || return 1

    _gh_wrapper_approval_gate "$@" || return 1

    if [[ "${help}" == "1" ]]; then
      # Set _GH_REVIEW_DONE so the ~/.local/bin/gh wrapper also skips review.
      _GH_REVIEW_DONE=1 command gh "$@"
      return $?
    fi

    _gh_wrapper_maybe_review warn "$@" || return 1

    # Off-org `gh pr create` must land as a draft — hard, mechanical, no
    # opt-out. Rebuild the positional params from the (possibly
    # --draft-appended) output; a function can't reassign "$@" directly.
    # NUL-delimited via process substitution — see the standalone-mode call
    # site above for why (embedded newlines in arg values, e.g. --body).
    # Only rebuild when there's at least one original arg.
    if [[ "$#" -gt 0 ]]; then
      local _gh_wrapper_new_args
      mapfile -t -d '' _gh_wrapper_new_args < <(_gh_wrapper_force_draft_for_off_org "$@" || true)
      # See the standalone-mode call site above: a short rebuild means the
      # producer failed partway through — refuse rather than silently
      # exec'ing gh with a truncated command line.
      if [[ "${#_gh_wrapper_new_args[@]}" -lt "$#" ]]; then
        echo "[gh] ERROR: internal arg rebuild truncated; refusing to proceed" >&2
        return 1
      fi
      set -- "${_gh_wrapper_new_args[@]}"
    fi

    # Run the real gh command. Set _GH_REVIEW_DONE so the ~/.local/bin/gh
    # wrapper (found again via `command gh`, since ~/.local/bin is early in
    # PATH) does not run the review a second time. A selected token is
    # passed as a prefix assignment, so it reaches gh without changing the
    # caller's GH_TOKEN.
    if [[ -n "${_gh_wrapper_token_var}" ]]; then
      GH_TOKEN="${!_gh_wrapper_token_var}" _GH_REVIEW_DONE=1 command gh "$@"
    else
      _GH_REVIEW_DONE=1 command gh "$@"
    fi
  }
  # Escape hatch to the real gh binary, bypassing identity auto-switch and
  # the merge guard entirely — same idea as suclaude for the claude wrapper.
  # Resolved via _gh_wrapper_find_real_gh (a PATH scan skipping this file)
  # rather than a hardcoded path, since ~/.local/bin/gh (unlike claude) IS
  # the wrapper itself, not a separate layer over a fixed real binary.
  sugh() {
    local real_gh
    real_gh="$(_gh_wrapper_find_real_gh)" || return 1
    "${real_gh}" "$@"
  }
  # Export gh AND the helpers it calls: an exported function only carries
  # its own body into subshells, not functions it calls. Without exporting
  # these too, gh() would break in any subshell that inherits the exported
  # gh but didn't source this file (e.g. BASH_ENV unset/overridden there).
  export -f gh sugh _gh_wrapper_block_bypass _gh_wrapper_approval_gate _gh_wrapper_api_body_fields _gh_wrapper_maybe_review _gh_wrapper_review_script_path _gh_wrapper_sync_identity _gh_wrapper_owner_token_var _gh_wrapper_find_real_gh _gh_wrapper_resolve_owner _gh_wrapper_force_draft_for_off_org _gh_wrapper_is_beacon_context _gh_wrapper_beacon_dir_is_explicit _gh_wrapper_keyring_login _gh_wrapper_keyring_users _gh_wrapper_resolve_switch_target _gh_wrapper_run_with_scope_hint _gh_wrapper_scope_from_file _gh_wrapper_print_scope_hint _gh_wrapper_redact_argv _gh_wrapper_redact_value
  export _gh_wrapper_review_script GH_WRAPPER_BEACON_DIR _GH_WRAPPER_BEACON_DIR_DEFAULT
fi
