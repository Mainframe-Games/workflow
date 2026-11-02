#!/usr/bin/env bash
# End-to-end tests for sync.sh and check.sh, run in throwaway git repos.
# Bash 3.2 safe: CI runs this under macOS /bin/bash on purpose. The scripts
# under test run with the same interpreter as this file.
set -u

source_dir=$(cd "$(dirname "$0")/.." && pwd -P)
work=$(mktemp -d "${TMPDIR:-/tmp}/mainframe-workflow.XXXXXX")
trap 'rm -rf "$work"' EXIT

export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.com
export GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@example.com
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1

passed=0
failed=0

pass() {
  passed=$((passed + 1))
}

fail() { # <name> <detail>
  failed=$((failed + 1))
  echo "FAIL: $1"
  echo "$2" | sed 's/^/    /'
}

sync() {
  "$BASH" "$source_dir/scripts/sync.sh" "$@"
}

check() {
  output=$("$BASH" .agents/mainframe-workflow/scripts/check.sh "$@" 2>&1)
  status=$?
}

expect_pass() { # <name> [check args]
  local name=$1
  shift
  check "$@"
  if [ "$status" -eq 0 ]; then pass; else fail "$name" "exit $status: $output"; fi
}

expect_fail() { # <name> <message> [check args]
  local name=$1 message=$2
  shift 2
  check "$@"
  if [ "$status" -eq 1 ] && grep -qF -- "$message" <<< "$output"; then
    pass
  else
    fail "$name" "exit $status, wanted '$message': $output"
  fi
}

expect() { # <name> <command...>
  local name=$1
  shift
  if "$@"; then pass; else fail "$name" "failed: $*"; fi
}

expect_not() { # <name> <command...>
  local name=$1
  shift
  if "$@"; then fail "$name" "should fail: $*"; else pass; fi
}

contains() { # <text> <message>
  grep -qF -- "$2" <<< "$1"
}

set_config() { # <key> <value>
  awk -v key="$1" -v value="$2" '
    index($0, key ":") == 1 { print key ": " value; next }
    { print }
  ' .agents/workflow.md > .agents/workflow.md.new
  mv .agents/workflow.md.new .agents/workflow.md
}

to_crlf() { # <file...>
  local file
  for file in "$@"; do
    awk '{ printf "%s\r\n", $0 }' "$file" > "$file.new"
    mv "$file.new" "$file"
  done
}

good_decision() { # <file>
  printf '# Title\n\n**Status:** accepted\n\n## Decision\n\nDo it.\n' > "$1"
}

good_proposal() { # <file>
  printf '# Title\n\n## Problem\n\nWhy.\n\n## Scenarios\n\n- Given a, when b, then c. Test: `T`.\n\n## Testing\n' > "$1"
}

good_plan() { # <file>
  printf '# Title\n\n**Status:** in progress\n\n## Steps\n\n- [ ] Step.\n' > "$1"
}

good_log() { # <file>
  printf -- '---\nsummary: >-\n  Short.\n---\n\n# 2026-01-02: Title\n' > "$1"
}

# A repo with old files that break every rule, on main, with a branch off it.
fixture=$work/fixture
mkdir -p "$fixture"
cd "$fixture" || exit 1
git init -q
git symbolic-ref HEAD refs/heads/main
mkdir -p docs/decisions docs/proposals docs/plans docs/logs
printf 'old\n' > docs/decisions/Old_Decision.md
printf 'old\n' > docs/decisions/0001-first.md
printf 'old\n' > docs/proposals/old.md
printf 'old\n' > docs/plans/old-plan.md
printf 'old [gone](missing.md)\n' > docs/logs/old-log.md
sync . >/dev/null 2>&1 || { echo "sync failed in the fixture"; exit 1; }
git add -A
git commit -qm base
git checkout -qb feature

new_case() {
  cd "$work" || exit 1
  rm -rf case
  cp -R "$fixture" case
  cd case || exit 1
}

