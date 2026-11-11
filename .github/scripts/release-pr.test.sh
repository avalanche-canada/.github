#!/usr/bin/env bash
# Checks how release-pr.sh rewrites an open release PR's body, against a throwaway repo and a fake gh.
# Run after changing release-pr.sh: .github/scripts/release-pr.test.sh
set -euo pipefail
script=$(cd "$(dirname "$0")" && pwd)/release-pr.sh
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# dev is one commit ahead of qa, and that commit is #2's merge commit. #1 merged earlier, so it isn't in the range.
git init -q "$tmp/repo"
cd "$tmp/repo"
commit() { git -c user.name=t -c user.email=t@t -c commit.gpgsign=false commit -q --allow-empty -m "$1"; }
commit base
git update-ref refs/remotes/origin/qa HEAD
commit 'Merge pull request #2'
git update-ref refs/remotes/origin/dev HEAD
# #3 merged master back into dev. Like dev, qa and main, master is a stage branch and is never listed.
jq -n --arg sha "$(git rev-parse HEAD)" '[
    {number: 3, title: "master -> dev", author: {login: "z"}, headRefName: "master", mergeCommit: {oid: $sha}},
    {number: 2, title: "B \\d & co", author: {login: "y"}, headRefName: "feature", mergeCommit: {oid: $sha}},
    {number: 1, title: "A", author: {login: "x"}, headRefName: "older", mergeCommit: {oid: "0000"}}
]' >"$tmp/merged.json"

# Fake gh: release PR #7 is open, its body lives in $tmp/body, and each edit adds a line to $tmp/edits.
# It has no "pr merge": an open release PR must not get auto-merge turned back on, so a hold sticks.
mkdir "$tmp/bin"
cat >"$tmp/bin/gh" <<'EOF'
#!/usr/bin/env bash
q=. prev=
for a in "$@"; do [ "$prev" = -q ] && q=$a; prev=$a; done
case "$1 $2" in
"pr list")
    if [[ " $* " == *" --base "* ]]; then echo '[{"number": 7}]'; else cat "$FAKE/merged.json"; fi | jq -r "$q"
    ;;
"pr view") jq -Rs '{body: .}' "$FAKE/body" | jq -r "$q" ;;
"pr edit") printf '%s' "$5" >"$FAKE/body" && echo >>"$FAKE/edits" ;;
*) echo "unexpected: gh $*" >&2 && exit 1 ;;
esac
EOF
chmod +x "$tmp/bin/gh"

fails=0
check() { # name, body before, body expected after two runs, edits expected
    printf '%s' "$2" >"$tmp/body"
    : >"$tmp/edits"
    for _ in 1 2; do PATH="$tmp/bin:$PATH" FAKE=$tmp "$script" dev qa >/dev/null; done
    body=$(cat "$tmp/body") edits=$(($(wc -l <"$tmp/edits")))
    if [ "$body" = "$3" ] && [ "$edits" = "$4" ]; then
        echo "ok   $1"
    else
        echo "FAIL $1 ($edits edits, want $4). Body:"
        printf '%s\n' "$body" | sed 's/^/    /'
        fails=1
    fi
}

inc='## Includes'$'\n''- #2 B \d & co (@y)'
check 'keeps text above Includes' \
    $'Hold until Friday\n\n## Includes\n- #1 A (@x)\n\n## Deploy notes\n- note' \
    $'Hold until Friday\n\n'"$inc"$'\n\n## Deploy notes\n- note' 1
check 'adds Includes below a body without one' 'Forecast images fix' $'Forecast images fix\n\n'"$inc" 1
check 'keeps CRLF sections from github.com' \
    $'## Includes\r\n- #1 A (@x)\r\n\r\n## Deploy notes\r\n- note' "$inc"$'\n\n## Deploy notes\r\n- note' 1
check 'leaves an up-to-date body alone' "$inc" "$inc" 0
exit $fails
