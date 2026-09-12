#!/usr/bin/env bash
#shellcheck shell=bash
# Standalone verification of finicky/generate-config.sh.
# Run directly: bash bash/tests/test-finicky-generate-config.sh
#
# The generator decides which Chrome PWAs get Finicky handlers. A handler
# for an app that is not installed drops the URL (Finicky has no fallback),
# and a config that fails to build sends every URL to Safari, so both the
# scan and the render are pinned here against fixtures — never against the
# real ~/Applications or Chrome profile directories.
set -euo pipefail
unset CDPATH

REPO_ROOT="$(CDPATH='' cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
GEN="${REPO_ROOT}/finicky/generate-config.sh"

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

TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

# ── Fixture: two PWA shims, one profile layout ──────────────────────────
# GitHub is in Default and Profile 4; Foo is only in Profile 4.
GH_ID="mjoklplbddabcmpepnokjaffbmgbkkgg"
FOO_ID="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
APPS="${TMP}/Chrome Apps.localized"
PROFILES="${TMP}/Chrome"

make_shim() {
  local name="$1" id="$2" url="$3"
  mkdir -p "${APPS}/${name}.app/Contents"
  cat >"${APPS}/${name}.app/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>com.google.Chrome.app.${id}</string>
  <key>CrAppModeShortcutID</key><string>${id}</string>
  <key>CrAppModeShortcutName</key><string>${name}</string>
  <key>CrAppModeShortcutURL</key><string>${url}</string>
</dict></plist>
EOF
}
make_shim "GitHub" "${GH_ID}" "https://github.com/"
make_shim "Foo" "${FOO_ID}" "https://foo.example/"
mkdir -p "${PROFILES}/Default/Web Applications/Manifest Resources/${GH_ID}"
mkdir -p "${PROFILES}/Profile 4/Web Applications/Manifest Resources/${GH_ID}"
mkdir -p "${PROFILES}/Profile 4/Web Applications/Manifest Resources/${FOO_ID}"

#shellcheck source=/dev/null
source "${GEN}"

echo "scan:"
scan="$(finicky_scan_pwas "${APPS}" "${PROFILES}")"
expected_scan="$(printf '%s\tFoo\tProfile 4\n%s\tGitHub\tDefault' "${FOO_ID}" "${GH_ID}")"
check "scan lists both apps sorted by id with preferred profile" "${expected_scan}" "${scan}"

echo "scan with no apps dir:"
check "missing apps dir yields empty scan" "" "$(finicky_scan_pwas "${TMP}/nope" "${PROFILES}")"

echo "scan with app in no profile:"
make_shim "Orphan" "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" "https://orphan.example/"
orphan_line="$(finicky_scan_pwas "${APPS}" "${PROFILES}" 2>/dev/null | grep '^bbbb')"
check "app in no profile falls back to Default" "$(printf 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\tOrphan\tDefault')" "${orphan_line}"
rm -rf "${APPS}/Orphan.app"

echo "render:"
TEMPLATE="${TMP}/finicky.template.js"
cat >"${TEMPLATE}" <<'EOF'
// header
const INSTALLED_PWAS = {}; // @@INSTALLED_PWAS@@
export default { defaultBrowser: "Google Chrome", handlers: [] };
EOF
rendered="$(finicky_render "${TEMPLATE}" "${scan}")"
expected_literal='const INSTALLED_PWAS = {"'"${FOO_ID}"'": {"name": "Foo", "profile": "Profile 4"}, "'"${GH_ID}"'": {"name": "GitHub", "profile": "Default"}};'
check "render replaces marker with sorted literal" "1" "$(grep -cF "${expected_literal}" <<<"${rendered}")"
check "render drops the marker comment" "0" "$(grep -c '@@INSTALLED_PWAS@@' <<<"${rendered}")"
check "render keeps the rest of the template" "1" "$(grep -c '^export default' <<<"${rendered}")"
check "render prepends a GENERATED header on line 1" "1" "$(head -1 <<<"${rendered}" | grep -c 'GENERATED')"

echo "render with empty scan:"
rendered_empty="$(finicky_render "${TEMPLATE}" "")"
check "empty scan renders an empty object" "1" "$(grep -cF 'const INSTALLED_PWAS = {};' <<<"${rendered_empty}")"

