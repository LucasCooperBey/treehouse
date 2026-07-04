#!/usr/bin/env bash
# treehouse -- git worktree POOL manager with an at-a-glance fleet surface.
# Run many parallel tasks (agents, builds, experiments) each in its own worktree,
# and see the whole pool's status without context-switching.
#
#   treehouse spin N [prefix] [base]   create N pooled worktrees (+ a tmux window each)
#   treehouse glance                   one-screen status of every worktree in this repo
#   treehouse sweep [--force]          remove pooled worktrees that are CLEAN + MERGED
#                                      (dry-run/list by default; --force actually removes)
#   treehouse ls                       list pooled worktrees for this repo
#
# Pooled worktrees live under TREEHOUSE_ROOT (default ~/.treehouse/<repo>). sweep ONLY
# ever touches that pool, only clean+merged ones, and lists before removing -- it never
# bulk-deletes blind. Inside tmux, spin opens a window per worktree and glance writes
# the pool status into the window title.
set -euo pipefail

TH_ROOT="${TREEHOUSE_ROOT:-$HOME/.treehouse}"

die() { echo "treehouse: $*" >&2; exit 1; }
in_repo() { git rev-parse --is-inside-work-tree >/dev/null 2>&1 || die "not in a git repo"; }
repo_name() { basename "$(git rev-parse --show-toplevel)"; }
pool_dir() { echo "$TH_ROOT/$(repo_name)"; }

# Canonicalize a directory path (resolve symlinks) so pool-membership checks match
# git's porcelain output, which reports REAL paths. Without this, a pool under a
# symlinked root (e.g. macOS /var -> /private/var) makes sweep/glance miss the pool.
# Degrades LOUDLY: if the dir exists but can't be entered, pool matching will miss
# real-path worktrees, so say so instead of quietly reporting an empty pool.
_realdir() {
  if [ -d "$1" ]; then
    (cd "$1" 2>/dev/null && pwd -P) || {
      echo "treehouse: WARN cannot resolve '$1' -- pool matching may miss worktrees" >&2
      echo "$1"
    }
  else
    echo "$1"
  fi
}
pool_dir_real() { _realdir "$(pool_dir)"; }

# Per-worktree status helpers (operate on an arbitrary worktree path).
_dirty() { [ -n "$(git -C "$1" status --porcelain 2>/dev/null)" ] && echo yes || echo no; }
_branch() { git -C "$1" symbolic-ref --short HEAD 2>/dev/null || echo "(detached)"; }
_aheadbehind() {
  local up; up=$(git -C "$1" rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null) || { echo "-"; return; }
  local lr; lr=$(git -C "$1" rev-list --left-right --count "${up}...HEAD" 2>/dev/null) || { echo "-"; return; }
  # lr = "<behind>\t<ahead>"
  echo "+$(echo "$lr" | awk '{print $2}')/-$(echo "$lr" | awk '{print $1}')"
}

# Iterate worktree paths from porcelain output (robust to spaces in paths).
_worktree_paths() {
  git worktree list --porcelain | awk '/^worktree /{print substr($0,10)}'
}

