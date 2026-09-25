#!/usr/bin/env bash
#shellcheck shell=bash
# Standalone verification that git/hooks/lint-prettier.sh resolves plugins
# from the nearest package.json directory rather than the process cwd.
# Run directly: bash bash/tests/test-lint-prettier-nested-node-modules.sh
#
# Prettier resolves a `.prettierrc`'s `plugins:` entries relative to the
# process cwd, not to the config file that declares them. The old hook ran
# `npx prettier --write --ignore-unknown "$@"` from the repo root, so a repo
# with per-package node_modules (no root install) failed to resolve any
# plugin declared by a nested package's .prettierrc. See
# twistedmelonman/dotfiles#321.
#
# Requires network (npm install of real packages into a scratch dir) and a
# working npx/node. Skips rather than failing when either is unavailable, so
# CI/offline runs don't block on an environment gap unrelated to the fix.
set -uo pipefail
unset CDPATH

REPO_ROOT="$(CDPATH='' cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HOOK="${REPO_ROOT}/git/hooks/lint-prettier.sh"

if ! command -v npx >/dev/null || ! command -v node >/dev/null; then
  echo "SKIP: npx/node not installed"
  exit 0
fi

fail=0

_pass() { echo "  PASS: $1"; }
_fail() {
  echo "  FAIL: $1" >&2
  fail=1
}

TMPROOT="$(mktemp -d)"
trap 'rm -rf "${TMPROOT}"' EXIT

# Fixture: a repo with NO root package.json/node_modules, and one nested
# package whose .prettierrc declares a plugin installed only in that
# package's own node_modules. This is the exact shape from #321
# (beacon-biosignals/platform-datastore).
PKGDIR="${TMPROOT}/pkg/nested"
mkdir -p "${PKGDIR}/src"

cat >"${PKGDIR}/.prettierrc.yaml" <<'EOF'
plugins:
  - prettier-plugin-organize-imports
EOF

cat >"${PKGDIR}/src/sample.ts" <<'EOF'
import { b } from "./b";
import { a } from "./a";
export const x: number = 1;
EOF

if ! (cd "${PKGDIR}" && npm init -y >/dev/null 2>&1 \
  && npm install --no-save prettier prettier-plugin-organize-imports >/dev/null 2>&1); then
  echo "SKIP: could not install prettier + plugin (no network?)"
  exit 0
fi

# ---------------------------------------------------------------------
# Known-bad case first. Running from the repo root — the old hook's
# behavior — must fail to resolve the plugin. If it does not reproduce,
# every assertion below proves nothing.
# ---------------------------------------------------------------------
kb_out="$(cd "${TMPROOT}/pkg" && npx prettier --check nested/src/sample.ts 2>&1)"
kb_rc=$?
if ((kb_rc != 0)) && grep -qi "prettier-plugin-organize-imports" <<<"${kb_out}"; then
  _pass "known-bad reproduces: plugin fails to resolve from the repo root"
else
  _fail "known-bad did NOT reproduce — plugin resolution succeeded from root, so the fix proves nothing"
  echo "${kb_out}" >&2
  exit 1
fi

# ---------------------------------------------------------------------
# Case 1: the hook, invoked from the repo root with the file's repo-relative
# path (exactly how pre-commit invokes it), must run from the nearest
# package.json ancestor and resolve the plugin.
# ---------------------------------------------------------------------
c1_out="$(cd "${TMPROOT}/pkg" && bash "${HOOK}" nested/src/sample.ts 2>&1)"
c1_rc=$?
if ((c1_rc == 0)); then
  _pass "nested package: hook resolves the plugin and formats successfully"
else
  _fail "nested package: hook failed (rc=${c1_rc})"
  echo "${c1_out}" >&2
fi

# ---------------------------------------------------------------------
# Case 2: a file with no package.json ancestor at all must still fall back
# to the previous behavior (format from the given cwd) rather than erroring.
# ---------------------------------------------------------------------
NOPKG="${TMPROOT}/nopkg"
mkdir -p "${NOPKG}"
cat >"${NOPKG}/plain.json" <<'EOF'
{"a":1,   "b":2}
EOF
c2_out="$(cd "${NOPKG}" && bash "${HOOK}" plain.json 2>&1)"
c2_rc=$?
if ((c2_rc == 0)) && grep -q '"a": 1' "${NOPKG}/plain.json"; then
  _pass "no package.json ancestor: falls back to formatting from given path"