echo "render without marker:"
printf '// no marker\nexport default {};\n' >"${TMP}/bad.js"
if finicky_render "${TMP}/bad.js" "${scan}" >/dev/null 2>&1; then
  check "missing marker fails" "nonzero" "0"
else
  check "missing marker fails" "nonzero" "nonzero"
fi

echo "render with duplicate marker:"
{
  cat "${TEMPLATE}"
  echo 'const INSTALLED_PWAS = {}; // @@INSTALLED_PWAS@@'
} >"${TMP}/dup.js"
if finicky_render "${TMP}/dup.js" "${scan}" >/dev/null 2>&1; then
  check "duplicate marker fails" "nonzero" "0"
else
  check "duplicate marker fails" "nonzero" "nonzero"
fi

echo "render with trailing-space marker:"
printf '// header\nconst INSTALLED_PWAS = {}; // @@INSTALLED_PWAS@@ \nexport default {};\n' >"${TMP}/trailing-space.js"
if finicky_render "${TMP}/trailing-space.js" "${scan}" >"${TMP}/ts.out" 2>"${TMP}/ts.err"; then
  check "trailing-space marker fails" "nonzero" "0"
else
  check "trailing-space marker fails" "nonzero" "nonzero"
fi
check "trailing-space marker error mentions marker" "1" "$(grep -c 'marker' "${TMP}/ts.err")"

echo "render with marker embedded in a longer line:"
printf '// header\n//   const INSTALLED_PWAS = {}; // @@INSTALLED_PWAS@@ (old)\nexport default {};\n' >"${TMP}/embedded.js"
if finicky_render "${TMP}/embedded.js" "${scan}" >"${TMP}/em.out" 2>"${TMP}/em.err"; then
  check "embedded marker fails" "nonzero" "0"
else
  check "embedded marker fails" "nonzero" "nonzero"
fi
check "embedded marker error mentions marker" "1" "$(grep -c 'marker' "${TMP}/em.err")"

echo "real template:"
REAL_TEMPLATE="${REPO_ROOT}/finicky/finicky.template.js"
check "real template has exactly one marker" "1" "$(grep -cF 'const INSTALLED_PWAS = {}; // @@INSTALLED_PWAS@@' "${REAL_TEMPLATE}" 2>/dev/null || echo 0)"
check "real template catalogs GitHub" "1" "$(grep -c 'mjoklplbddabcmpepnokjaffbmgbkkgg' "${REAL_TEMPLATE}" 2>/dev/null || echo 0)"
real_rendered="$(finicky_render "${REAL_TEMPLATE}" "${scan}")"
check "real template renders with fixture scan" "2" "$(grep -cF "${GH_ID}" <<<"${real_rendered}")"
if command -v node >/dev/null 2>&1; then
  printf '%s\n' "${real_rendered}" >"${TMP}/rendered.mjs"
  if node --check "${TMP}/rendered.mjs" 2>"${TMP}/node.err"; then
    check "rendered real template passes node --check" "ok" "ok"
  else
    check "rendered real template passes node --check" "ok" "$(head -3 "${TMP}/node.err")"
  fi
  printf '%s\n' "$(finicky_render "${REAL_TEMPLATE}" "")" >"${TMP}/rendered-empty.mjs"
  if node --check "${TMP}/rendered-empty.mjs" 2>"${TMP}/node2.err"; then
    check "rendered real template with no PWAs passes node --check" "ok" "ok"
  else
    check "rendered real template with no PWAs passes node --check" "ok" "$(head -3 "${TMP}/node2.err")"
  fi
else
  echo "  SKIP: node not on PATH, syntax check not run"
fi

echo "catalog:"
# A CATALOG entry whose app is not installed loses its handler silently: the
# template's filter drops it and links fall through to a plain browser tab
# with no diagnostic anywhere. The generator warns instead.
check "real template has exactly one CATALOG block" "1" "$(grep -c '^const CATALOG = {' "${REAL_TEMPLATE}")"
check "catalog ids on real template lists only GitHub" "${GH_ID}" "$(finicky_catalog_ids "${REAL_TEMPLATE}")"

