# dotfiles

Unified configuration files. The repo lives at `~/Developer/dotfiles` and `install.sh` creates per-file symlinks into `~/.config/`.

## Structure

```
~/.config/
├── bash/            Shell config (profile, aliases, functions, path, prompt)
├── btop/            System monitor
├── dig/             DNS lookup defaults
├── gh/              GitHub CLI (config.yml only — auth excluded)
├── git/             Git config, global ignore, hooks, templates
├── markdownlint-cli/  Markdown linting rules
├── pre-commit/      Pre-commit framework config
├── s/               s (web search from terminal)
├── shellcheck/      Shell script linting
├── tidy/            HTML tidy
├── vim/             Vim config, plugins, colorscheme
├── yamllint/        YAML linting
├── yt-dlp/          Video downloader defaults
├── Brewfile         Homebrew package manifest
├── install.sh       Idempotent bootstrap script
└── liquidpromptrc   Liquidprompt configuration
```

53 tracked files across 13 directories.

Directories that exist under `~/.config/` but are **not** tracked (managed by their own tools, contain secrets, or are ephemeral): `claude-code/`, `configstore/`, `iterm2/`, `jgit/`, `npm/`, `op/`, `rclone/`, `cagent/`.

## Symlinks

Some tools expect config in `~/` rather than `~/.config/`. These symlinks bridge the gap:

| Symlink | Target |
|---------|--------|
| `~/.bash_profile` | `~/.config/bash/.bash_profile` |
| `~/.digrc` | `~/.config/dig/digrc` |
| `~/.shellcheckrc` | `~/.config/shellcheck/.shellcheckrc` |
| `~/.markdownlint.json` | `~/.config/markdownlint-cli/.markdownlint.json` |

Git, vim, yamllint, btop, gh, and yt-dlp all read from `~/.config/` natively via XDG conventions or built-in support.

### What does not get symlinked

`install.sh` walks `git ls-files` and symlinks each tracked file into
`~/.config/`. Not every tracked file belongs there — `~/.config` is where
applications look for configuration, so repo-management files (README,
LICENSE, CI metadata, `Makefile`, tests, agent instructions) and
copy-and-edit templates (`*.example`) are skipped.

That skip list lives in one place:

**`git/hooks/lib-symlink-exclusions.sh`** — defines `_symlink_is_excluded()`,
a single `case` over repo-relative paths.

Two consumers source it, and they must agree:

| Consumer | Uses the list to decide |
|----------|-------------------------|
| `install.sh` | which tracked files get a symlink |
| `git/hooks/lib-symlink-repair.sh` | which symlinks the pre-commit repair pass manages |

