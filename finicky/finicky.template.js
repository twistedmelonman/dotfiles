// Finicky configuration TEMPLATE — routes opened URLs to Chrome PWAs.
// Docs: https://github.com/johnste/finicky/wiki/Configuration-(v4)
//
// This file is NOT read by Finicky. finicky/generate-config.sh renders it to
// ~/.config/finicky/finicky.js at install time (install.sh --sync), replacing
// the INSTALLED_PWAS marker line below with the PWAs actually installed on
// this machine. Edit the CATALOG here, never the generated file.
//
// Constraints that shape this file (all verified with Finicky 4.2.2):
//
//   1. Finicky evaluates config in goja, a Go JavaScript engine — not Node.
//      There is no `process` global and no filesystem access, and the
//      bundler cannot import a second file, so the installed-app list has to
//      be substituted into this one file.
//   2. A handler whose app is not installed does NOT fall back to
//      defaultBrowser — the URL is dropped. Handlers are therefore built only
//      for CATALOG entries present in INSTALLED_PWAS.
//   3. Launching a PWA by bundle ID (`open -b com.google.Chrome.app.<id>`)
//      drops the URL: Chrome's app_mode_loader opens the start page. The only
//      launch form that preserves it is Chrome itself with `--app-id=<id>`
//      plus `--app-launch-url-for-shortcuts-menu-item=<url>`. A profile must
//      be given so Finicky adds `-n` and a fresh Chrome process honors the
//      args. Recipe from the Finicky wiki (Configuration ideas), >= 4.2.1.
//   4. Chrome honors that launch URL only inside the PWA's scope. Hostnames
//      in CATALOG must be in scope: gist.github.com is NOT in GitHub's scope
//      and lost the link, so it is left to fall through to Chrome.
//   5. A config that fails to build makes Finicky send every URL to Safari.
//      The generator validates its output with `node --check` before install.
//
// App IDs come from each shim's Info.plist:
//   plutil -extract CrAppModeShortcutID raw -o - \
//     ~/Applications/Chrome\ Apps.localized/<App>.app/Contents/Info.plist
//
// To test a rendered config without opening anything:
//   /Applications/Finicky.app/Contents/MacOS/Finicky -config <file> -dry-run
//   (then `open https://github.com/...` from another shell and read the log)

// Hand-curated: app ID → hostnames to route there. Add an entry per PWA you
// install anywhere; the generator activates only the ones present locally.
// An entry whose app is not installed is dropped, and the generator warns —
// that is the only signal, since Finicky logs nothing when no handler matches.
//
// The generated scan chooses a profile for each installed app. A catalog entry
// can pin `profile` when the same app ID is intentionally installed in more
// than one Chrome profile.
const CATALOG = {
  mjoklplbddabcmpepnokjaffbmgbkkgg: {
    hostnames: ["github.com", "www.github.com"],
    profile: "Default",
  },
};

// Replaced by the generator with the PWAs installed on this machine:
//   { "<appId>": { "name": "<shim name>", "profile": "<Chrome profile dir>" } }
// The profile is the directory name (Default, Profile 4, ...), never the
// account display name, so nothing user-specific is emitted.
const INSTALLED_PWAS = {}; // @@INSTALLED_PWAS@@

/** Builds a browser function that opens `url` inside a Chrome PWA. */
const chromeApp = (appId, profile) => (url) => ({
  name: "Google Chrome",
  profile,
  args: [
    `--app-id=${appId}`,
    `--app-launch-url-for-shortcuts-menu-item=${url.toString()}`,
  ],
});

const handlers = Object.keys(CATALOG)
  .filter((appId) =>
    Object.prototype.hasOwnProperty.call(INSTALLED_PWAS, appId),
  )
  .map((appId) => ({
    match: finicky.matchHostnames(CATALOG[appId].hostnames),
    browser: chromeApp(
      appId,
      CATALOG[appId].profile || INSTALLED_PWAS[appId].profile,
    ),
  }));

export default {
  defaultBrowser: "Google Chrome",

  options: {
    // Finicky logs every opened URL to ~/Library/Logs/Finicky by default,
    // which accumulates a plaintext record of browsing — including alert,
    // ticket and PR links that carry account and incident identifiers.
    // Diagnostics still go to the console, so `Finicky -config <file>` from a
    // terminal remains available when a handler needs debugging.
    logRequests: false,
  },

  // Anything with no matching handler falls through to defaultBrowser.
  handlers,
};