CAT_TEMPLATE="${TMP}/catalog.template.js"
PHANTOM_ID="cccccccccccccccccccccccccccccccc"
COMMENTED_ID="dddddddddddddddddddddddddddddddd"
cat >"${CAT_TEMPLATE}" <<EOF
// header
const CATALOG = {
  ${GH_ID}: { hostnames: ["github.com"] },
  ${PHANTOM_ID}: { hostnames: ["phantom.example"] },
  // ${COMMENTED_ID}: { hostnames: ["retired.example"] },
};
const INSTALLED_PWAS = {}; // @@INSTALLED_PWAS@@
export default { defaultBrowser: "Google Chrome", handlers: [] };
EOF
check "catalog ids skips commented-out entries" "$(printf '%s\n%s' "${GH_ID}" "${PHANTOM_ID}")" "$(finicky_catalog_ids "${CAT_TEMPLATE}")"

run_catalog_gen() {
  FINICKY_TEMPLATE="${CAT_TEMPLATE}" FINICKY_OUTPUT="${TMP}/catalog-out.js" \
    CHROME_APPS_DIR="${APPS}" CHROME_PROFILE_ROOT="${PROFILES}" \
    FINICKY_RESTART_CMD="true" \
    bash "${GEN}" "$@"
}
run_catalog_gen >"${TMP}/cat1.out" 2>&1 || {
  echo "  FAIL: catalog run exited non-zero"
  cat "${TMP}/cat1.out"
  fail=1
}
check "warns about the uninstalled CATALOG entry" "1" "$(grep -c "CATALOG entry ${PHANTOM_ID} has no installed PWA" "${TMP}/cat1.out")"
check "does not warn about the installed entry" "0" "$(grep -c "CATALOG entry ${GH_ID} has no installed" "${TMP}/cat1.out")"
check "does not warn about the commented-out entry" "0" "$(grep -c "${COMMENTED_ID}" "${TMP}/cat1.out")"
check "reports catalog entry and active handler counts" "1" "$(grep -c 'CATALOG entries: 2, active handlers: 1' "${TMP}/cat1.out")"

run_catalog_gen --dry-run >"${TMP}/cat2.out" 2>&1 || {
  echo "  FAIL: catalog dry-run exited non-zero"
  fail=1
}
check "dry-run still warns about the uninstalled entry" "1" "$(grep -c "CATALOG entry ${PHANTOM_ID} has no installed PWA" "${TMP}/cat2.out")"

echo "catalog: template without a CATALOG block:"
# The other fixtures in this file have no CATALOG block at all. A missing
# block must not be fatal — it only means there is nothing to cross-check.
nocat_exit=0
FINICKY_TEMPLATE="${TEMPLATE}" FINICKY_OUTPUT="${TMP}/nocat-out.js" \
  CHROME_APPS_DIR="${APPS}" CHROME_PROFILE_ROOT="${PROFILES}" \
  FINICKY_RESTART_CMD="true" \
  bash "${GEN}" >"${TMP}/cat3.out" 2>&1 || nocat_exit=$?
check "missing CATALOG block still exits 0" "0" "${nocat_exit}"
check "missing CATALOG block still installs" "1" "$(grep -c 'installed:' "${TMP}/cat3.out")"

echo "install:"
OUT_DIR="${TMP}/out"
mkdir -p "${OUT_DIR}"
OUT="${OUT_DIR}/finicky.js"
SENTINEL="${TMP}/restarted"
run_gen() {
  FINICKY_TEMPLATE="${TEMPLATE}" FINICKY_OUTPUT="${OUT}" \
    CHROME_APPS_DIR="${APPS}" CHROME_PROFILE_ROOT="${PROFILES}" \
    FINICKY_RESTART_CMD="touch ${SENTINEL}" \
    bash "${GEN}" "$@"
}

ln -s "${TMP}/does-not-exist" "${OUT}"
run_gen >"${TMP}/run1.out" 2>&1 || {
  echo "  FAIL: first run exited non-zero"
  cat "${TMP}/run1.out"
  fail=1
}
check "dangling symlink replaced by a regular file" "regular" "$([[ -f "${OUT}" && ! -L "${OUT}" ]] && echo regular || echo other)"
check "installed file carries the literal" "1" "$(grep -cF "${GH_ID}" "${OUT}")"
check "first install reports installed" "1" "$(grep -c 'installed:' "${TMP}/run1.out")"
check "first install runs the restart command" "yes" "$([[ -f "${SENTINEL}" ]] && echo yes || echo no)"