new_project() {
  cd "$work" || exit 1
  rm -rf project
  mkdir project
  cd project || exit 1
  git init -q
}

# check.sh: a clean repo and history

new_case
expect_pass "clean repo passes"

new_case
good_decision docs/decisions/0002-next.md
good_proposal docs/proposals/thing.md
good_plan docs/plans/2026-01-02-thing.md
good_log docs/logs/2026-01-02-thing.md
good_log docs/logs/2026-01-03.md
expect_pass "good untracked files pass"
git add -A
git commit -qm next
expect_pass "good committed files pass"

new_case
printf 'edited, still no headers\n' >> docs/decisions/Old_Decision.md
printf 'edited\n' >> docs/plans/old-plan.md
expect_pass "changing an old file does not apply the added-file rules"

new_case
git mv docs/plans/old-plan.md docs/plans/old-plan-moved.md
expect_pass "renaming an old file passes"

new_case
git checkout -q main
git rm -q docs/logs/old-log.md
git commit -qm "drop old log"
git checkout -q feature
expect_pass "base is compared at the merge base"

new_case
printf 'x\n' > docs/plans/notes.txt
printf 'x\n' > docs/decisions/README.md
printf 'x\n' > docs/proposals/index.md
printf 'x\n' > docs/plans/TEMPLATE.md
expect_pass "non-Markdown, README, index and TEMPLATE are skipped"

new_case
mkdir sub
output=$(cd sub && "$BASH" ../.agents/mainframe-workflow/scripts/check.sh 2>&1)
status=$?
expect "runs from a subfolder" [ "$status" -eq 0 ]

# check.sh: the install

new_case
rm .agents/workflow.md
expect_fail "missing config fails" ".agents/workflow.md missing"

new_case
printf 'no frontmatter\n' > .agents/workflow.md
expect_fail "config without frontmatter fails" "no frontmatter"

new_case
rm .agents/mainframe-workflow/.lock
expect_fail "missing lock fails" ".lock missing"

new_case
rm .agents/mainframe-workflow/workflow/ship.md
expect_fail "missing locked file fails" "ship.md: locked file missing; edited by hand, fix upstream"

new_case
rm .claude/skills/mf-ship/SKILL.md
expect_fail "missing locked skill fails" "mf-ship/SKILL.md: locked file missing"

new_case
printf 'tweak\n' >> .agents/mainframe-workflow/workflow/ship.md
expect_fail "hand-edited vendored file fails" "ship.md: hash differs from the lock; edited by hand, fix upstream"

new_case
printf 'tweak\n' >> .agents/skills/mf-plan/SKILL.md
expect_fail "hand-edited vendored skill fails" "mf-plan/SKILL.md: hash differs"

new_case
printf 'extra\n' > .agents/mainframe-workflow/workflow/extra.md
expect_fail "unlocked vendored file fails" "extra.md: not in the lock"

new_case
mkdir -p .agents/skills/own
printf 'own\n' > .agents/skills/own/SKILL.md
expect_pass "project-owned skill beside the vendored ones passes"

