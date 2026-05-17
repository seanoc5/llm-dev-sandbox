# Git & GitHub: Tips for Swarm Programming

The llm-dev-sandbox is a tool, not a git tutorial — but every swarm session ends with you reviewing and merging pull requests, and that is squarely a git-and-`gh` job. Workers branch from `main`, push to GitHub, open PRs; the coordinator orchestrates them; **you** decide which PRs land and in what order. When a PR can't auto-merge because two workers touched the same lines, the cleanup falls to you.

This doc is a focused crib sheet for that role. It's not a comprehensive git reference — it points to those — and it's not specific to llm-dev-sandbox the codebase. It is specific to the **swarm workflow**: many short-lived PRs, frequent main-branch movement, and a non-zero conflict rate as a steady-state condition rather than a once-a-month anomaly. If your git skills are thin and you're picking up volume in this workflow, start here.

> **Tip:** for the orchestration side of swarm work (spawning workers, watching for outcomes, killing stuck containers), see [`../advanced-usage.md`](../advanced-usage.md). For when something in git breaks weird, see [`../troubleshooting.md`](../troubleshooting.md) — git-specific entries live under "Git & SSH" there.

## Contents

- [When to use this doc](#when-to-use-this-doc)
- [Background: official + recommended reading](#background-official--recommended-reading)
- [Mental model: how the swarm uses git](#mental-model-how-the-swarm-uses-git)
- [The main event: resolving conflicts in a PR](#the-main-event-resolving-conflicts-in-a-pr)
  - [Merge approach (safer, recommended for non-experts)](#merge-approach-safer-recommended-for-non-experts)
  - [Rebase approach (cleaner history, more risk)](#rebase-approach-cleaner-history-more-risk)
  - [Resolving from the GitHub web UI](#resolving-from-the-github-web-ui)
  - [Choosing merge vs. rebase](#choosing-merge-vs-rebase)
- [Cheat sheet: swarm-flavored git/gh](#cheat-sheet-swarm-flavored-gitgh)
- ["Oh shit" recovery recipes](#oh-shit-recovery-recipes)
- [Swarm-specific patterns and gotchas](#swarm-specific-patterns-and-gotchas)
- [Glossary](#glossary)

## When to use this doc

Open this doc when:

- GitHub says "This branch has conflicts that must be resolved" on a PR.
- You merged a PR that broke main and you need to back it out.
- A worker's branch is way behind `main` and you want to catch it up before reviewing.
- You typed something into git, regretted it instantly, and want to know if you can undo.
- You want to understand *why* git just did the thing it did.

Skip this doc when you just want to write code — workers handle that side of git themselves inside their isolated worktrees.

## Background: official + recommended reading

These are the references this doc leans on. When something here is hand-wavy, one of them will go deeper.

| Resource | Best for |
|---|---|
| [git-scm.com/doc](https://git-scm.com/doc) — official git docs | Authoritative reference; man pages |
| [Pro Git book (free)](https://git-scm.com/book) | Chapter-by-chapter book; ch. 2–3 cover everything in this doc |
| [GitHub CLI manual](https://cli.github.com/manual/) | `gh` command reference |
| [GitHub Docs: About merge conflicts](https://docs.github.com/en/pull-requests/collaborating-with-pull-requests/addressing-merge-conflicts/about-merge-conflicts) | Conflict mechanics, web-UI resolver |
| [ohshitgit.com](https://ohshitgit.com/) | "I did the bad thing, how do I undo" — bookmark this |
| [learngitbranching.js.org](https://learngitbranching.js.org/) | Interactive visualizer; build intuition for merge/rebase |
| [git-flight-rules](https://github.com/k88hudson/git-flight-rules) | Question-driven recipes ("how do I...?") |
| [The Pragmatic Engineer: How to write a good commit message](https://cbea.ms/git-commit/) | Commit-message style; swarm uses `[swarm]` prefix |

If you only learn one thing today: **`git reflog` exists, and it remembers basically everything for 90 days, including state you thought you destroyed.** That's your safety net.

## Mental model: how the swarm uses git

A short orientation. If any of this feels new, the Pro Git book ch. 2 covers it well.

- **A git repository** is a collection of *commits* (snapshots) plus *refs* (named pointers — branches, tags, HEAD). Branches are just labels; they're cheap.
- **A *worktree*** is a checkout of one branch into a directory. The swarm pattern uses `git worktree add` to give each worker its own isolated directory and branch, so worker-A can be hacking on `iss-5` while worker-B is on `iss-12`, both backed by the same underlying repo.
- **Remotes** (here: `origin`, pointing at GitHub) are other copies of the repo. `fetch` downloads remote refs; `push` uploads yours; `pull` is `fetch + merge` (and is what trips up beginners — see below).
- **PRs (pull requests)** are GitHub's mechanism for proposing that the commits on one branch be merged into another. The swarm convention is: workers branch from `origin/main`, push `iss-N`, open a PR, you merge.

What the swarm adds on top:

- One worktree per worker, named `wt-issue-N` by convention (path determined by `provision-worker.sh`).
- One branch per worker, `iss-N`. Workers commit with `[swarm]` prefix per `.swarm-policy.md`.
- After PR merge: the worktree should be removed (`git worktree remove`) and the branch deleted both locally and on GitHub.

## The main event: resolving conflicts in a PR

You opened a PR and GitHub says "This branch has conflicts that must be resolved." Here's the playbook.

**Pre-flight, always:**

```bash
git fetch origin                  # get the latest remote state into your local refs
gh pr checkout <PR-number>        # check out the PR branch locally (auto-creates a local tracking branch)
git status                        # confirm you're on the PR branch with a clean tree
```

Now pick an approach.

### Merge approach (safer, recommended for non-experts)

You're going to merge `main` *into* the PR branch. New "merge commit" appears in the PR; reviewers can still see the worker's original commits intact.

```bash
git merge origin/main             # will print conflict messages and abort the merge mid-flight
```

You'll see something like:

```
Auto-merging path/to/file.kt
CONFLICT (content): Merge conflict in path/to/file.kt
Automatic merge failed; fix conflicts and then commit the result.
```

Open the conflicted file(s). Look for conflict markers:

```
<<<<<<< HEAD
your branch's version of this hunk
=======
main's version of this hunk
>>>>>>> origin/main
```

Edit by hand: keep one side, keep the other, or write a new merged version. **Remove all the marker lines** (`<<<<<<<`, `=======`, `>>>>>>>`). Save the file.

```bash
git status                        # shows "Unmerged paths" — every file still listed needs work
git add path/to/file.kt           # mark this file resolved
# ...repeat for each conflicted file...
git status                        # when everything is staged, no unmerged paths remain
git merge --continue              # finalize the merge (drops you into your editor for the merge-commit message — accept the default)
git push                          # push the merge commit; GitHub re-evaluates the PR
```

**If you panic at any point during conflict resolution:** `git merge --abort` returns you to the pre-merge state. No harm done.

### Rebase approach (cleaner history, more risk)

You're going to replay the PR's commits *on top of* the current `main`. The PR appears to have been written against the latest main from the start — no merge commit. You then need to **force-push** because the PR's commits have new hashes.

```bash
git rebase origin/main            # if there are conflicts, rebase pauses on the first conflicting commit
```

For each conflict pause:

```bash
# edit conflicted files as in the merge approach — same conflict markers
git add path/to/file.kt
git rebase --continue             # move to the next commit (or finish if none left)
```

When the rebase completes:

```bash
git push --force-with-lease       # NOT plain --force — see below
```

**`--force-with-lease`** refuses to overwrite the remote if someone else (e.g., another collaborator, or a different machine of yours) pushed to the PR branch since you last fetched. Use it instead of plain `--force` — it's the same convenience for you, but it stops accidents on shared branches. In the solo-laptop swarm case the protection rarely fires, but it's free to have.

**If a rebase goes sideways:** `git rebase --abort` returns you to the pre-rebase state, including the original commits unchanged.

### Resolving from the GitHub web UI

GitHub's web UI has a built-in conflict resolver, accessible via the **Resolve conflicts** button on the PR's conversation tab when conflicts exist. It works for simple cases (a handful of files, single-line edits) and is fine for that. For anything beyond trivial, prefer the local merge/rebase approach — the editor in the web UI is a textarea, no syntax highlighting, no test-running, easy to introduce subtle bugs.

Rule of thumb: if you can finish web-UI resolution in under 30 seconds, do that. Otherwise drop to the terminal.

### Choosing merge vs. rebase

| Situation | Pick |
|---|---|
| You're new to git and want the safe path | Merge |
| You want reviewers to see the worker's original commits unaltered | Merge |
| You want a linear, clean main history | Rebase (then squash-merge — see below) |
| The PR has many small commits and you'd squash-merge anyway | Either; the squash flattens them |
| You're terrified of force-push | Merge |
| You're on a shared branch other people might be pushing to | Merge (rebase + force-push will steamroll their work) |

When you actually merge the PR via `gh pr merge`, you'll also choose **squash**, **rebase**, or **merge** as the *integration strategy*. Most swarm PRs are best squash-merged: one PR becomes one commit on main, message includes the PR title and number, the worker's noisy intermediate commits collapse into a single landing point.

```bash
gh pr merge <PR-number> --squash --delete-branch
```

`--delete-branch` removes both the local tracking branch and the remote branch after merge. Saves cleanup steps.

## Cheat sheet: swarm-flavored git/gh

Tasks you'll do regularly. Each command shown with the form you're most likely to want, not the maximum-flexibility form.

**Inspecting state**

| Goal | Command |
|---|---|
| List open PRs | `gh pr list` |
| List your own open PRs | `gh pr list --author @me` |
| See a PR's details, files, conversation | `gh pr view <N>` |
| See the diff of a PR | `gh pr diff <N>` |
| See what's on the current branch that isn't on main | `git log origin/main..HEAD` |
| See what's on main that isn't on your branch | `git log HEAD..origin/main` |
| See both, side-by-side, as a graph | `git log --left-right --graph --oneline origin/main...HEAD` |
| See uncommitted changes | `git status` (file list) / `git diff` (line-level) |
| See the last 20 commits compactly | `git log --oneline -20` |

**Updating local state**

| Goal | Command |
|---|---|
| Get latest remote refs without changing your working tree | `git fetch origin` |
| Update local main to match remote main | `git switch main && git pull` |
| Check out a PR locally | `gh pr checkout <N>` |
| Update PR branch with latest main (merge) | `git merge origin/main` |
| Update PR branch with latest main (rebase) | `git rebase origin/main` |

**Conflict mid-flight**

| Goal | Command |
|---|---|
| Continue merge after staging resolved files | `git merge --continue` |
| Abandon a merge | `git merge --abort` |
| Continue rebase after staging resolved files | `git rebase --continue` |
| Skip a problematic commit during rebase | `git rebase --skip` |
| Abandon a rebase | `git rebase --abort` |

**Publishing**

| Goal | Command |
|---|---|
| Push current branch to remote | `git push` (or `git push -u origin HEAD` first time) |
| Push after rebase, safely | `git push --force-with-lease` |
| Open a PR for current branch | `gh pr create --fill` (uses commit messages for title/body) |
| Merge a PR with squash and branch cleanup | `gh pr merge <N> --squash --delete-branch` |
| Close a PR without merging | `gh pr close <N>` |
| Reopen a closed PR | `gh pr reopen <N>` |

**Worktrees (swarm-specific)**

| Goal | Command |
|---|---|
| List all worktrees | `git worktree list` |
| Remove a finished worktree | `git worktree remove <path>` |
| Force-remove a worktree (uncommitted changes will be lost) | `git worktree remove --force <path>` |
| Prune stale worktree refs after manual deletion | `git worktree prune` |
| Delete a local branch | `git branch -d <name>` (refuses if unmerged) / `git branch -D <name>` (force) |

## "Oh shit" recovery recipes

Bookmarked from [ohshitgit.com](https://ohshitgit.com/) and adapted for swarm scenarios. The common thread: **`git reflog` is your time machine** — it records every move HEAD made for the last 90 days, even moves you thought you destroyed.

| Situation | Recovery |
|---|---|
| "I committed to the wrong branch" (haven't pushed) | `git reset HEAD~1` (un-commit, keep changes); `git switch correct-branch`; `git commit -am "..."` |
| "I want to undo my last commit" (haven't pushed) | `git reset --soft HEAD~1` (un-commit, keep staged) |
| "I want to undo my last commit" (already pushed) | `git revert HEAD` then `git push` (creates a new commit that undoes the old one — does NOT rewrite history) |
| "I did a destructive thing and lost commits" | `git reflog` to find the hash you want; `git reset --hard <hash>` (only safe if you haven't pushed the bad state) |
| "I'm on a detached HEAD with commits I want to keep" | `git switch -c rescue-branch` (captures current HEAD as a new branch) |
| "I made a bad merge, haven't pushed" | `git reset --hard ORIG_HEAD` (ORIG_HEAD = pre-merge HEAD; auto-set by `git merge`) |
| "I made a bad merge, already pushed" | `git revert -m 1 <merge-commit-hash>` then `git push` (the `-m 1` says "treat first parent as the side to keep") |
| "I want to discard all uncommitted changes in a file" | `git checkout -- path/to/file` (or `git restore path/to/file` in modern git) |
| "I want to discard ALL uncommitted changes everywhere" | `git reset --hard` (**destroys work; only if you're sure**) |
| "I want to throw out my whole branch and start over from main" | `git fetch origin && git reset --hard origin/main` |

**Three habits worth forming:**

1. **Before any `--hard` or `--force` operation, write down the current commit hash.** `git rev-parse HEAD`. Tape it to your screen for two minutes. You can always `git reset --hard <that-hash>` to come back.
2. **`git stash` first if you're unsure.** Saves your uncommitted work to a stack you can pop later: `git stash`, do scary thing, `git stash pop`.
3. **Use `--force-with-lease`, never plain `--force`.** Once muscle memory locks in `--force`, you'll one day overwrite someone else's commits.

## Swarm-specific patterns and gotchas

Things that bite specifically because of how llm-dev-sandbox uses git:

- **One branch per worker, named `iss-N`.** Don't reuse a branch across workers; the coordinator and provision-worker.sh assume a fresh branch per spawn. If you need to retry a worker on the same issue, delete the old branch + worktree first.
- **Workers commit inside isolated worktrees.** Each `wt-issue-N` directory has its own working tree, index, and HEAD, but all of them share the same `.git/objects` store. This means `git log` from any worktree sees commits from every worktree — useful for spotting cross-worker activity, occasionally confusing.
- **`[swarm]` commit prefix.** The `.swarm-policy.md` template tells workers to prefix every commit message with `[swarm]`. If you amend or squash a worker commit, keep the prefix so the convention holds.
- **`.swarm/tasks/` is technically version-controllable but usually shouldn't be.** Most projects gitignore `.swarm/` to keep brief and outcome files out of the repo. If you see merge conflicts in `.swarm/*.json` files, that's almost certainly a gitignore that should be added. Check the project's `.gitignore` before resolving.
- **The coordinator never commits.** All commits are made by workers in their worktrees. If you see uncommitted changes in the *coordinator's* working directory, those are yours (from manual edits) — they're not under the swarm's authority.
- **`gh auth` lives in `~/.config/gh/` on the host and is bind-mounted into worker containers** (see `sandbox.sh`). One auth, everywhere. If `gh` is failing inside a worker but works on the host, the bind mount is the first thing to check.
- **Branch protection on main.** If the project requires PRs to pass CI before merge, `gh pr merge --squash` will refuse until checks are green. Use `gh pr checks <N>` to see what's outstanding. Don't bypass with `--admin` unless you genuinely understand what you're skipping.
- **After-merge cleanup is on you.** GitHub deletes the *remote* branch (with `--delete-branch`), but the local worktree and local branch persist. Cleanup:
  ```bash
  git worktree remove /path/to/wt-issue-N
  git branch -d iss-N
  ```
  If `git branch -d` refuses with "not fully merged", and you're sure the PR landed, double-check with `git log origin/main --oneline | grep iss-N` — if you see the squash commit, you're safe to `git branch -D iss-N`.

## Glossary

| Term | What it means here |
|---|---|
| **branch** | A named, movable pointer to a commit. Cheap; create freely. |
| **commit** | An immutable snapshot of the tree plus metadata (author, message, parent(s)). Identified by SHA hash. |
| **HEAD** | "Where am I right now" — usually points to the branch you're on, sometimes directly to a commit (detached HEAD). |
| **ORIG_HEAD** | Git auto-sets this to the previous HEAD before destructive operations (merge, rebase, reset). Lifeline for undo. |
| **index / staging area** | The "what I'm about to commit" buffer between working tree and history. `git add` puts things in it. |
| **working tree** | The files on disk, including uncommitted changes. |
| **remote** | A pointer to another copy of the repo. `origin` = the default name, usually GitHub. |
| **ref** | A named pointer — branches, tags, HEAD, etc. Lives in `.git/refs/`. |
| **fetch** | Download remote refs and objects. Doesn't change your working tree. |
| **pull** | `fetch` + `merge` (or `rebase` if configured). Convenient, sometimes too convenient. |
| **merge** | Combine two branches by creating a new commit with two parents. Preserves history of both sides. |
| **rebase** | Replay your commits on top of a different base. Rewrites your commits' hashes. |
| **squash** | Combine multiple commits into one. The default integration strategy for swarm PRs. |
| **fast-forward** | When branch A is a direct ancestor of branch B, "merging" B into A is just moving A's pointer forward. No merge commit. |
| **force-push** | Overwrite the remote branch with your local version. Required after rebase. Use `--force-with-lease` for safety. |
| **reflog** | Local-only log of every HEAD move for the last 90 days. Recovery superpower. |
| **worktree** | A separate working directory backed by the same repo. The swarm uses one per worker. |
| **PR (pull request)** | GitHub feature: proposes merging one branch into another, with review + CI. |


## Misc & Random...

```(base) sean@minti9 :.../work/oconeco/fand-poc$ git pull
You are not currently on a branch.
Please specify which branch you want to merge with.
See git-pull(1) for details.

    git pull <remote> <branch>
```

● You're mid-interactive-rebase on feat/issue-182-construct-registry rebasing onto c827d2c (current master). That's why git pull refuses — there's no current branch, you're on a detached HEAD inside the rebase.
  State:
  - All conflicts resolved, changes staged (constructs.py + 10 loaders + test)                                                                                                                                               
  - Rebase is on its last step: pick e1366e8 feat(#182): Construct registry foundation per ADR-0007                                                                                                                          
  - Git is waiting for you to run git rebase --continue to commit the staged result                                                                                                                                          
  Options:                                                                                                                                                                                                                   
  - A. Continue the rebase — git rebase --continue. Applies the staged commit, finishes the rebase, drops you back on feat/issue-182-construct-registry. Then git pull (or git push --force-with-lease if the remote branch  
  exists and diverges) works again.            
  - B. Abort the rebase — git rebase --abort. Throws away all the resolution work and returns to wherever the branch was before the rebase started. Only do this if you've forgotten what you were doing and want a clean    
  slate.                                                                                                                                                                                                                     
  - C. Inspect first — git diff --staged to confirm the staged commit content matches what you expect for #182 before continuing. Recommended if you don't remember exactly where you were.
  Recommend C → A. Sanity-check the staged diff (it's a sizable change — registry foundation + 10 loaders + test), then git rebase --continue to finish.                                                                     
  Note this is the in-progress work I flagged at startup — the coordinator working tree owns #182. Want me to run git diff --staged --stat so you can eyeball the size, then continue?                                       
---

