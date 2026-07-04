#!/usr/bin/env bash
# Hermetic smoke tests for treehouse. Temp repo + temp TREEHOUSE_ROOT; never touches
# a real pool. TMUX is unset so no windows are created or renamed.
set -uo pipefail
TH="$(cd "$(dirname "$0")/.." >/dev/null 2>&1 && pwd -P)/treehouse.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export TREEHOUSE_ROOT="$TMP/pool"
unset TMUX 2>/dev/null || true

FAIL=0
fail() { echo "FAIL $1"; FAIL=1; }

REPO="$TMP/repo"
mkdir -p "$REPO"
cd "$REPO" || exit 1
git init -q
git -c user.email=t@t -c user.name=t commit -q --allow-empty -m base
git branch -M main

# 1. spin creates N pooled worktrees on th/ branches
bash "$TH" spin 2 >/dev/null 2>&1 || fail "spin exit"
[ -d "$TREEHOUSE_ROOT/repo/wt-1" ] || fail "wt-1 missing"
[ -d "$TREEHOUSE_ROOT/repo/wt-2" ] || fail "wt-2 missing"
git show-ref --verify --quiet refs/heads/th/wt-1 || fail "branch th/wt-1 missing"

# 2. glance counts the main worktree + 2 pooled
out=$(bash "$TH" glance) || fail "glance exit"
printf '%s' "$out" | grep -q "3 worktrees" || fail "glance count: $out"

# 3. re-spin skips existing worktrees instead of erroring
out=$(bash "$TH" spin 1) || fail "respin exit"
printf '%s' "$out" | grep -q "skip wt-1" || fail "respin should skip existing: $out"

# 4. ls lists the pool
bash "$TH" ls | grep -q "wt-2" || fail "ls missing wt-2"

# 5. sweep dry-run: clean+merged worktrees are listed as DROP, nothing removed
out=$(bash "$TH" sweep) || fail "sweep exit"
printf '%s' "$out" | grep -q "DROP  wt-1" || fail "dry-run should DROP wt-1: $out"
[ -d "$TREEHOUSE_ROOT/repo/wt-1" ] || fail "dry-run removed wt-1!"

# 6. --force removes clean+merged but KEEPS dirty, always
echo x > "$TREEHOUSE_ROOT/repo/wt-2/f.txt"
out=$(bash "$TH" sweep --force) || fail "sweep force exit"
printf '%s' "$out" | grep -q "KEEP  wt-2 (dirty)" || fail "dirty wt-2 not kept: $out"
[ -d "$TREEHOUSE_ROOT/repo/wt-2" ] || fail "force removed dirty wt-2!"
[ ! -d "$TREEHOUSE_ROOT/repo/wt-1" ] || fail "force did not remove clean wt-1"

# 7. unmerged work is KEPT even when clean
rm "$TREEHOUSE_ROOT/repo/wt-2/f.txt"
git -C "$TREEHOUSE_ROOT/repo/wt-2" -c user.email=t@t -c user.name=t commit -q --allow-empty -m ahead
out=$(bash "$TH" sweep --force) || fail "sweep unmerged exit"
printf '%s' "$out" | grep -q "KEEP  wt-2 (unmerged)" || fail "unmerged wt-2 not kept: $out"
[ -d "$TREEHOUSE_ROOT/repo/wt-2" ] || fail "force removed unmerged wt-2!"

[ "$FAIL" = "0" ] && echo "PASS test_treehouse" || { echo "SOME treehouse CASES FAILED"; exit 1; }
