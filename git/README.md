# Git Configuration

Personal git configuration with custom hooks, optimized diff settings, and modern best practices.

## Overview

This directory contains centralized git configuration that applies to all repositories on this system.

**Location**: `~/.config/git/`
**XDG**: Git automatically uses `~/.config/git/config` per XDG Base Directory spec

## Structure

```
git/
├── config              # Main git configuration
├── gitignore_global    # Global gitignore patterns
├── ignore              # Additional ignore patterns
├── hooks/              # Custom git hooks
│   ├── lint-shell.sh   # Shell script linting with auto-fix
│   ├── lib-symlink-exclusions.sh  # Which repo files are NOT symlinked to ~/.config
│   ├── lib-symlink-repair.sh      # Repairs ~/.config symlinks clobbered by atomic writes
│   ├── pre-commit      # Pre-commit hook (delegates to repo or global)
│   ├── commit-msg      # Commit-msg hook (conventional-commits validation + AI review)
│   ├── post-checkout   # Post-checkout hook (delegates to the template hook)
│   └── pre-push        # Pre-push hook (syncs configs to GitHub repos)
├── template/           # init.templateDir contents
│   ├── .claude-template/  # .claude/ scaffold copied into new repos
│   └── hooks/
│       └── post-checkout  # Canonical .claude/ scaffolder + gitignore policy
└── README.md           # This file
```

## Configuration Highlights

### Diff & Merge Settings

- **Algorithm**: `histogram` - Better rename detection than default Myers algorithm
- **Conflict style**: `zdiff3` - Shows original + both sides + common ancestor
- **Custom prefixes**: `SRC` and `DST` instead of `a/` and `b/` for better readability
- **Color moved**: Highlights moved code blocks in diffs
- **Mnemonic prefixes**: Uses `i/` (index) and `w/` (working tree) prefixes

### Performance Optimizations

- **fsmonitor**: File system monitor for faster status in large repos
- **untrackedCache**: Caches list of untracked files for performance
- **Auto-correct**: Suggests autocorrected commands, runs after two seconds

### Workflow Settings

- **Default branch**: `main` (not `master`)
- **Pull strategy**: Rebase (cleaner history than merge commits)
- **Push behavior**:
  - `autoSetupRemote` - Automatically sets up tracking
  - `followTags` - Pushes annotated tags with commits
- **Fetch behavior**:
  - Prunes stale remote-tracking branches
  - Prunes stale tags
  - Fetches from all remotes (not just origin)

### Rebase Settings

- **autoSquash**: Automatically reorders and marks fixup! commits
- **autoStash**: Stashes uncommitted changes before rebase
- **updateRefs**: Updates branch pointers during rebase

### Conflict Resolution

- **rerere** (reuse recorded resolution): Remembers how you resolved conflicts and auto-applies them if they recur

## Git Hooks

All hooks are configured via `core.hooksPath` to use this directory instead of per-repo `.git/hooks/`.

### pre-commit

**Purpose**: Delegates to repository-local pre-commit framework configuration
**File**: `hooks/pre-commit`

**Behavior**:

1. Checks if repo has `.pre-commit-config.yaml`
2. If yes: Runs `pre-commit run` (repo-specific hooks)
3. If no: Runs global linting (fallback to `lint-shell.sh`)

