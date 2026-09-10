#!/usr/bin/env bash
#shellcheck shell=bash
# Standalone verification of `pbrun`'s exit status and clipboard behavior.
# Run directly: bash bash/tests/test-pbrun-output-capture.sh
#
# pbrun runs a command, showing its output on the terminal while also copying
# that output to the clipboard. The obvious one-line implementation
#
#   "$@" |& tee >(pbcopy) | cat
#
# is wrong in two silent ways, and both are silent in exactly the situation a
# clipboard helper is used: interactively, where nobody inspects `$?`.
#
#   1. The pipeline's status is the LAST command's, so `pbrun false` returned 0.
#      Anything built on pbrun ("run it, bail if it fails") saw every failure as
#      a success.
#   2. Process substitution is not waited for. Bash reaps `>(pbcopy)`
#      asynchronously, so the function could return before pbcopy finished
#      writing, and a following `pbpaste` read the PREVIOUS clipboard contents.
#
# Both replacement branches keep pbcopy inside the pipeline (streaming) or call
# it synchronously (buffered), so neither can race. This test pins the observable
# contract rather than the implementation: whichever branch runs, the exit status
# must be the command's own and the clipboard must hold its combined output by
# the time pbrun returns.
#
# pbrun has two branches, selected by whether stdout is a terminal AND
# /dev/tty actually opens. A test that captures stdout — via $(...) or a
# redirect — forces the buffered branch every time, so the streaming branch is
# exercised through a real pty below; without that, a green run says nothing
# about half the function. Because both branches satisfy every behavioral
# assertion, the pty case also asserts which branch ran, so a future change
# that made the guard always-false could not silently delete that coverage.
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

# Extract the function through bash's own parser rather than slicing the file
# with a text pattern, so the test does not depend on source formatting.
_fn_src="$(bash --norc --noprofile -c '
  source "$1" >/dev/null 2>&1 || exit 1
  declare -f pbrun
' _ "${REPO_ROOT}/bash/functions.sh")"
if [[ -z "${_fn_src}" ]]; then
  echo "FAIL: could not extract pbrun from functions.sh" >&2
  echo "      (the function may have been renamed or removed)" >&2
  exit 1
fi

# A stub pbcopy on PATH keeps this runnable on Linux CI, where the real
# pasteboard does not exist, and makes the clipboard contents readable.
# It is a real executable rather than a shell function so it survives the
# pipeline and the pty subshell alike.
STUB_DIR="$(mktemp -d)"
CLIP_FILE="$(mktemp)"
# Declared empty up front so the trap can reference it before the pbcopy-absent
# case creates it; `set -u` would otherwise abort on the unset name.
sandbox=""
trap 'rm -rf "${STUB_DIR}" "${CLIP_FILE}" "${CLIP_FILE}.kind" ${sandbox:+"${sandbox}"}' EXIT

#
# The stub also records what kind of stdin it was handed, which is how the
# test tells the two branches apart: streaming ends in \`| pbcopy\` (a pipe),
# buffered uses \`pbcopy <file\` (a regular file).
cat >"${STUB_DIR}/pbcopy" <<STUB
#!/usr/bin/env bash
if [[ -p /dev/stdin ]]; then echo pipe; else echo file; fi >"${CLIP_FILE}.kind"
cat >"${CLIP_FILE}"
STUB
chmod +x "${STUB_DIR}/pbcopy"

# Harness sourced by both the buffered and the streamed run. It defines pbrun
# from the extracted source and a pbpaste that reads the stub's file, then runs
# the cases. Each case prints a machine-readable "key=value" line so the pty
# run can be parsed out of terminal output.
HARNESS="${STUB_DIR}/cases.sh"
cat >"${HARNESS}" <<'HARNESS_EOF'
pbpaste() { cat "${CLIP_FILE}"; }

pbrun false
echo "rc_false=$?"

pbrun true
echo "rc_true=$?"

pbrun bash -c 'exit 42'
echo "rc_42=$?"

# Clipboard must already hold this command's output when pbrun returns.
printf 'STALE' >"${CLIP_FILE}"
pbrun echo NEW
echo "clip_new=[$(pbpaste)]"

