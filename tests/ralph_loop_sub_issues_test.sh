#!/usr/bin/env bash
# Each sub-issue (declaring a parent via "## Parent") counts as a separate
# ticket toward --max-tickets, in the live loop and in --dry-run.
set -euo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
export DEV_SCRIPTS_TEST_DIR="$tmp" TMPDIR="$tmp" PATH="$tmp:$PATH"
mkdir -p "$tmp/tools"
cat >"$tmp/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case "$*" in
    'api user --jq .login') echo tester ;;
    'api graphql --input -')
        cat >/dev/null
        cat <<'JSON'
{"data":{"search":{"nodes":[
  {"number":1,"title":"Parent specification","url":"https://example.test/1","body":"Spec for the parent.","labels":{"nodes":[{"name":"ready-for-agent"}]},"assignees":{"nodes":[]},"blockedBy":{"nodes":[]}},
  {"number":2,"title":"Sub-issue one","url":"https://example.test/2","body":"## Parent\n#1","labels":{"nodes":[{"name":"ready-for-agent"}]},"assignees":{"nodes":[]},"blockedBy":{"nodes":[]}},
  {"number":3,"title":"Sub-issue two","url":"https://example.test/3","body":"## Parent\n#1","labels":{"nodes":[{"name":"ready-for-agent"}]},"assignees":{"nodes":[]},"blockedBy":{"nodes":[{"number":2,"state":"OPEN"}]}},
  {"number":4,"title":"Standalone ticket","url":"https://example.test/4","body":"Standalone work.","labels":{"nodes":[{"name":"ready-for-agent"}]},"assignees":{"nodes":[]},"blockedBy":{"nodes":[]}}
]}}}
JSON
        ;;
    'issue list '*)
        for n in 1 2 3 4; do
            body=""
            [[ "$n" == 2 || "$n" == 3 ]] && body='## Parent
#1'
            jq -nc --argjson n "$n" --arg body "$body" \
                '{number:$n,title:("Ticket "+($n|tostring)),body:$body,labels:[],assignees:[]}'
        done | jq -s . ;;
    'api repos/'*'/issues/3 '*)
        # Sub-issue #3 is blocked by #2 until #2 is closed. The stub applies the
        # caller's --jq filter itself, so emit the bare count.
        if [[ -f "$DEV_SCRIPTS_TEST_DIR/closed-2" ]]; then echo 0; else echo 1; fi ;;
    'api repos/'*) echo 0 ;;
    'issue view '*'--json state --jq .state')
        if [[ -f "$DEV_SCRIPTS_TEST_DIR/closed-$3" ]]; then echo CLOSED; else echo OPEN; fi ;;
    'issue view '*)
        body=""
        [[ "$3" == 2 || "$3" == 3 ]] && body='## Parent
#1'
        jq -nc --argjson n "$3" --arg body "$body" \
            '{number:$n,title:("Ticket "+($n|tostring)),body:$body,comments:[],url:("https://example.test/"+($n|tostring))}' ;;
    'label create '*) ;;
    'issue edit '*) echo "$3" >>"$DEV_SCRIPTS_TEST_DIR/claims" ;;
    *) echo "unexpected gh: $*" >&2; exit 99 ;;
esac
EOF
cat >"$tmp/git" <<'EOF'
#!/usr/bin/env bash
case "$*" in
    'rev-parse --show-toplevel') echo "$DEV_SCRIPTS_TEST_DIR" ;;
    'status '*) ;;
    *) echo "unexpected git: $*" >&2; exit 99 ;;
esac
EOF
cat >"$tmp/pi" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
n=$(grep -o 'Implement GitHub ticket #[0-9]*' <<<"${!#}" | head -1 | tr -cd '0-9')
echo "$n" >>"$DEV_SCRIPTS_TEST_DIR/attempts"
touch "$DEV_SCRIPTS_TEST_DIR/closed-$n"
EOF
cp "$tmp/pi" "$tmp/claude"
chmod +x "$tmp/gh" "$tmp/git" "$tmp/pi" "$tmp/claude"