rm -f "${SENTINEL}"
run_gen >"${TMP}/run2.out" 2>&1 || {
  echo "  FAIL: second run exited non-zero"
  fail=1
}
check "second run reports unchanged" "1" "$(grep -c 'unchanged:' "${TMP}/run2.out")"
check "second run does not restart" "no" "$([[ -f "${SENTINEL}" ]] && echo yes || echo no)"

echo "dry-run:"
rm -rf "${APPS}/Foo.app"
run_gen --dry-run >"${TMP}/run3.out" 2>&1 || {
  echo "  FAIL: dry-run exited non-zero"
  fail=1
}
check "dry-run reports would install" "1" "$(grep -c 'would install:' "${TMP}/run3.out")"
check "dry-run leaves the file alone" "1" "$(grep -cF "${FOO_ID}" "${OUT}")"
check "dry-run does not restart" "no" "$([[ -f "${SENTINEL}" ]] && echo yes || echo no)"

echo "restart command failure:"
# Foo.app is still removed from the dry-run case above; re-adding it alone
# would render byte-identical to run1's output and hit the "unchanged"
# early-return before restart is ever invoked. Also touch the template's
# trailing comment so the render actually differs from what's on disk.
make_shim "Foo" "${FOO_ID}" "https://foo.example/"
TEMPLATE2="${TMP}/finicky.template2.js"
cat "${TEMPLATE}" >"${TEMPLATE2}"
echo '// force a content change for the restart-failure test' >>"${TEMPLATE2}"
gen_exit=0
FINICKY_TEMPLATE="${TEMPLATE2}" FINICKY_OUTPUT="${OUT}" \
  CHROME_APPS_DIR="${APPS}" CHROME_PROFILE_ROOT="${PROFILES}" \
  FINICKY_RESTART_CMD="false" \
  bash "${GEN}" >"${TMP}/run4.out" 2>&1 || gen_exit=$?
check "failing restart command still exits 0" "0" "${gen_exit}"
check "failing restart command still reports installed" "1" "$(grep -c 'installed:' "${TMP}/run4.out")"
check "failing restart command is warned about" "1" "$(grep -c 'restart command failed' "${TMP}/run4.out")"

echo "validation:"
printf '// GENERATED header stays\nconst INSTALLED_PWAS = {}; // @@INSTALLED_PWAS@@\nexport default { this is not javascript };\n' >"${TMP}/broken.template.js"
if command -v node >/dev/null 2>&1; then
  if FINICKY_TEMPLATE="${TMP}/broken.template.js" FINICKY_OUTPUT="${OUT}" CHROME_APPS_DIR="${APPS}" CHROME_PROFILE_ROOT="${PROFILES}" FINICKY_RESTART_CMD="touch ${SENTINEL}" bash "${GEN}" >/dev/null 2>&1; then
    check "invalid render is rejected" "nonzero" "0"
  else
    check "invalid render is rejected" "nonzero" "nonzero"
  fi
  check "invalid render leaves existing file intact" "1" "$(grep -cF "${FOO_ID}" "${OUT}")"
else
  echo "  SKIP: node not on PATH, validation test not run"
fi

echo "temp file cleanup:"
if command -v node >/dev/null 2>&1; then
  TMPDIR_TEST="$(mktemp -d)"
  FINICKY_TEMPLATE="${TEMPLATE}" FINICKY_OUTPUT="${OUT}" \
    CHROME_APPS_DIR="${APPS}" CHROME_PROFILE_ROOT="${PROFILES}" \
    FINICKY_RESTART_CMD="true" \
    TMPDIR="${TMPDIR_TEST}" \
    bash "${GEN}" >/dev/null 2>&1 || true
  check "no finicky-check temp files remain" "0" "$(find "${TMPDIR_TEST}" -name 'finicky-check.*' | wc -l | tr -d ' ')"
  rm -rf "${TMPDIR_TEST}"
else
  echo "  SKIP: node not on PATH, temp file cleanup test not run"
fi

echo "install.sh wiring:"
check "install.sh calls the generator" "2" "$(grep -cE 'bash "\$\{REPO_DIR\}/finicky/generate-config\.sh"' "${REPO_ROOT}/install.sh")"

exit "${fail}"