# stderr is part of what gets captured, so a failing command's diagnostics
# reach the clipboard too -- the main reason to use pbrun at all.
printf 'STALE' >"${CLIP_FILE}"
pbrun bash -c 'echo ERRTEXT >&2'
echo "clip_stderr=[$(pbpaste)]"

# Arguments must reach the command intact, not word-split.
printf 'STALE' >"${CLIP_FILE}"
pbrun printf '%s\n' 'a b'
echo "clip_spaces=[$(pbpaste)]"

# A no-argument call must not clobber the clipboard with empty output.
printf 'PRESERVE' >"${CLIP_FILE}"
pbrun 2>/dev/null
echo "rc_noargs=$?"
echo "clip_noargs=[$(pbpaste)]"

# Byte fidelity: the clipboard must hold exactly what the command emitted.
# Trailing newlines are the case that separates a file/pipe buffer from
# $(...), which strips them all. Reported as a byte count so the comparison
# does not itself go through a newline-stripping substitution.
printf 'STALE' >"${CLIP_FILE}"
pbrun printf 'a\n\n\n'
echo "clip_trailing_bytes=$(wc -c <"${CLIP_FILE}" | tr -d ' ')"

# A command that prints nothing must copy nothing, not a bare newline.
printf 'STALE' >"${CLIP_FILE}"
pbrun true
echo "clip_empty_bytes=$(wc -c <"${CLIP_FILE}" | tr -d ' ')"

# Which branch actually ran? Both satisfy every assertion above, so observe
# what pbrun DID rather than recomputing its condition here -- an independent
# copy of the `if` would still report "streaming" after a change that disabled
# streaming, which is exactly the regression this is here to catch.
#
# The stub records its stdin type, and the branches differ there: streaming
# ends the pipeline in `| pbcopy` (stdin is a pipe), buffered redirects a
# temp file into it (stdin is a regular file). The call must not redirect
# stdout, which would make `-t 1` false and force the buffered branch.
pbrun echo BRANCHPROBE
case "$(cat "${CLIP_FILE}.kind" 2>/dev/null)" in
  pipe) echo "branch=streaming" ;;
  file) echo "branch=buffered" ;;
  *) echo "branch=unknown" ;;
esac
HARNESS_EOF

# Assemble a runnable script: the extracted pbrun plus the cases.
RUNNER="${STUB_DIR}/runner.sh"
{
  echo "export CLIP_FILE='${CLIP_FILE}'"
  echo "export PATH='${STUB_DIR}':\${PATH}"
  printf '%s\n' "${_fn_src}"
  cat "${HARNESS}"
} >"${RUNNER}"

# Assert one key=value pair out of a run's captured output.
expect_kv() {
  local label="$1" key="$2" want="$3" output="$4" got
  got="$(printf '%s\n' "${output}" | grep -E "^${key}=" | head -1 | cut -d= -f2-)"
  # Terminal output arrives with CR line endings from the pty.
  got="${got%$'\r'}"
  check "${label}" "${want}" "${got}"
}

echo "Case: buffered branch (stdout is not a terminal)"
# Piping into cat makes `[[ -t 1 ]]` false, selecting the buffered branch.
buffered_out="$(bash "${RUNNER}" 2>/dev/null | cat)"
expect_kv "false propagates exit status" rc_false 1 "${buffered_out}"
expect_kv "true propagates exit status" rc_true 0 "${buffered_out}"
expect_kv "exit 42 propagates exit status" rc_42 42 "${buffered_out}"
expect_kv "clipboard holds fresh output on return" clip_new "[NEW]" "${buffered_out}"
expect_kv "stderr reaches the clipboard" clip_stderr "[ERRTEXT]" "${buffered_out}"
expect_kv "arguments are not word-split" clip_spaces "[a b]" "${buffered_out}"
expect_kv "no-arg call returns non-zero" rc_noargs 1 "${buffered_out}"
expect_kv "no-arg call preserves clipboard" clip_noargs "[PRESERVE]" "${buffered_out}"
expect_kv "trailing newlines preserved exactly" clip_trailing_bytes 4 "${buffered_out}"
expect_kv "empty output copies zero bytes" clip_empty_bytes 0 "${buffered_out}"
expect_kv "buffered branch was the one exercised" branch buffered "${buffered_out}"

