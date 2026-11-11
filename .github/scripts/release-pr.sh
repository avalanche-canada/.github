#!/usr/bin/env bash
# Keeps one open release PR from $1 into $2. A new one gets auto-merge, so a single approval ships it.
# Only the "## Includes" section of the body is rewritten; Release steps and Deploy notes are kept.
# Run by .github/workflows/release-prs.yml, from the repo whose release PR it manages.
set -euo pipefail
head=$1 base=$2
range="origin/$base..origin/$head"

shas=$(git rev-list "$range")

# A PR is in this release when its merge commit is in head but not base. That catches stacked PRs too: GitHub gives
# them the merge commit of the PR that carried them in. Not --search: its index can lag the merge behind this run.
includes=$(gh pr list --state merged -L 1000 \
    --json number,title,author,headRefName,mergeCommit \
    -q '.[] | select(.headRefName | test("^(dev|qa|main|master)$") | not)
        | "\(.mergeCommit.oid) - #\(.number) \(.title) (@\(.author.login))"' |
    awk 'NR == FNR {in_range[$1]; next} $1 in in_range {sub(/^[^ ]+ /, ""); print}' <(printf '%s\n' "$shas") - |
    sort -t'#' -k2n)
if [ -z "$includes" ]; then
    echo "No merged PRs to release from $head into $base"
    exit 0
fi

pr=$(gh pr list --base "$base" --head "$head" --state open --json number -q '.[0].number // empty')
if [ -z "$pr" ]; then
    url=$(gh pr create --base "$base" --head "$head" --title "$head -> $base" --body "## Includes"$'\n'"$includes")
    # Only on create, so turning auto-merge off by hand holds the release.
    gh pr merge "$url" --auto --merge
else
    old=$(gh pr view "$pr" --json body -q .body)
    # Swap the Includes section in place, or add one at the end (github.com edits use CRLF, hence [[:space:]]).
    new=$(printf '%s\n' "$old" | INCLUDES=$includes awk '
        /^## /{skip = /^## Includes[[:space:]]*$/; if (skip) {print "## Includes\n" ENVIRON["INCLUDES"] "\n"; done = 1}}
        !skip
        END {if (!done) print "\n## Includes\n" ENVIRON["INCLUDES"]}')
    [ "$new" = "$old" ] || gh pr edit "$pr" --body "$new"
fi
