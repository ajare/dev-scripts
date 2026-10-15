#!/usr/bin/env bash
# Hermetic ticket-cap checks, including recovery and the uncapped post-hunt loop.
set -euo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
export DEV_SCRIPTS_TEST_DIR="$tmp" TMPDIR="$tmp" PATH="$tmp:$PATH"
# Keep the scripts outside the target repo, including a space in their path.
script_dir="$tmp/dev scripts"
mkdir -p "$script_dir"
cp "$root/ralph_loop.sh" "$script_dir/ralph_loop.sh"
cat >"$tmp/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case "$*" in
    'api user --jq .login') echo tester ;;
    'issue list '*)
        if [[ "$*" == *'--label bug'* ]]; then numbers='4 5'; else numbers='1 2 3'; fi
        for n in $numbers; do
            printf '{"number":%s,"title":"Ticket %s","labels":[],"assignees":[]}\n' "$n" "$n"
        done | jq -s . ;;
    'api repos/'*) echo 0 ;;
    'issue view '*'--json state --jq .state')
        if [[ -f "$DEV_SCRIPTS_TEST_DIR/closed-$3" ]]; then echo CLOSED; else echo OPEN; fi ;;
    'issue view '*) printf '{"number":%s,"title":"Ticket","body":"","comments":[]}' "$3" ;;
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
# First ticket needs a recovery attempt; neither attempt counts separately.
if [[ "$n" == 1 && ! -f "$DEV_SCRIPTS_TEST_DIR/retried" ]]; then
    touch "$DEV_SCRIPTS_TEST_DIR/retried"
else
    touch "$DEV_SCRIPTS_TEST_DIR/closed-$n"
fi
EOF
cp "$tmp/pi" "$tmp/claude"
cat >"$script_dir/bug_hunt.sh" <<'EOF'
#!/usr/bin/env bash
touch "$DEV_SCRIPTS_TEST_DIR/hunted"
printf '%s\n' "$*" >"$DEV_SCRIPTS_TEST_DIR/hunt-args"
EOF
chmod +x "$tmp/gh" "$tmp/git" "$tmp/pi" "$tmp/claude" "$script_dir/bug_hunt.sh"
root="$script_dir"

for backend in pi claude; do
    for cap in unlimited 1 2 2-hunt 4; do
        rm -f "$tmp"/closed-* "$tmp/attempts" "$tmp/claims" "$tmp/retried" "$tmp/hunted"
        args=(--agent "$backend" --repo owner/repo)
        expected=3
        if [[ "$cap" != unlimited ]]; then
            expected=${cap%-hunt}; ((expected > 3)) && expected=3
            args+=(--max-tickets "${cap%-hunt}")
        fi
        if [[ "$cap" == 4 || "$cap" == 2-hunt ]]; then
            args+=(--bug-hunt test:high --fix-bugs)
            # The bug-fix loop ignores --max-tickets and fixes every bug ticket.
            expected=$((expected + 2))
        fi
        timeout 20 "$root/ralph_loop.sh" "${args[@]}" >"$tmp/output" 2>&1 || { cat "$tmp/output" >&2; exit 1; }
        [[ $(wc -l <"$tmp/claims") -eq $expected ]]
        [[ $(wc -l <"$tmp/attempts") -eq $((expected + 1)) ]]
        if [[ "$cap" == 4 ]]; then [[ -f "$tmp/hunted" && -f "$tmp/closed-5" ]]; fi
        if [[ "$cap" == 2-hunt ]]; then [[ -f "$tmp/hunted" && -f "$tmp/closed-4" && -f "$tmp/closed-5" && ! -f "$tmp/closed-3" ]]; fi
    done
    rm -f "$tmp"/closed-* "$tmp/attempts" "$tmp/claims" "$tmp/retried"
    timeout 20 "$root/ralph_loop.sh" --agent "$backend" --repo owner/repo --max-tickets 2 --once >"$tmp/output" 2>&1
    [[ $(wc -l <"$tmp/claims") -eq 1 ]]

    # --bug-hunt-implemented-only implies the hunt and scopes it to the implemented tickets.
    rm -f "$tmp"/closed-* "$tmp/attempts" "$tmp/claims" "$tmp/retried" "$tmp/hunted" "$tmp/hunt-args"
    timeout 20 "$root/ralph_loop.sh" --agent "$backend" --repo owner/repo \
        --max-tickets 2 --bug-hunt-implemented-only test:high >"$tmp/output" 2>&1 \
        || { cat "$tmp/output" >&2; exit 1; }
    [[ $(<"$tmp/hunt-args") == *'--model test --effort high --publish tracker --tickets 1,2'* ]]

    # It is mutually exclusive with --bug-hunt.
    if "$root/ralph_loop.sh" --agent "$backend" --repo owner/repo \
        --bug-hunt test:high --bug-hunt-implemented-only test:high >"$tmp/output" 2>&1; then
        echo 'accepted --bug-hunt together with --bug-hunt-implemented-only' >&2; exit 1
    else
        [[ $? -eq 2 ]]
        grep -q 'mutually exclusive' "$tmp/output"
    fi

    # It carries its own MODEL:EFFORT, validated like --bug-hunt's.
    if "$root/ralph_loop.sh" --agent "$backend" --repo owner/repo \
        --bug-hunt-implemented-only test >"$tmp/output" 2>&1; then
        echo 'accepted a malformed --bug-hunt-implemented-only spec' >&2; exit 1
    else
        [[ $? -eq 2 ]]
        grep -q -- '--bug-hunt-implemented-only must be in the form MODEL:EFFORT' "$tmp/output"
    fi

    # Nothing implemented: the scoped hunt (and any fix loop) is skipped.
    rm -f "$tmp"/closed-* "$tmp/attempts" "$tmp/claims" "$tmp/retried" "$tmp/hunted" "$tmp/hunt-args"
    touch "$tmp/closed-1" "$tmp/closed-2" "$tmp/closed-3"
    timeout 20 "$root/ralph_loop.sh" --agent "$backend" --repo owner/repo \
        --bug-hunt-implemented-only test:high --fix-bugs >"$tmp/output" 2>&1 \
        || { cat "$tmp/output" >&2; exit 1; }
    [[ ! -f "$tmp/hunted" && ! -f "$tmp/claims" ]]
    grep -q 'skipping the scoped bug hunt' "$tmp/output"
done
for value in 0 -1 1.5 abc '' 01 2147483648 999999999999999999999; do
    if "$root/ralph_loop.sh" --agent pi --max-tickets "$value" >"$tmp/output" 2>&1; then
        echo "accepted invalid cap: $value" >&2; exit 1
    else
        [[ $? -eq 2 ]]
        grep -q 'max-tickets' "$tmp/output"
    fi
done
if "$root/ralph_loop.sh" --agent pi --max-tickets >"$tmp/output" 2>&1; then exit 1; else [[ $? -eq 2 ]]; fi
echo 'ok - maximum tickets, unlimited default, recovery, once, the uncapped post-hunt bug-fix loop, and ticket-scoped hunts'
