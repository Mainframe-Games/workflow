# Mainframe Workflow

The development workflow for Mainframe Games projects: how work is sized, proposed, planned, decided and shipped. It is plain Markdown that a person or an agent can follow, thin skills that point at that Markdown, and one check script for CI. The check is the only enforcement.

**Agent support:** only Claude Code is tested. The Markdown is agent-neutral and `AGENTS.md` is the common entry point, but other agents are untested.

## The steps

Read [workflow/README.md](workflow/README.md) first. It holds the size table and the ground rules.

| Step | Page | Skill | When |
|---|---|---|---|
| Start | [start.md](workflow/start.md) | `mf-start` | Every piece of work begins here |
| Propose | [propose.md](workflow/propose.md) | `mf-propose` | Large work |
| Plan | [plan.md](workflow/plan.md) | `mf-plan` | Medium and large work |
| Decide | [decide.md](workflow/decide.md) | `mf-decide` | A reader in six months would ask why |
| Ship | [ship.md](workflow/ship.md) | `mf-ship` | Every piece of work ends here |
| Engine bug | [engine-bug.md](workflow/engine-bug.md) | `mf-engine-bug` | A game hits a bug in the engine |

## Add it to a project

Clone this repo at a tag, somewhere outside the project:

```bash
git clone --depth 1 --branch v1.0.0 https://github.com/Mainframe-Games/workflow.git
```

Run sync against the project:

```bash
bash workflow/scripts/sync.sh path/to/project
```

`--agents agents`, `--agents claude` or `--agents agents,claude` (the default) chooses where skills go.

Then, in the project:

1. Commit what sync wrote.
2. Fill in `.agents/workflow.md`: paths, gates and shipping rules.
3. If `AGENTS.md` already existed, add the line sync printed. If the project has a `CLAUDE.md`, add the same line there; sync never touches it.
4. Turn on automatic branch deletion: run `gh repo edit --delete-branch-on-merge` from the project.
5. Add the check to CI. It needs history to find the merge base:

```yaml
on: pull_request
jobs:
  workflow:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v5
        with:
          fetch-depth: 0
      - run: bash .agents/mainframe-workflow/scripts/check.sh --base origin/${{ github.base_ref }}
```

## What sync writes

| Path | Owner | On a later sync |
|---|---|---|
| `.agents/mainframe-workflow/` | This repo | Replaced, and locked |
| `.agents/skills/mf-*/` | This repo | Replaced, and locked |
| `.claude/skills/mf-*/` | This repo | Replaced, and locked |
| `.agents/workflow.md` | The project | Created if missing, never overwritten |
| `AGENTS.md` | The project | Created if missing, otherwise the pointer line is printed |
| `CLAUDE.md` | The project | Never touched |

`.agents/mainframe-workflow/.lock` records the version and a hash of every file this repo owns. Sync removes everything in the old lock before copying, so files dropped upstream go away. Sync warns if the source is not at the tag for its `VERSION`, or if any file it wrote is gitignored in the project.

## Why a copy, not a submodule

Fresh worktrees and cloud agents do not see submodule contents, and they are the ones that most need to read the workflow. A pinned copy is in every checkout. The lock keeps the copy honest.

## What the check covers

`scripts/check.sh [--base <ref>]` runs from anywhere in the project. The base defaults to `origin/HEAD`, then `origin/main`, then `main`. Untracked files count, so it works before commit.

Only files added or changed since the merge base count, so history never needs migrating. Moving a file counts as changing it. `README.md`, `index.md` and `TEMPLATE.md` are skipped, and a blank key in the config skips its check.

| Target | Fails when |
|---|---|
| Install | `.agents/workflow.md` or the lock is missing |
| Vendored files | A locked file is missing or changed, or an unlocked file sits in `.agents/mainframe-workflow/` |
| Added decision | Bad name for `decision_naming`, a number already used here or on the base, or no `**Status:**` or `## Decision` / `## The decision` |
| Added proposal | No `## Problem`, or no `## Scenarios` with at least one bullet |
| Added plan | Not named `YYYY-MM-DD-slug.md`, or no `**Status:**` or `## Steps` |
| Added log | Not dated, or no frontmatter `summary:` |
| Added or changed file in those folders | A relative link does not resolve. URLs, anchors and code are skipped |

The state file going over `state_max_lines` is a warning only.

## Update a project

Pull a newer tag here, run sync again, review the diff and commit. If the check says a file was edited by hand, make the change in this repo and release it. A sync puts the vendored copy back.

## Develop this repo

`tests/run.sh` builds throwaway git repos and runs both scripts end to end. CI runs it on Ubuntu and on macOS, whose `/bin/bash` 3.2 is the portability test, so the scripts avoid `mapfile`, associative arrays and `readlink -f`.

## License

[MIT](LICENSE)