echo
echo "Case: streaming branch (stdout is a terminal)"
# `[[ -t 1 ]]` is only true with a real terminal on stdout, so allocate a pty.
# Without this the streaming branch never executes and its exit-status handling
# (PIPESTATUS) goes untested. Python ships on macOS and on CI images alike.
if ! command -v python3 >/dev/null 2>&1; then
  echo "  SKIP: python3 not available to allocate a pty"
else
  streamed_out="$(python3 -c '
import os, pty, sys

with open(sys.argv[2], "wb") as sink:
    def read(fd):
        data = os.read(fd, 1024)
        sink.write(data)
        return data

    pty.spawn(["bash", sys.argv[1]], read)
' "${RUNNER}" "${STUB_DIR}/pty.out" >/dev/null 2>&1 && cat "${STUB_DIR}/pty.out")"

  # Guard against a silently empty pty run: if spawning failed, every
  # expect_kv below would compare "" against "" for absent keys and pass.
  if ! printf '%s\n' "${streamed_out}" | grep -qE '^rc_false='; then
    echo "  FAIL: pty run produced no results (streaming branch untested)"
    fail=1
  else
    expect_kv "false propagates exit status" rc_false 1 "${streamed_out}"
    expect_kv "true propagates exit status" rc_true 0 "${streamed_out}"
    expect_kv "exit 42 propagates exit status" rc_42 42 "${streamed_out}"
    expect_kv "clipboard holds fresh output on return" clip_new "[NEW]" "${streamed_out}"
    expect_kv "stderr reaches the clipboard" clip_stderr "[ERRTEXT]" "${streamed_out}"
    expect_kv "arguments are not word-split" clip_spaces "[a b]" "${streamed_out}"
    expect_kv "no-arg call returns non-zero" rc_noargs 1 "${streamed_out}"
    expect_kv "no-arg call preserves clipboard" clip_noargs "[PRESERVE]" "${streamed_out}"
    expect_kv "trailing newlines preserved exactly" clip_trailing_bytes 4 "${streamed_out}"
    expect_kv "empty output copies zero bytes" clip_empty_bytes 0 "${streamed_out}"

    # Pin that the pty run really took the streaming path. Without this, a
    # change making the guard always-false would leave every assertion above
    # green while deleting all streaming coverage.
    expect_kv "streaming branch was the one exercised" branch streaming "${streamed_out}"

    # The output the user sees must actually appear on the terminal. The
    # buffered branch cannot demonstrate this; only the pty run can. Anchored
    # to a whole line so it matches tee's echo of the command output, not the
    # "clip_new=[NEW]" report line that is printed either way.
    if printf '%s\n' "${streamed_out}" | grep -qE '^NEW'$'\r''?$'; then
      check "command output is visible on the terminal" "yes" "yes"
    else
      check "command output is visible on the terminal" "yes" "no"
    fi
  fi
fi

echo
echo "Case: pbcopy missing is reported, not silently ignored"
# On a system without pbcopy (Linux without a shim), pbrun must fail loudly
# rather than run the command and quietly drop the copy.
sandbox="$(mktemp -d)"
for c in bash cat echo printf tee mktemp; do
  p="$(command -v "${c}" 2>/dev/null)" && ln -sf "${p}" "${sandbox}/${c}"
done
no_pbcopy_rc=0
env -i PATH="${sandbox}" "${sandbox}/bash" -c "
  $(printf '%s\n' "${_fn_src}")
  pbrun echo hi >/dev/null 2>&1
" || no_pbcopy_rc=$?
check "returns non-zero when pbcopy is absent" 1 "${no_pbcopy_rc}"
rm -rf "${sandbox}"

echo
if [[ "${fail}" -eq 0 ]]; then
  echo "test-pbrun-output-capture: all cases passed"
else
  echo "test-pbrun-output-capture: FAILURES above"
fi
exit "${fail}"