# The dry run counts each sub-issue separately and ignores parent specifications.
output=$(PATH="$tmp:$PATH" "$root/ralph_loop.sh" --agent pi --repo owner/repo --dry-run)
grep -Eq '^1 +#2 ' <<<"$output"
grep -Eq '^2 +#3 ' <<<"$output"
grep -Eq '^3 +#4 ' <<<"$output"
grep -q '1 parent specification issue(s) ignored' <<<"$output"
grep -q 'All 3 eligible tickets are runnable. Nothing stranded.' <<<"$output"
if grep -Eq '^[0-9]+ +#1 ' <<<"$output"; then
    echo "parent specification issue must not be listed as a ticket" >&2; exit 1
fi

output=$(PATH="$tmp:$PATH" "$root/ralph_loop.sh" --agent pi --repo owner/repo --dry-run --max-tickets 1)
[[ $(grep -Ec '^[0-9]+ +#[0-9]+ ' <<<"$output") -eq 1 ]]
grep -Eq '^1 +#2 ' <<<"$output"
grep -q 'Maximum ticket count (1) reached' <<<"$output"
if grep -Eq '#3 |#4 |Not runnable' <<<"$output"; then
    echo "cap 1 must stop before the second sub-issue and print no stranded report" >&2; exit 1
fi

output=$(PATH="$tmp:$PATH" "$root/ralph_loop.sh" --agent pi --repo owner/repo --dry-run --max-tickets 2)
[[ $(grep -Ec '^[0-9]+ +#[0-9]+ ' <<<"$output") -eq 2 ]]
grep -Eq '^2 +#3 ' <<<"$output"
! grep -Eq '#4 ' <<<"$output"
grep -q 'Maximum ticket count (2) reached' <<<"$output"
! grep -q 'Not runnable' <<<"$output"

echo 'ok - dry run counts sub-issues separately and ignores parent specification issues'

for backend in pi claude; do
    # Cap 1: only #2 runs; the unblocked sibling #3 still needs its own slot.
    rm -f "$tmp"/closed-* "$tmp/claims" "$tmp/attempts"
    timeout 20 "$root/ralph_loop.sh" --agent "$backend" --repo owner/repo --max-tickets 1 >"$tmp/output" 2>&1 \
        || { cat "$tmp/output" >&2; exit 1; }
    [[ $(<"$tmp/claims") == '2' ]]
    [[ $(<"$tmp/attempts") == '2' ]]
    [[ -f "$tmp/closed-2" && ! -f "$tmp/closed-3" && ! -f "$tmp/closed-4" ]]
    ! grep -q '^1$' "$tmp/attempts"
    grep -q 'Maximum ticket count (1) reached' "$tmp/output"

    # Cap 2: the sibling sub-issue fills the second slot; #4 waits.
    rm -f "$tmp"/closed-* "$tmp/claims" "$tmp/attempts"
    timeout 20 "$root/ralph_loop.sh" --agent "$backend" --repo owner/repo --max-tickets 2 >"$tmp/output" 2>&1 \
        || { cat "$tmp/output" >&2; exit 1; }
    [[ $(<"$tmp/claims") == $'2\n3' ]]
    [[ $(<"$tmp/attempts") == $'2\n3' ]]
    [[ -f "$tmp/closed-3" && ! -f "$tmp/closed-4" ]]
    grep -q 'Maximum ticket count (2) reached' "$tmp/output"

    # Unlimited: everything runs and the loop ends by running out of tickets.
    rm -f "$tmp"/closed-* "$tmp/claims" "$tmp/attempts"
    timeout 20 "$root/ralph_loop.sh" --agent "$backend" --repo owner/repo >"$tmp/output" 2>&1 \
        || { cat "$tmp/output" >&2; exit 1; }
    [[ $(<"$tmp/claims") == $'2\n3\n4' ]]
    grep -q "No unblocked, unclaimed 'ready-for-agent' tickets are available" "$tmp/output"
    ! grep -q 'Maximum ticket count' "$tmp/output"

    # --once stops after the first ticket even though more sub-issues remain.
    rm -f "$tmp"/closed-* "$tmp/claims" "$tmp/attempts"
    timeout 20 "$root/ralph_loop.sh" --agent "$backend" --repo owner/repo --once >"$tmp/output" 2>&1 \
        || { cat "$tmp/output" >&2; exit 1; }
    [[ $(<"$tmp/claims") == '2' ]]
    [[ ! -f "$tmp/closed-3" ]]
done

echo 'ok - each sub-issue counts as a separate ticket toward --max-tickets'
