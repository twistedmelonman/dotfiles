#!/usr/bin/env bash
set -euo pipefail

# Resolve the config the way CI does instead of leaving shellcheck to its
# ancestor search, which reaches $HOME and picked up enable=all -- 87 findings
# on a tree CI calls clean (claude-config#534).
#
# An empty result is the fresh-machine fallback: run bare rather than fail on a
# path the user never set.
#
# The resolver is a sibling symlink that install.sh creates. A machine that
# pulls this commit and has not re-run install.sh does not have it yet, and
# under `set -e` calling it would exit 127 and hard-block every commit touching
# a shell file. Degrade to shellcheck's own discovery and say why, rather than
# blocking work on a deploy step the user has not run yet.
_lint_shell_resolver="$(dirname "${BASH_SOURCE[0]}")/lint-shellcheck.sh"
shellcheck_rc=()
if [[ -x "${_lint_shell_resolver}" ]]; then
  SHELLCHECK_RCFILE="$("${_lint_shell_resolver}")"
  [[ -n "${SHELLCHECK_RCFILE}" ]] && shellcheck_rc=(--rcfile "${SHELLCHECK_RCFILE}")
else
  echo "[lint-shell] lint-shellcheck.sh not found at ${_lint_shell_resolver}" >&2
  echo "[lint-shell] run install.sh to link it; using shellcheck discovery meanwhile" >&2
  echo "[lint-shell] local findings may differ from CI (claude-config#534)" >&2
fi

# Track which files were modified and which have remaining issues
declare -A fixed_by_shellcheck=() fixed_by_shfmt=() failed_files=()
declare -A format_advisories=()
temp_files=()

# Cleanup temporary files on exit
cleanup() {
  for tmpfile in "${temp_files[@]}"; do
    rm -f "${tmpfile}"
  done
}
trap cleanup EXIT

# =========================================================
# PERMISSION VERIFICATION - Detect permission mismatches
# =========================================================
# Check for shell scripts with shebangs but missing +x permissions.
# This is a PASSIVE check - we warn and fail, but don't auto-fix.
# Claude Code CLI will handle the fix automatically.

permission_errors=()
for f in "$@"; do
  [[ -f "${f}" ]] || continue

  # Check if file has shebang but is missing +x
  if head -n1 "${f}" 2>/dev/null | grep -qE '^#!/' && [[ ! -x "${f}" ]]; then
    permission_errors+=("${f}")
  fi
done

