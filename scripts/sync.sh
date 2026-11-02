#!/usr/bin/env bash
# Install the workflow into a project, replacing the files of any older install.
# Run from a checkout of this repo. Bash 3.2 safe: macOS still ships it.
set -euo pipefail

usage() {
  echo "usage: sync.sh <project> [--agents agents,claude]" >&2
  exit 2
}

die() {
  echo "sync: $*" >&2
  exit 1
}

warn() {
  echo "warning: $*" >&2
}

source_dir=$(cd "$(dirname "$0")/.." && pwd -P)
project=
agents=agents,claude

while [ $# -gt 0 ]; do
  case "$1" in
    --agents)
      [ $# -ge 2 ] || usage
      agents=$2
      shift 2
      ;;
    --agents=*)
      agents=${1#--agents=}
      shift
      ;;
    -*) usage ;;
    *)
      [ -z "$project" ] || usage
      project=$1
      shift
      ;;
  esac
done

[ -n "$project" ] || usage
[ -d "$project" ] || die "project not found: $project"
project=$(cd "$project" && pwd -P)
[ "$project" != "$source_dir" ] || die "project is this repo"

to_agents=false
to_claude=false
old_ifs=$IFS
IFS=,
for target in $agents; do
  case "$target" in
    agents) to_agents=true ;;
    claude) to_claude=true ;;
    *) die "unknown agent target: '$target' (use agents, claude)" ;;
  esac
done
IFS=$old_ifs
$to_agents || $to_claude || die "no agent target given (use agents, claude)"

if command -v sha256sum >/dev/null 2>&1; then
  sha() { sha256sum; }
elif command -v shasum >/dev/null 2>&1; then
  sha() { shasum -a 256; }
else
  die "need sha256sum or shasum"
fi

# Hash without carriage returns so Windows checkouts match.
hash_file() {
  tr -d '\r' < "$1" | sha | cut -d' ' -f1
}

version=$(tr -d '[:space:]' < "$source_dir/VERSION")
vendor=.agents/mainframe-workflow
lock=$project/$vendor/.lock

if [ -f "$lock" ]; then
  while IFS= read -r line; do
    line=${line%$'\r'}
    case "$line" in
      '' | '#'*) continue ;;
    esac
    path=${line#*  }
    # The lock is a file in the project: never let it aim the rm elsewhere.
    case "$path" in
      */../* | ../*)
        warn "ignoring lock path: $path"
        continue
        ;;
      "$vendor"/* | .agents/skills/* | .claude/skills/*) ;;
      *)
        warn "ignoring lock path: $path"
        continue
        ;;
    esac
    rm -f "$project/$path"
    (cd "$project" && rmdir -p "$(dirname "$path")" 2>/dev/null) || true
  done < "$lock"
  rm -f "$lock"
fi

installed=

install_file() { # <source file> <path in project>
  mkdir -p "$project/$(dirname "$2")"
  cp "$1" "$project/$2"
  installed="$installed$2
"
}

install_tree() { # <source dir> <path in project>
  local file
  while IFS= read -r file; do
    install_file "$file" "$2/${file#"$1"/}"
  done < <(find "$1" -type f)
}

install_tree "$source_dir/workflow" "$vendor/workflow"
install_tree "$source_dir/templates" "$vendor/templates"
install_file "$source_dir/scripts/check.sh" "$vendor/scripts/check.sh"
install_file "$source_dir/VERSION" "$vendor/VERSION"
if $to_agents; then
  install_tree "$source_dir/skills" .agents/skills
fi
if $to_claude; then
  install_tree "$source_dir/skills" .claude/skills
fi

if [ ! -e "$project/.agents/workflow.md" ]; then
  cp "$source_dir/templates/workflow.md" "$project/.agents/workflow.md"
  echo "created .agents/workflow.md: fill it in"
fi

if [ ! -e "$project/AGENTS.md" ]; then
  cp "$source_dir/templates/AGENTS.md" "$project/AGENTS.md"
  echo "created AGENTS.md"
elif ! grep -q '\.agents/workflow\.md' "$project/AGENTS.md"; then
  echo "AGENTS.md has no pointer to the workflow. Add this line:"
  grep '\.agents/workflow\.md' "$source_dir/templates/AGENTS.md"
fi

if $to_claude && ! grep -qs 'AGENTS\.md' "$project/CLAUDE.md"; then
  echo "CLAUDE.md does not point to AGENTS.md. Keep instructions in AGENTS.md and put this in CLAUDE.md:"
  echo "@AGENTS.md"
fi

{
  echo "# mainframe-workflow $version"
  printf '%s' "$installed" | LC_ALL=C sort | while IFS= read -r path; do
    printf '%s  %s\n' "$(hash_file "$project/$path")" "$path"
  done
} > "$lock"

echo "synced mainframe-workflow $version to $project"

# A gitignored file never reaches a fresh clone, where check.sh would fail.
if git -C "$project" rev-parse --git-dir >/dev/null 2>&1; then
  ignored=$(printf '%s%s\n%s\n' "$installed" .agents/workflow.md "$vendor/.lock" |
    git -C "$project" check-ignore --stdin || true)
  if [ -n "$ignored" ]; then
    warn "gitignored in the project, so check.sh fails on a fresh clone:"
    echo "$ignored" >&2
  fi
fi

tags=$(git -C "$source_dir" tag --points-at HEAD 2>/dev/null || true)
dirty=$(git -C "$source_dir" status --porcelain 2>/dev/null || true)
if ! grep -qxF "v$version" <<< "$tags" || [ -n "$dirty" ]; then
  warn "source is not at tag v$version"
fi