else
  _fail "no package.json ancestor: expected fallback formatting to succeed (rc=${c2_rc})"
  echo "${c2_out}" >&2
fi

# ---------------------------------------------------------------------
# Case 3: no files passed. pre-commit still invokes the hook; it must not
# invent a failure.
# ---------------------------------------------------------------------
c3_out="$(cd "${TMPROOT}" && bash "${HOOK}" 2>&1)"
c3_rc=$?
if ((c3_rc == 0)); then
  _pass "no files: exits clean"
else
  _fail "no files: expected exit 0, got ${c3_rc}"
  echo "${c3_out}" >&2
fi

# ---------------------------------------------------------------------
# Case 4: the pre-commit `entry:` itself (not lint-prettier.sh) carries a
# fallback to the pre-fix behavior when the script is not yet deployed —
# symlink repair (install.sh) does not run itself, so a machine that has
# pulled this change but not yet repaired symlinks would otherwise hit
# "No such file" on every commit. Extract the literal entry string from
# config.yaml (rather than hardcoding a copy here, which would drift) and
# run it with HOME pointed at a directory that has no lint-prettier.sh, and
# a stub `npx` on PATH standing in for the real one. The stub, not real
# prettier, proves the OLD codepath ran — not merely that something
# succeeded.
# ---------------------------------------------------------------------
CONFIG_YAML="${REPO_ROOT}/pre-commit/config.yaml"

# Resolve a python interpreter with PyYAML, same approach as
# test-lint-yamllint-config.sh's _yl_python: a bare python3 on PATH often
# lacks PyYAML, but yamllint's own pipx venv always has it.
_yaml_python() {
  command -v yamllint >/dev/null || return 1
  local shebang
  shebang="$(head -1 "$(command -v yamllint)" 2>/dev/null)"
  [[ "${shebang}" == '#!'* ]] || return 1
  shebang="${shebang#\#!}"
  local py="${shebang%% *}"
  "${py}" -c 'import yaml' 2>/dev/null && printf '%s\n' "${py}"
}

YAML_PY="$(_yaml_python)"
if [[ -z "${YAML_PY}" ]]; then
  echo "SKIP: no PyYAML-capable interpreter, cannot extract the entry: string"
  exit 0
fi

ENTRY="$("${YAML_PY}" -c '
import sys, yaml
doc = yaml.safe_load(open(sys.argv[1]))
for repo in doc["repos"]:
    for h in repo.get("hooks", []):
        if h.get("id") == "prettier":
            print(h["entry"])
            sys.exit(0)
sys.exit(1)
' "${CONFIG_YAML}")"

# Strip the "bash -c '...' --" wrapper down to just the -c body, so this
# test exercises the exact fallback logic without re-deriving it.
BODY="${ENTRY#bash -c \'}"
BODY="${BODY%\' --}"

FAKEHOME="${TMPROOT}/fakehome"
FAKEBIN="${TMPROOT}/fakebin"
mkdir -p "${FAKEHOME}/.config/git/hooks" "${FAKEBIN}"
cat >"${FAKEBIN}/npx" <<'EOF'
#!/usr/bin/env bash
echo "STUB_NPX_CALLED: $*"
EOF
chmod +x "${FAKEBIN}/npx"

c4_out="$(HOME="${FAKEHOME}" PATH="${FAKEBIN}:${PATH}" bash -c "${BODY}" -- some/file.ts 2>&1)"
c4_rc=$?
if ((c4_rc == 0)) && grep -q "STUB_NPX_CALLED" <<<"${c4_out}"; then
  _pass "entry fallback: script not installed, falls back to calling prettier directly"
else
  _fail "entry fallback: expected the pre-fix codepath (stub npx) to run, got rc=${c4_rc}"
  echo "${c4_out}" >&2
fi

if ((fail)); then
  echo "FAIL: lint-prettier nested node_modules resolution"
  exit 1
fi
echo "OK: lint-prettier nested node_modules resolution"
