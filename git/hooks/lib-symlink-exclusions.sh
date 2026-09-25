#!/usr/bin/env bash
# git/hooks/lib-symlink-exclusions.sh
#
# Single source of truth for which tracked repo files must NOT be symlinked
# into ~/.config.
#
# ~/.config is where applications look for their configuration. Repo-management
# files (README, LICENSE, CI metadata, build files, tests, agent instructions)
# and copy-and-edit templates are not application config and do not belong
# there, even though they live in this repo.
#
# Sourced by:
#   - install.sh                      — decides which tracked files get a symlink
#   - git/hooks/lib-symlink-repair.sh — decides which symlinks it manages/repairs
#
# These two consumers must agree. When they drifted apart they produced two
# distinct silent failures (smartwatermelon/dotfiles#225):
#   - hook excludes / install.sh does not → install.sh creates a symlink that
#     the repair hook then refuses to manage, so it drifts unnoticed.
#   - install.sh excludes / hook does not → the hook recreates links install.sh
#     deliberately never intended, on every commit.
#
# LOCATION: this file lives beside lib-symlink-repair.sh so both are deployed
# to ~/.config/git/hooks by the same install.sh pass. The pre-commit hook runs
# from the deployed copy (core.hooksPath = ~/.config/git/hooks) and resolves
# this file relative to its own path, so it works without assuming the repo's
# location, the caller's cwd, or the user's shell environment.
#
# Defines: _symlink_is_excluded <path>  → 0 if excluded, 1 otherwise
# Paths are repo-relative, exactly as `git ls-files` emits them.

# Files in the repo that should NOT be symlinked to ~/.config
_symlink_is_excluded() {
  case "$1" in
    # Deployed project templates. These files are copied by post-checkout
    # into every project's scaffolded .claude/, so they are deployed content,
    # not docs about THIS repo — checked ahead of the generic README.md/
    # CLAUDE.md repo-doc rules below, which would otherwise swallow them
    # silently (dotfiles#356: */README.md matched
    # git/template/.claude-template/README.md, so it never deployed).
    git/template/*) return 1 ;;
    # CI / GitHub metadata
    .github/*) return 0 ;;
    # Git ignore files (repo-level, not app configs)
    .gitignore) return 0 ;;
    */.gitignore) return 0 ;;
    # Repo management files
    Brewfile) return 0 ;;
    README.md) return 0 ;;
    */README.md) return 0 ;;
    install.sh) return 0 ;;
    docs/*) return 0 ;;
    # Project metadata that may be added in the future
    LICENSE*) return 0 ;;
    CLAUDE.md) return 0 ;;
    */CLAUDE.md) return 0 ;;
    MEMORY.md) return 0 ;;
    */MEMORY.md) return 0 ;;
    .claude/*) return 0 ;;
    .pre-commit-config.yaml) return 0 ;;
    # Test files
    *.test.*) return 0 ;;
    *.spec.*) return 0 ;;
    *.bats) return 0 ;;
    tests/*) return 0 ;;
    test/*) return 0 ;;
    # Nested test dirs (e.g. bash/tests/). A bash `case` glob does not cross
    # directory levels, so `tests/*` matches only at the repo root — without
    # these, bash/tests/* was symlinked into ~/.config/bash/tests
    # (smartwatermelon/dotfiles#227).
    */tests/*) return 0 ;;
    */test/*) return 0 ;;
    # Copy-and-edit templates — meant to be copied by hand, not symlinked
    *.example) return 0 ;;
    # Project-local hook extension (runs the bash test suite before push).
    # Repo tooling, invoked from the repo by git/hooks/pre-push — not app config.
    .project-hooks/*) return 0 ;;
    # Other repo-level files that may be added
    Makefile) return 0 ;;
    .editorconfig) return 0 ;;
    # Repo-root shellcheck config, read by CI from the repo root. It must NOT
    # reach ~/.config: ~/.shellcheckrc is the stricter interactive config
    # deployed from shellcheck/.shellcheckrc, and symlinking this one would
    # shadow it.
    .shellcheckrc) return 0 ;;
    .gitattributes) return 0 ;;
    CONTRIBUTING.md) return 0 ;;
    CHANGELOG*) return 0 ;;
    *) return 1 ;;
  esac
}
