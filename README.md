# treehouse 🌳

Git worktree **pool** manager with an at-a-glance fleet surface. Run many parallel tasks — coding agents, builds, experiments — each in its own worktree, and see the whole pool's status on one screen without context-switching.

Single-file bash, no dependencies beyond `git` (tmux optional).

## Why

`git worktree` is the right primitive for parallel work, but managing ten of them by hand is where it breaks down: creating them one at a time, losing track of which are dirty, and the graveyard of stale worktrees nobody dares delete. treehouse adds the three missing verbs: **bulk spin**, **glance**, and a **safe sweep** that never deletes blind.

## Install

```sh
git clone https://github.com/LucasCooperBey/treehouse
ln -s "$PWD/treehouse/treehouse.sh" ~/.local/bin/treehouse
```

Pooled worktrees live under `~/.treehouse/<repo>/` (override with `$TREEHOUSE_ROOT`).

## Subcommands

### `treehouse spin N [prefix] [base]`

Create N pooled worktrees. Each gets a branch `th/<prefix>-N` checked out from `base` (default: `HEAD`). Skips any that already exist. Inside tmux, opens a new window per worktree. Runs `glance` when done.

```
treehouse spin 3            # creates th/wt-1, th/wt-2, th/wt-3
treehouse spin 2 feat main  # creates th/feat-1, th/feat-2 from main
```

### `treehouse glance`

One-screen status table of every worktree: path, branch, dirty flag, ahead/behind upstream. Pool worktrees are prefixed with 🌳. Inside tmux, renames the current window to `🌳<N>wt[·<D>d]` so the fleet status lives in your status bar.

### `treehouse sweep [--force]`

List (or remove) pooled worktrees that are **clean and fully merged** into `main`/`master`. Dry-run by default — prints `DROP` lines without touching anything. Pass `--force` to actually remove them.

Safety properties, in order: it only ever looks inside the pool directory (never arbitrary worktrees), it keeps anything dirty, it keeps anything unmerged, and it lists before removing. Deleting work requires both the tool's consent and yours.

### `treehouse ls`

List pooled worktrees for the current repo.

## Example

In a repo on `main`, make two pooled worktrees, look at the pool, and ask what is safe to drop:

```sh
treehouse spin 2
treehouse sweep
```

`spin` creates the branches and prints the status table:

```
spun  wt-1  ->  ~/.treehouse/demo/wt-1   (th/wt-1)
spun  wt-2  ->  ~/.treehouse/demo/wt-2   (th/wt-2)

WORKTREE      BRANCH     DIRTY  AHEAD/BEHIND
demo          main       no     -
              th/wt-1    no     -
              th/wt-2    no     -

treehouse: 3 worktrees, 0 dirty.
```

After an edit in `wt-1`, `sweep` keeps the dirty worktree and only lists the clean, merged one. Nothing is removed until you add `--force`:

```
  KEEP  wt-1 (dirty)
  DROP  wt-2 (clean+merged)  <- would remove

treehouse: dry-run. 1 kept. Re-run with --force to remove the DROP entries.
```

## Tests

```sh
test/test_treehouse.sh   # hermetic: temp repo + temp pool, no tmux
```

## Related

- [review-gate](https://github.com/LucasCooperBey/review-gate) — fresh-context adversarial review for the pushes coming out of those worktrees
- [harness-guard](https://github.com/LucasCooperBey/harness-guard) — drop-in safety hooks for agent sessions

## License

MIT