**Integration**: Works with [pre-commit framework](https://pre-commit.com/) configurations in individual repos

#### Symlink repair

Before linting, the hook sources `hooks/lib-symlink-repair.sh` and runs a
repair pass. Editors and tools that write atomically (write a temp file,
rename it over the target) replace a symlink with a regular file. The pass
walks `git ls-files`, finds `~/.config` entries that are regular files where
a symlink belongs, copies any changed content back into the repo, and
restores the link.

It decides which files it manages using `_symlink_is_excluded()` from
`hooks/lib-symlink-exclusions.sh` — the same list `install.sh` uses to decide
what to symlink in the first place. The two must agree; see
[What does not get symlinked](../README.md#what-does-not-get-symlinked).

`lib-symlink-repair.sh` is sourced from two different places, so it resolves
the exclusion list without assuming the caller's cwd or environment:

1. The sibling of its own fully-resolved path. The hook sources the deployed
   copy at `~/.config/git/hooks/lib-symlink-repair.sh`, which is a symlink
   into the repo; bash reports the symlink in `BASH_SOURCE`, so following it
   is what lands back inside the repo.
2. Its literal sibling directory.
3. `${REPO_DIR}/git/hooks/`.

If none resolve, it fails **closed** — `_symlink_is_excluded()` returns true
for everything, so the repair pass manages nothing rather than touching files
it has no list for.

#### Bypassing pre-existing zizmor findings

The `zizmor` hook (GitHub Actions security lint) checks the whole workflow
file on every run, not just your staged diff. This means a pre-existing
finding elsewhere in the file can block a commit even when your actual
change is unrelated and one line long — awkward in repos with strict
no-drive-by-cleanup norms that forbid bundling unrelated fixes into your
commit.

The supported escape hatch is to skip the hook for that commit:

```bash
SKIP=zizmor git commit
```

Tradeoff: this also skips checking your own newly-staged lines for zizmor
findings. If you want assurance your change didn't introduce a new
finding, run `zizmor <file>` manually against the changed file afterward
and check whether any reported findings' line ranges overlap your diff.

### commit-msg

**Purpose**: Validates Conventional Commits format and runs AI code review — this is the primary AI-review entry point
**File**: `hooks/commit-msg`

**Behavior**:

1. Skips merge commits and WIP/fixup/squash commits (`fixup!`, `squash!`, `wip:`, `WIP:`)
2. Validates the commit message subject against the Conventional Commits pattern: `<type>(<scope>)!?: <description>` (valid types: `feat`, `fix`, `docs`, `style`, `refactor`, `test`, `chore`, `perf`, `ci`, `build`, `revert`; optional scope; trailing `!` marks a breaking change); warns (non-blocking) if the subject exceeds 72 characters
3. If validation passes, runs AI code review via `~/.claude/hooks/run-review.sh` against the staged diff, forwarding the in-progress commit message file so the reviewer sees both the code change and the author's stated intent
4. Blocks the commit if either validation or review fails

**Why here (not pre-commit)**: Git only materializes the commit message on disk by the time `commit-msg` fires — during `pre-commit`, `COMMIT_EDITMSG` still contains the *previous* commit's message (per `man githooks`). Because this hook runs before the commit object exists, `run-review.sh` logs the parent commit hash; `post-commit` later patches the review log with the real commit hash.

**Integration**: Works with `~/.claude/hooks/run-review.sh` (AI code review) and the `post-commit` hook (hash patching)

### pre-push

**Purpose**: Syncs configuration files to GitHub repos before pushing
**File**: `hooks/pre-push`

**Behavior**:

1. Detects if remote is GitHub
2. Checks if `.github/workflows/` exists and uses config files
3. Creates/updates hardlinks from global configs to `.github/workflows/`:
   - `.shellcheckrc` → `${HOME}/.config/shellcheck/.shellcheckrc`
   - `.yamllint` → `${HOME}/.config/yamllint/config`
4. Stages updated configs for inclusion in push
5. Falls back to copying if hardlinks fail (cross-filesystem)

**Why**: Ensures CI workflows use same linting rules as local development

**Also runs AI review**: on non-main branches with a diff against `main`, the hook runs `~/.claude/hooks/run-review.sh` in `--mode=full-diff`. That pass reports its findings to stderr and gates the push on its exit code; it **files no GitHub issues**. `--mode=codebase` used to run here in parallel and was the only thing on the push path that filed issues. It was removed from the push path — see `dev-env/docs/plans/2026-08-26-review-pipeline-redesign-design.md` §1 — because a whole-codebase scan hunts pre-existing defects, which do not appear between pushes. The mode itself remains in `run-review.sh` for weekly and on-demand use. The reviewer lives in claude-config; if `run-review.sh` moves, the docs move with it.

### post-checkout

**Purpose**: Scaffolds `.claude/` infrastructure into newly created repos, and records a tracking policy for what it created
**Files**: `hooks/post-checkout` (thin delegate resolved via `core.hooksPath`) -> `template/hooks/post-checkout` (the canonical hook)

**Behavior**:

1. Exits unless git reports a branch checkout (`$3 == 1`)
2. Exits if `.claude/` already exists
3. Copies `template/.claude-template/` to `.claude/`
4. Records `.claude/` as ignored, subject to the guards below

**Why ignore by default**: the scaffold is generated content the hook can reproduce on demand, and the other common inhabitant of `.claude/` (`settings.local.json`) is machine-local by Claude Code's own `.local.` naming convention. Without a recorded decision, each repo's `.claude/` ended up tracked or ignored by whoever touched it next — a survey of 27 repos found 14 tracking it, 12 ignoring it, and 1 doing neither, all holding byte-identical content (smartwatermelon/dotfiles#220).

**Where the entry goes**:

- **`.gitignore`** normally — the shared, committed policy.
- **`.git/info/exclude`** when `.gitignore` is already tracked. Rewriting a committed `.gitignore` would leave every fresh clone holding a *modified tracked file*, which breaks `git diff --exit-code` checks, `git describe --dirty`, and any `git commit -a` that would sweep the line into an unrelated commit. Writing to `info/exclude` has the same effect on `.claude/`, stays local to that clone, and leaves the tree clean.

**Guards — the hook writes only into a genuinely fresh repo that hasn't already decided**:

- **Fresh clone/init only.** `post-checkout` also fires with `$3 == 1` on `git checkout -b` and on `git worktree add`. Two signals separate those from a real clone or init:
  - `prev_head` (`$1`) is the null SHA on clone and init, but the commit you moved away from on a branch switch — that rules out `git checkout -b`.
  - A *linked worktree* also reports the null SHA, so `prev_head` alone is not enough. A linked worktree's `--git-dir` (`<repo>/.git/worktrees/<name>`) differs from its `--git-common-dir`, whereas a main work tree's two agree. This matters because a new worktree's `.claude/` is absent — the parent repo ignores it, so it never materializes — which means the "does `.claude/` exist" no-op does *not* fire, and without this check the hook would write into an established repo.
- **Already tracked.** If any path under `.claude/` is in the index, the hook writes nothing. `.gitignore` has no effect on already-tracked files, so adding the line would leave the repo claiming a policy it isn't following.
- **Already ignored.** Checked with `git check-ignore -q .claude/`, which consults `.gitignore`, `.git/info/exclude`, and any global `core.excludesFile` in one call. Grepping `.gitignore` alone would miss the `info/exclude` case and promote someone's deliberate private hold to a shared committed policy.
- **Non-regular target.** A `.gitignore` that is a symlink or directory is skipped. `-e` follows symlinks, so a dangling link reports neither `-e` nor `-w`; the hook tests `-L` explicitly rather than walking into a failing write.

**Failure tolerance**: every write is `|| return 0`, and the whole step is called with `|| true`. A `post-checkout` that exits non-zero makes `git clone` itself exit 1 *after* the files have already landed — a far worse outcome than skipping the ignore line. Because this hook is global via `core.hooksPath` and fires on every clone, init, and branch switch on this machine, it does nothing rather than write whenever the state is ambiguous.

**Sharing part of `.claude/`**: negate the specific paths.

```gitignore
.claude/
!.claude/skills/
!.claude/pre-launch.sh
```

**Diagnosing an existing repo**: `git check-ignore -v .claude/` prints the source file and line, which distinguishes a `.gitignore` entry from a `.git/info/exclude` one.

**Tests**: `bash/tests/test-post-checkout-gitignore.sh` drives real `git clone`, `git checkout -b`, and worktree creation through the hook and asserts each guard plus the exit code; `bash/tests/test-post-checkout-hookspath.sh` covers delegate resolution via `core.hooksPath`.

### lint-shell.sh

**Purpose**: Auto-fix shell scripts with shellcheck + shfmt
**File**: `hooks/lint-shell.sh`

**Tools used**:

- **shellcheck**: Static analysis and linting
- **shfmt**: Formatting (2-space indent, case indent, binary ops on left)

**Behavior**:

1. Runs shellcheck in diff mode for each shell file
2. Applies auto-fixes using patch
3. Runs shfmt for formatting
4. Reports summary: ✅ fixed, ❌ remaining issues, 🎉 clean
5. Exits non-zero if unfixable issues remain

**Exclusions**:

- SC2312 globally excluded (command substitution masking exit codes)

**Temporary files**: Creates atomic temp files in same directory, cleaned up via trap

## Ignores

### gitignore_global

System-wide gitignore patterns that apply to all repos:

- OS artifacts (.DS_Store, Thumbs.db)
- Editor files (.vscode/, .idea/, *.swp)
- Common build artifacts

**Path**: Set in `core.excludesfile`

### ignore

Additional local ignore patterns for this config directory.

## Best Practices

### When to Edit

- **User identity** (`user.name`, `user.email`): Set before first commit
- **Aliases**: Add frequently-used command shortcuts under `[alias]`
- **Diff settings**: Customize diff algorithm or color scheme
- **Hooks**: Modify hook behavior or add new hooks

### When NOT to Edit

- **Per-repo settings**: Use repo's `.git/config` for repo-specific settings
- **Credentials**: Use credential helpers, not plain config
- **Experimental settings**: Test in a scratch repo first

## Troubleshooting

### Hooks not running

Check that `core.hooksPath` points to this directory:

```bash
git config --get core.hooksPath
# Should output: ~/.config/git/hooks
```

### Pre-commit hook fails

If pre-commit framework is not installed:

```bash
pipx install pre-commit
```

For repo-specific hooks, run:

```bash
pre-commit install
```

### Shellcheck issues

Install shellcheck and shfmt:

```bash
brew install shellcheck shfmt
```

### Config not applying

Verify config file location:

```bash
git config --list --show-origin | grep config
```

## References

- [Git SCM Documentation](https://git-scm.com/docs/git-config)
- [How Git Core Devs Configure Git](https://blog.gitbutler.com/how-git-core-devs-configure-git/)
- [Pre-commit Framework](https://pre-commit.com/)
- [ShellCheck](https://www.shellcheck.net/)
- [shfmt](https://github.com/mvdan/sh)