cmd_glance() {
  in_repo
  local n=0 dirty=0 pool; pool="$(pool_dir_real)"
  printf "%-34s %-22s %-6s %s\n" "WORKTREE" "BRANCH" "DIRTY" "AHEAD/BEHIND"
  printf "%-34s %-22s %-6s %s\n" "--------" "------" "-----" "------------"
  while IFS= read -r wt; do
    [ -z "$wt" ] && continue
    n=$((n + 1))
    local d; d=$(_dirty "$wt"); [ "$d" = yes ] && dirty=$((dirty + 1))
    local label="$wt"
    case "$wt" in "$pool"/*) label="🌳 ${wt#"$pool"/}" ;; esac
    printf "%-34s %-22s %-6s %s\n" "${label: -34}" "$(_branch "$wt")" "$d" "$(_aheadbehind "$wt")"
  done < <(_worktree_paths)
  echo
  echo "treehouse: $n worktrees, $dirty dirty."
  if [ -n "${TMUX:-}" ]; then
    local title="🌳${n}wt"; [ "$dirty" -gt 0 ] && title="$title·${dirty}d"
    tmux rename-window "$title" 2>/dev/null || true
  fi
}

cmd_ls() {
  in_repo
  local pool; pool="$(pool_dir_real)"
  [ -d "$pool" ] || { echo "treehouse: no pool yet for $(repo_name)"; return 0; }
  # Filter porcelain (real) paths against the real pool — plain `git worktree list`
  # may print paths as originally given, which breaks under symlinked roots.
  local wt found=0
  while IFS= read -r wt; do
    case "$wt" in "$pool"/*) echo "$wt  ($(_branch "$wt"))"; found=1 ;; esac
  done < <(_worktree_paths)
  [ "$found" = 1 ] || echo "treehouse: pool empty for $(repo_name)"
}

cmd_spin() {
  in_repo
  local n="${1:-}"; [ -n "$n" ] || die "usage: treehouse spin N [prefix] [base]"
  case "$n" in ''|*[!0-9]*) die "N must be a positive integer";; esac
  local prefix="${2:-wt}" base="${3:-HEAD}" pool; pool="$(pool_dir)"
  mkdir -p "$pool"
  # Canonicalize AFTER mkdir so spin creates + prints the same real paths that
  # glance/ls/sweep will later match against git's porcelain output.
  pool="$(_realdir "$pool")"
  local i name path branch
  for i in $(seq 1 "$n"); do
    name="${prefix}-${i}"; path="$pool/$name"; branch="th/${name}"
    if [ -e "$path" ]; then echo "skip $name (exists)"; continue; fi
    if git show-ref --verify --quiet "refs/heads/$branch"; then
      git worktree add "$path" "$branch" >/dev/null
    else
      git worktree add -b "$branch" "$path" "$base" >/dev/null
    fi
    echo "spun  $name  ->  $path   ($branch)"
    [ -n "${TMUX:-}" ] && tmux new-window -d -n "🌳$name" -c "$path" 2>/dev/null || true
  done
  echo
  cmd_glance
}

cmd_sweep() {
  in_repo
  local force=0; [ "${1:-}" = "--force" ] && force=1
  local pool; pool="$(pool_dir_real)"
  [ -d "$pool" ] || { echo "treehouse: nothing to sweep (no pool)"; return 0; }
  # A candidate is a pooled worktree that is CLEAN and whose branch is fully merged
  # into the default branch (main/master) -- safe to drop.
  local mainref="main"; git show-ref --verify --quiet refs/heads/main || mainref="master"
  local removed=0 kept=0 wt name d merged
  echo "treehouse sweep (pool: $pool, merged-into: $mainref)"
  while IFS= read -r wt; do
    case "$wt" in "$pool"/*) ;; *) continue ;; esac   # pool only, never arbitrary worktrees
    name="${wt#"$pool"/}"; d=$(_dirty "$wt")
    if [ "$d" = yes ]; then echo "  KEEP  $name (dirty)"; kept=$((kept + 1)); continue; fi
    merged=no
    local sha; sha=$(git -C "$wt" rev-parse HEAD 2>/dev/null)
    if [ -n "$sha" ] && git merge-base --is-ancestor "$sha" "$mainref" 2>/dev/null; then merged=yes; fi
    if [ "$merged" != yes ]; then echo "  KEEP  $name (unmerged)"; kept=$((kept + 1)); continue; fi
    if [ "$force" = 1 ]; then
      git worktree remove "$wt" --force >/dev/null 2>&1 && echo "  GONE  $name" && removed=$((removed + 1))
    else
      echo "  DROP  $name (clean+merged)  <- would remove"
    fi
  done < <(_worktree_paths)
  echo
  if [ "$force" = 1 ]; then
    echo "treehouse: removed $removed, kept $kept. (run 'git worktree prune' if needed)"
  else
    echo "treehouse: dry-run. $kept kept. Re-run with --force to remove the DROP entries."
  fi
}

main() {
  local sub="${1:-glance}"; shift || true
  case "$sub" in
    glance) cmd_glance "$@" ;;
    ls)     cmd_ls "$@" ;;
    spin)   cmd_spin "$@" ;;
    sweep)  cmd_sweep "$@" ;;
    -h|--help|help)
      grep -E '^#( |$)' "$0" | sed 's/^# \{0,1\}//' | head -14 ;;
    *) die "unknown subcommand '$sub' (try: glance|spin|sweep|ls|help)" ;;
  esac
}
main "$@"