# Report errors but don't auto-fix
if [[ ${#permission_errors[@]} -gt 0 ]]; then
  echo "" >&2
  echo "❌ Permission mismatch detected:" >&2
  for f in "${permission_errors[@]}"; do
    echo "   ${f} has shebang but is not executable" >&2
  done
  echo "" >&2
  echo "   Fix with: chmod +x <file>" >&2
  echo "   Or let Claude Code CLI handle this automatically" >&2
  echo "" >&2
  exit 1
fi

# =========================================================
# SHELLCHECK AND SHFMT PROCESSING
# =========================================================

for f in "$@"; do
  [[ -f "${f}" ]] || continue
  issues_remaining=""

  # --- ShellCheck ---
  if command -v shellcheck >/dev/null; then
    # Note: SC2312 warns about command substitutions in conditional contexts
    # where the exit code is masked. Excluded globally to reduce informational
    # noise. Re-enable with --exclude='' if stricter checking is needed.

    # Run shellcheck once in diff mode
    shellcheck_diff=$(shellcheck "${shellcheck_rc[@]}" --severity=warning --exclude=SC2312 --format=diff "${f}" 2>&1 || true)

    if [[ -n "${shellcheck_diff}" ]]; then
      # Try to auto-fix with diff output
      # Capture original permissions before creating tmpfile (macOS BSD stat)
      original_perms=$(stat -f "%OLp" "${f}")

      # Create tmpfile in same directory for atomic mv across filesystems
      tmpfile=$(mktemp "${f}.XXXXXX")
      temp_files+=("${tmpfile}")

      if cp "${f}" "${tmpfile}" && echo "${shellcheck_diff}" | patch --quiet "${tmpfile}" 2>/dev/null; then
        # Restore original permissions before replacing file
        chmod "${original_perms}" "${tmpfile}"
        mv "${tmpfile}" "${f}"
        fixed_by_shellcheck["${f}"]=1

        # After successful auto-fix, check if any issues remain
        if ! shellcheck "${shellcheck_rc[@]}" --severity=warning --exclude=SC2312 "${f}" >/dev/null 2>&1; then
          remaining=$(shellcheck "${shellcheck_rc[@]}" --severity=warning --exclude=SC2312 "${f}" 2>&1 || true)
          issues_remaining+="ShellCheck:\n${remaining}\n"
        fi
      else
        # Patch failed (e.g. issues not auto-fixable) - get human-readable output
        rm -f "${tmpfile}"
        remaining=$(shellcheck "${shellcheck_rc[@]}" --severity=warning --exclude=SC2312 "${f}" 2>&1 || true)
        issues_remaining+="ShellCheck:\n${remaining}\n"
      fi
    fi
  else
    echo "Error: shellcheck not found" >&2
    exit 1
  fi

  # --- shfmt ---
  if command -v shfmt >/dev/null; then
    # shfmt only consults .editorconfig when given no formatting flags; passing
    # -i/-ci/-bn suppresses that lookup. Search upward from the file for a
    # .editorconfig and defer to it when present; otherwise fall back to our
    # own defaults so repos without one keep prior behavior.
    shfmt_flags=()
    # CDPATH='' scopes out CDPATH for this cd so it can't resolve via CDPATH
    # search and echo the resolved path into this command substitution
    # (see smartwatermelon/dotfiles#176).
    editorconfig_dir="$(CDPATH='' cd "$(dirname "${f}")" && pwd)"
    has_editorconfig=false
    while true; do
      if [[ -f "${editorconfig_dir}/.editorconfig" ]]; then
        has_editorconfig=true
        break
      fi
      [[ "${editorconfig_dir}" == "/" ]] && break
      editorconfig_dir="$(dirname "${editorconfig_dir}")"
    done
    # No .editorconfig anywhere up to / means the repo has stated no
    # formatting preference. We have no authority to pick one for it: any
    # fallback style we impose can disagree with what the repo's own CI
    # enforces, and rewriting the file mid-commit turns that disagreement
    # into a commit that silently contradicts its own author
    # (smartwatermelon/dotfiles#290). Report the drift instead of fixing it,
    # and leave the repo's CI as the only authority on its format.
    if ! ${has_editorconfig}; then
      # Advisory only: record the drift against shfmt's own defaults and
      # leave the file untouched. shfmt -d exits non-zero when a diff exists,
      # so a non-empty capture is the finding; an empty one means clean.
      format_diff=$(shfmt -d "${f}" 2>/dev/null) || true
      if [[ -n "${format_diff}" ]]; then
        format_advisories["${f}"]="${format_diff}"
      fi
    # Check if formatting is needed (without modifying)
    elif shfmt -d "${shfmt_flags[@]}" "${f}" >/dev/null 2>&1; then
      # Already formatted correctly
      :
    else
      # Needs formatting - use atomic write via tmpfile
      # Capture original permissions before creating tmpfile (macOS BSD stat)
      original_perms=$(stat -f "%OLp" "${f}")

      # Create tmpfile in same directory for atomic mv across filesystems
      tmpfile=$(mktemp "${f}.XXXXXX")
      temp_files+=("${tmpfile}")

      if shfmt "${shfmt_flags[@]}" "${f}" >"${tmpfile}"; then
        # Restore original permissions before replacing file
        chmod "${original_perms}" "${tmpfile}"
        mv "${tmpfile}" "${f}"
        fixed_by_shfmt["${f}"]=1
      else
        rm -f "${tmpfile}"
        issues_remaining+="shfmt: Failed to format file\n"
      fi
    fi
  else
    echo "Error: shfmt not found" >&2
    exit 1
  fi

  # Track files with remaining issues
  if [[ -n "${issues_remaining}" ]]; then
    failed_files["${f}"]="${issues_remaining}"
  fi
done

# --- Summary ---
echo "----------------------------------------"

# Show files fixed by each tool (deduplicated)
all_fixed=()
for f in "${!fixed_by_shellcheck[@]}"; do
  all_fixed+=("${f} (shellcheck)")
done
for f in "${!fixed_by_shfmt[@]}"; do
  all_fixed+=("${f} (shfmt)")
done

if [[ ${#all_fixed[@]} -gt 0 ]]; then
  echo "✅ Auto-fixed files:"
  printf "  %s\n" "${all_fixed[@]}" | sort
fi

# Show formatting advisories (repos with no .editorconfig).
# Informational only - these never set has_failures and never block a commit.
# The repo has stated no formatting preference, so this is a note for the
# author and reviewer to reason over, not a standard to enforce.
if [[ ${#format_advisories[@]} -gt 0 ]]; then
  echo "ℹ️  Formatting notes (advisory - nothing was changed, commit not blocked):"
  for f in "${!format_advisories[@]}"; do
    printf "  %s\n" "${f}"
  done | sort
  echo "     No .editorconfig found, so this repo's format is its own to set."
  echo "     Diff vs shfmt defaults: shfmt -d <file>"
  echo "     To adopt a style here: add an .editorconfig (then shfmt auto-fixes)."
fi

# Check for failed files
has_failures=false
for f in "${!failed_files[@]}"; do
  if ! ${has_failures}; then
    echo "❌ Files with remaining issues:"
    has_failures=true
  fi
  printf "  %s\n" "${f}"
  printf "%b" "${failed_files[${f}]}" | sed 's/^/    /'
done

if ${has_failures}; then
  exit 1
elif [[ ${#format_advisories[@]} -gt 0 ]]; then
  # Nothing blocking, but don't claim "clean" over an open formatting note.
  echo "🎉 No blocking issues (see formatting notes above)."
else
  echo "🎉 All checked files are clean!"
fi