new_case
to_crlf .agents/mainframe-workflow/workflow/*.md .agents/mainframe-workflow/VERSION \
  .agents/skills/mf-plan/SKILL.md .agents/mainframe-workflow/.lock .agents/workflow.md
expect_pass "CRLF does not fail the lock"
good_decision docs/decisions/0002-next.md
good_log docs/logs/2026-01-02.md
to_crlf docs/decisions/0002-next.md docs/logs/2026-01-02.md
expect_pass "CRLF added files pass"
printf 'tweak\r\n' >> .agents/mainframe-workflow/workflow/ship.md
expect_fail "CRLF does not hide an edit" "ship.md: hash differs"

# check.sh: decisions

new_case
good_decision docs/decisions/Bad_Name.md
expect_fail "numbered: bad name fails" "bad decision name, want NNNN-slug.md"

new_case
good_decision docs/decisions/2026-01-02-thing.md
expect_fail "numbered: a date is not a number" "bad decision name, want NNNN-slug.md"

new_case
good_decision docs/decisions/0001-again.md
expect_fail "duplicate number fails" "duplicate number, also used by 0001-first.md"

new_case
good_decision docs/decisions/0002-a.md
good_decision docs/decisions/0002-b.md
expect_fail "two added with one number fail" "duplicate number"

new_case
git checkout -q main
good_decision docs/decisions/0002-landed.md
git add -A
git commit -qm landed
git checkout -q feature
good_decision docs/decisions/0002-mine.md
expect_fail "number taken on the base fails" "duplicate number, also used by 0002-landed.md"

new_case
printf '# T\n\n## Decision\n\nx\n' > docs/decisions/0002-next.md
expect_fail "decision without status fails" "decision missing **Status:**"

new_case
printf '# T\n\n**Status:** accepted\n\n## Context\n' > docs/decisions/0002-next.md
expect_fail "decision without heading fails" "decision missing ## Decision"

new_case
printf '# T\n\n```\n**Status:** accepted\n\n## Decision\n```\n' > docs/decisions/0002-next.md
expect_fail "fenced headings do not count" "decision missing ## Decision"

new_case
printf '# T\n\n**Status:** accepted\n\n## The decision\n\nx\n' > docs/decisions/0002-next.md
expect_pass "## The decision is accepted"

new_case
set_config decision_naming dated
good_decision docs/decisions/2026-01-02-thing.md
expect_pass "dated: good name passes"
good_decision docs/decisions/0002-next.md
expect_fail "dated: bad name fails" "bad decision name, want YYYY-MM-DD-slug.md"

new_case
set_config decision_naming slug
good_decision docs/decisions/some-thing.md
expect_pass "slug: good name passes"
good_decision docs/decisions/Some_Thing.md
expect_fail "slug: bad name fails" "bad decision name, want slug.md"

new_case
set_config decision_naming numberd
expect_fail "bad decision_naming fails" "bad decision_naming: numberd"

new_case
set_config decision_naming ""
good_decision docs/decisions/Any_Name.md
expect_pass "blank decision_naming skips the name check"
printf 'x\n' > docs/decisions/Other.md
expect_fail "blank decision_naming keeps the content checks" "decision missing **Status:**"

new_case
set_config decisions ""
printf 'x\n' > docs/decisions/Bad_Name.md
expect_pass "blank decisions skips decisions"

# check.sh: proposals

new_case
printf '# T\n\n## Scenarios\n\n- Given a.\n' > docs/proposals/thing.md
expect_fail "proposal without Problem fails" "proposal missing ## Problem"

new_case
printf '# T\n\n## Problem\n\nx\n' > docs/proposals/thing.md
expect_fail "proposal without Scenarios fails" "needs ## Scenarios"

new_case
printf '# T\n\n## Problem\n\nx\n\n## Scenarios\n\nNone yet.\n\n## Testing\n\n- Not a scenario.\n' > docs/proposals/thing.md
expect_fail "proposal without a scenario bullet fails" "needs ## Scenarios"

new_case
printf '# T\n\n## Problem\n\nx\n\n## Scenarios\n\n### Phase one\n\n- Given a.\n' > docs/proposals/thing.md
expect_pass "scenario bullets under a subheading count"

new_case
set_config proposals ""
printf 'x\n' > docs/proposals/thing.md
expect_pass "blank proposals skips proposals"

# check.sh: plans

new_case
good_plan docs/plans/thing.md
expect_fail "plan without a date fails" "bad plan name, want YYYY-MM-DD-slug.md"

new_case
printf '# T\n\n## Steps\n\n- [ ] x\n' > docs/plans/2026-01-02-thing.md
expect_fail "plan without status fails" "plan missing **Status:**"

new_case
printf '# T\n\n**Status:** in progress\n' > docs/plans/2026-01-02-thing.md
expect_fail "plan without steps fails" "plan missing ## Steps"

new_case
set_config plans ""
printf 'x\n' > docs/plans/thing.md
expect_pass "blank plans skips plans"

# check.sh: logs

new_case
good_log docs/logs/thing.md
expect_fail "log without a date fails" "bad log name"

new_case
printf '# 2026-01-02: Title\n' > docs/logs/2026-01-02.md
expect_fail "log without frontmatter fails" "log missing frontmatter summary:"

new_case
printf -- '---\ntitle: x\n---\n\nsummary: not frontmatter\n' > docs/logs/2026-01-02.md
expect_fail "summary outside frontmatter fails" "log missing frontmatter summary:"

new_case
printf -- '---\nsummary: x\n' > docs/logs/2026-01-02.md
expect_fail "unclosed frontmatter fails" "log missing frontmatter summary:"

new_case
set_config logs ""
printf 'x\n' > docs/logs/thing.md
expect_pass "blank logs skips logs"

# check.sh: links

new_case
good_plan docs/plans/2026-01-02-thing.md
good_log docs/logs/2026-01-02.md
printf '[plan](../plans/2026-01-02-thing.md) [anchored](../plans/2026-01-02-thing.md#steps) ![i](../plans/old-plan.md "title")\n' >> docs/logs/2026-01-02.md
printf '[url](https://example.com/x) [mail](mailto:a@example.com) [here](#top) [abs](/docs/gone.md)\n' >> docs/logs/2026-01-02.md
printf '`[code](gone.md)`\n\n```\n[fence](gone.md)\n```\n' >> docs/logs/2026-01-02.md
expect_pass "good links, URLs, anchors and code are fine"

new_case
good_log docs/logs/2026-01-02.md
printf '[gone](gone.md)\n' >> docs/logs/2026-01-02.md
expect_fail "broken link in an added file fails" "broken link: gone.md"

new_case
printf '[gone](../plans/gone.md#steps)\n' >> docs/decisions/0001-first.md
expect_fail "broken link in a changed file fails" "broken link: ../plans/gone.md"

new_case
git mv docs/logs/old-log.md docs/logs/moved.md
expect_fail "broken link in a moved file fails" "broken link: missing.md"

new_case
good_log docs/logs/2026-01-02.md
printf 'x\n' > "docs/logs/my file.md"
printf '[spaced](my%%20file.md) [angled](<my file.md>)\n' >> docs/logs/2026-01-02.md
expect_fail "spaced names resolve, the odd one out fails" "bad log name"
expect_not "spaced links are not broken" contains "$output" "broken link"

new_case
good_decision docs/decisions/README.md
printf '[gone](gone.md)\n' >> docs/decisions/README.md
expect_pass "skipped files are not link checked"

# check.sh: state

new_case
printf 'one\ntwo\nthree\n' > docs/state.md
set_config state_max_lines 2
expect_pass "state over the limit only warns"
expect "state over the limit prints a warning" contains "$output" "warning: docs/state.md: 3 lines"

new_case
printf 'one\ntwo\nthree\n' > docs/state.md
set_config state_max_lines ""
expect_pass "blank state_max_lines skips the warning"
expect_not "blank state_max_lines prints nothing" contains "$output" "warning"

# check.sh: base

new_case
good_decision docs/decisions/Bad_Name.md
git add -A
git commit -qm bad
expect_fail "base defaults to main" "bad decision name"
git update-ref refs/remotes/origin/main HEAD
expect_pass "origin/main wins over main"
git update-ref -d refs/remotes/origin/main
git update-ref refs/remotes/origin/trunk HEAD
git symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/trunk
expect_pass "origin/HEAD wins"
git symbolic-ref -d refs/remotes/origin/HEAD

new_case
good_decision docs/decisions/Bad_Name.md
git add -A
git commit -qm bad
expect_pass "--base is honoured" --base HEAD
expect_pass "--base=ref is honoured" --base=HEAD
expect_fail "--base with a bad ref fails" "base not found: nope" --base nope

new_case
git branch -qD main
expect_fail "no base fails" "no base found"

# sync.sh

new_project
sync . >/dev/null 2>&1
expect "agents skills written" [ -f .agents/skills/mf-start/SKILL.md ]
expect "claude skills written" [ -f .claude/skills/mf-engine-bug/SKILL.md ]
expect "workflow written" [ -f .agents/mainframe-workflow/workflow/README.md ]
expect "templates written" [ -f .agents/mainframe-workflow/templates/AGENTS.md ]
expect "check written" [ -f .agents/mainframe-workflow/scripts/check.sh ]
expect "VERSION written" [ -f .agents/mainframe-workflow/VERSION ]
expect "config created" [ -f .agents/workflow.md ]
expect "AGENTS.md created" [ -f AGENTS.md ]
expect_not "CLAUDE.md not created" [ -e CLAUDE.md ]
expect_not "sync.sh not vendored" [ -e .agents/mainframe-workflow/scripts/sync.sh ]
expect "lock header" [ "$(head -n 1 .agents/mainframe-workflow/.lock)" = "# mainframe-workflow $(cat "$source_dir/VERSION")" ]
paths=$(tail -n +2 .agents/mainframe-workflow/.lock | sed 's/^[0-9a-f]\{64\}  //')
expect "lock lines are sha, two spaces, path" [ "$(tail -n +2 .agents/mainframe-workflow/.lock | grep -cvE '^[0-9a-f]{64}  [^ ]+$')" -eq 0 ]
expect "lock sorted with LC_ALL=C" [ "$paths" = "$(printf '%s\n' "$paths" | LC_ALL=C sort)" ]
expect_not "lock has no project-owned files" contains "$paths" ".agents/workflow.md"
expect "lock paths are relative" [ -z "$(printf '%s\n' "$paths" | grep '^/')" ]

new_project
sync . --agents claude >/dev/null 2>&1
expect "--agents claude writes claude" [ -f .claude/skills/mf-plan/SKILL.md ]
expect_not "--agents claude skips agents" [ -e .agents/skills ]
sync . --agents agents >/dev/null 2>&1
expect "--agents agents writes agents" [ -f .agents/skills/mf-plan/SKILL.md ]
expect_not "switching targets removes the old one" [ -e .claude ]

new_project
output=$(sync . --agents agents,cursor 2>&1)
status=$?
expect "unknown agent target exits 1" [ "$status" -eq 1 ]
expect "unknown agent target says so" contains "$output" "unknown agent target: 'cursor'"
expect_not "unknown agent target writes nothing" [ -e .agents ]
output=$(sync . --agents "" 2>&1)
expect "empty agent target fails" contains "$output" "no agent target given"
output=$(sync "$work/nowhere" 2>&1)
expect "missing project fails" contains "$output" "project not found"
output=$(sync 2>&1)
expect "no project prints usage" contains "$output" "usage: sync.sh"
output=$(sync . --nope 2>&1)
expect "unknown option prints usage" contains "$output" "usage: sync.sh"
output=$(sync "$source_dir" 2>&1)
expect "syncing onto this repo fails" contains "$output" "project is this repo"

new_project
sync . >/dev/null 2>&1
printf 'mine\n' > .agents/workflow.md
sync . >/dev/null 2>&1
expect "second sync keeps the config" [ "$(cat .agents/workflow.md)" = mine ]

new_project
printf '# Mine\n' > AGENTS.md
output=$(sync . 2>&1)
expect "existing AGENTS.md left alone" [ "$(cat AGENTS.md)" = "# Mine" ]
expect "missing pointer is printed" contains "$output" 'Read `.agents/workflow.md`'
sync . >/dev/null 2>&1
printf 'See `.agents/workflow.md`.\n' > AGENTS.md
output=$(sync . 2>&1)
expect_not "existing pointer prints nothing" contains "$output" "Add this line"

new_project
printf 'mine\n' > CLAUDE.md
output=$(sync . 2>&1)
expect "CLAUDE.md untouched" [ "$(cat CLAUDE.md)" = mine ]
expect "CLAUDE.md without AGENTS.md gets a reminder" contains "$output" "does not point to AGENTS.md"

new_project
output=$(sync . 2>&1)
expect "no CLAUDE.md gets a reminder" contains "$output" "@AGENTS.md"
expect_not "the reminder creates nothing" [ -e CLAUDE.md ]

new_project
printf '@AGENTS.md\n' > CLAUDE.md
output=$(sync . 2>&1)
expect_not "CLAUDE.md with the pointer gets no reminder" contains "$output" "does not point to AGENTS.md"

new_project
output=$(sync . --agents agents 2>&1)
expect_not "no reminder without claude skills" contains "$output" "does not point to AGENTS.md"

new_project
mkdir -p .agents/skills/own
printf 'own\n' > .agents/skills/own/SKILL.md
sync . >/dev/null 2>&1
sync . >/dev/null 2>&1
expect "project-owned skill survives sync" [ -f .agents/skills/own/SKILL.md ]

new_project
sync . >/dev/null 2>&1
printf 'tweak\n' >> .agents/mainframe-workflow/workflow/ship.md
sync . >/dev/null 2>&1
git add -A
git commit -qm base
expect_pass "sync repairs a hand edit" --base HEAD

new_project
sync . >/dev/null 2>&1
printf 'keep\n' > outside.md
printf 'keep\n' > ../outside.md
printf '%s  %s\n%s  %s\n%s  %s\n' x outside.md x ../outside.md x .agents/../outside.md \
  >> .agents/mainframe-workflow/.lock
output=$(sync . 2>&1)
expect "lock cannot delete project files" [ -f outside.md ]
expect "lock cannot delete outside the project" [ -f ../outside.md ]
expect "ignored lock paths warn" contains "$output" "ignoring lock path: ../outside.md"
rm ../outside.md

new_project
printf '.claude/\n' > .gitignore
output=$(sync . 2>&1)
expect "gitignored install warns" contains "$output" "gitignored in the project"
expect "gitignored install names the file" contains "$output" ".claude/skills/mf-plan/SKILL.md"

new_project
output=$(sync . 2>&1)
expect_not "no gitignore warning without need" contains "$output" "gitignored"

# Upstream changes need a source of their own.
cp -R "$source_dir" "$work/source"
rm -rf "$work/source/.git"
source_copy=$work/source
version=$(cat "$source_dir/VERSION")
(cd "$source_copy" && git init -q && git add -A && git commit -qm source && git tag "v$version")

new_project
git commit -q --allow-empty -m base
"$BASH" "$source_copy/scripts/sync.sh" . >/dev/null 2>&1
git add -A
git commit -qm install
rm "$source_copy/workflow/decide.md"
rm -r "$source_copy/skills/mf-decide"
output=$("$BASH" "$source_copy/scripts/sync.sh" . 2>&1)
expect_not "dropped page removed" [ -e .agents/mainframe-workflow/workflow/decide.md ]
expect_not "dropped skill removed" [ -e .agents/skills/mf-decide ]
expect_not "dropped claude skill removed" [ -e .claude/skills/mf-decide ]
expect "resync warns about the dirty source" contains "$output" "source is not at tag v$version"
git add -A
git commit -qm update
expect_pass "project passes after an upstream drop" --base HEAD~1

(cd "$source_copy" && git add -A && git commit -qm drop)
output=$("$BASH" "$source_copy/scripts/sync.sh" . 2>&1)
expect "warns when the source is past the tag" contains "$output" "source is not at tag v$version"
(cd "$source_copy" && git tag -f "v$version" >/dev/null)
output=$("$BASH" "$source_copy/scripts/sync.sh" . 2>&1)
expect_not "no warning at the tag" contains "$output" "source is not at tag"

echo "$passed passed, $failed failed"
[ "$failed" -eq 0 ]