They previously kept separate copies, which drifted by eight patterns
(#225). Disagreement fails silently in both directions: a file the
installer links but the hook ignores drifts unmanaged, and a file the
installer skips but the hook manages gets recreated on every commit.
`bash/tests/test-symlink-exclusions-shared.sh` guards against the
duplication returning.

To stop a newly added file from being symlinked, add its pattern to
`lib-symlink-exclusions.sh` — nowhere else.

## Gitignore strategy

The root `.gitignore` uses a **default-ignore, explicit-allow** pattern:

```gitignore
/*              # Ignore everything by default
!bash/          # Explicitly allow tracked directories
!btop/
...
```

This means new directories added to `~/.config/` are automatically ignored. You must add an `!dirname/` entry to track a new directory. This prevents accidental commits of secrets or tool-generated state.

Additional safety layers:

- **Per-directory `.gitignore` files** in `bash/`, `git/`, `gh/`, etc. handle directory-specific exclusions (e.g., `bash/secrets.sh`, `gh/hosts.yml`)
- **Global exclusion patterns** catch secrets regardless of location: `**/*.key`, `**/*.pem`, `**/secrets.*`, `**/.env`, etc.

## History

### Previous structure (Aug 2025 -- Feb 2026)

Each config directory was its own GitHub repository:

| Repository | Commits | Visibility |
|-----------|---------|------------|
| `bash-config` | 5 | Public |
| `btop-config` | 2 | Private |
| `dig-config` | 2 | Private |
| `git-config` | 62 | Public |
| `markdownlint-config` | 3 | Private |
| `pre-commit-config` | 3 | Private |
| `shellcheck-config` | 4 | Private |
| `tidy-config` | 2 | Private |
| `vim-config` | 7 | Private |
| `yamllint-config` | 2 | Private |
| `yt-dlp-config` | 2 | Private |

This worked but had friction: 11 repos to manage, 11 sets of branches and PRs for what amounts to one machine's configuration. Cross-cutting changes (like updating lint rules that affect multiple configs) required coordinating across repos.

### Consolidation (Feb 2026)

Merged all 11 into this single `dotfiles` repo. Decisions made during the merge:

**History preservation.** `git-config` had 62 meaningful commits spanning 6 months of hook development, security hardening, and template work. Its history was preserved using `git-filter-repo`, rewriting file paths into a `git/` subdirectory. The other 10 repos had 2--7 commits each (initial commit + minor tweaks) — not worth the complexity of preserving, so they got a fresh start.

**PII scrubbing.** The preserved `git-config` history had a personal email in commit metadata (62 commits authored with `andrew.rich@gmail.com`). A mailmap rewrite replaced all instances with the GitHub noreply address. Commit messages referencing private repo names were also redacted.

**Public repo cleanup.** `git-config` and `bash-config` were public repositories. `git-config` had PII in its commit history and references to private repo names. Both were made private before archiving.

**Config fixes during migration.** `dig/digrc` had contradictory options (`+stats` immediately overridden by `+nostats`) and globally-breaking defaults (`+nssearch` and `+norecurse` change `dig`'s fundamental behavior). These were cleaned up during the consolidation. `vim/README.md` had minor markdown formatting issues fixed by the pre-commit linter.

**What didn't change.** No file paths moved. Every tool reads from the exact same `~/.config/<tool>/` path as before. Symlinks are unchanged. Git hooks at `~/.config/git/hooks/` still work. The consolidation was purely a repository structure change.

All 11 original repositories were archived on GitHub after the merge.

## Git hooks

This repo uses global git hooks from `~/.config/git/hooks/`. See `git/README.md` for details on the hook system, which includes:

- **Pre-commit**: Linting (shell, YAML, markdown, HTML, Python), formatting (prettier), and automated code review
- **Pre-push**: Push-target validation (blocks direct pushes to `main`), plus the project-local extension at `.project-hooks/pre-push`, which runs the bash test suite
- **Commit-msg**: Conventional commit format enforcement

## Tests

Regression tests for the shell config and git hooks live in `bash/tests/`:

```bash
# Invoke with an explicit modern bash: a bare `bash` resolves through PATH,
# which on macOS can still find the 3.2 at /bin/bash.
"$(brew --prefix)/bin/bash" bash/tests/run-tests.sh              # whole suite
"$(brew --prefix)/bin/bash" bash/tests/run-tests.sh path-order   # one test, by substring
```

The runner discovers every `bash/tests/test-*.sh` automatically. It runs on
push via `.project-hooks/pre-push` and in CI via `.github/workflows/bash-tests.yml`
(on a macOS runner — the tests assert macOS-specific behavior). Requires
bash 4.4 or newer, which on macOS means a Homebrew bash rather than the 3.2
at `/bin/bash`. See `bash/README.md` for the conventions for adding a test.

## Setup on a new machine

```bash
# Fresh machine (no ~/.config yet):
git clone git@github.com:twistedmelonman/dotfiles.git ~/Developer/dotfiles

# Existing machine (~/.config already has other tool configs):
cd ~/.config
git init
git remote add origin git@github.com:twistedmelonman/dotfiles.git
git fetch origin
git checkout -b main origin/main

# Then bootstrap and activate:
~/Developer/dotfiles/install.sh
source ~/.bash_profile
```

`install.sh` is idempotent — safe to re-run at any time. It creates per-file symlinks from `~/.config/` into the repo using `git ls-files` for discovery. It also handles Homebrew, directories, pipx packages, NVM, and a post-install smoke test. It also generates `~/.config/finicky/finicky.js` from `finicky/finicky.template.js` and the Chrome PWAs installed in `~/Applications/Chrome Apps.localized`, restarting Finicky when the file changes. Use `--dry-run` to preview changes.

Tools that use XDG conventions (`git`, `vim`, `btop`, `yamllint`, `gh`, `yt-dlp`) will find their config automatically.
