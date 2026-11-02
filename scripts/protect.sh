#!/usr/bin/env bash
# Have GitHub enforce the workflow's Git rules on a repo: the default branch
# changes only through a PR, its history stays linear, and merged branches are
# deleted. Safe to run again. Needs gh, signed in as a repo admin.
# Bash 3.2 safe: macOS still ships it.
set -euo pipefail

die() {
  echo "protect: $*" >&2
  exit 1
}

[ $# -eq 1 ] || { echo "usage: protect.sh <owner/repo>" >&2; exit 2; }
case "$1" in
  */*) repo=$1 ;;
  *) echo "usage: protect.sh <owner/repo>" >&2; exit 2 ;;
esac

command -v gh >/dev/null 2>&1 || die "need gh"

name=mainframe-workflow

# No bypass_actors on purpose: the rules hold for everyone, admins included.
# Rulesets stack, so this also closes any bypass another ruleset grants.
ruleset='{
  "name": "'$name'",
  "target": "branch",
  "enforcement": "active",
  "bypass_actors": [],
  "conditions": { "ref_name": { "include": ["~DEFAULT_BRANCH"], "exclude": [] } },
  "rules": [
    { "type": "required_linear_history" },
    {
      "type": "pull_request",
      "parameters": {
        "allowed_merge_methods": ["squash", "rebase"],
        "dismiss_stale_reviews_on_push": false,
        "require_code_owner_review": false,
        "require_last_push_approval": false,
        "required_approving_review_count": 0,
        "required_review_thread_resolution": false
      }
    }
  ]
}'

gh repo edit "$repo" --delete-branch-on-merge --enable-merge-commit=false \
  --enable-squash-merge --enable-rebase-merge

id=$(gh api --paginate "repos/$repo/rulesets" --jq ".[] | select(.name == \"$name\") | .id")
if [ -n "$id" ]; then
  gh api --method PUT "repos/$repo/rulesets/$id" --input - <<< "$ruleset" >/dev/null
else
  gh api --method POST "repos/$repo/rulesets" --input - <<< "$ruleset" >/dev/null
fi

# Read back what GitHub says applies, rather than trusting the writes.
branch=$(gh api "repos/$repo" --jq .default_branch)
rules=$(gh api "repos/$repo/rules/branches/$branch" --jq '.[].type')
for rule in pull_request required_linear_history; do
  grep -qxF "$rule" <<< "$rules" || die "$rule is not active on $branch in $repo"
done

echo "protected $branch in $repo: PRs only, linear history, merged branches deleted"
