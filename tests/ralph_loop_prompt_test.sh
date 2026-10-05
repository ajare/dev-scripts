#!/usr/bin/env bash
# Hermetic live-loop prompt checks: no GitHub calls or real agents.
set -euo pipefail
script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
export DEV_SCRIPTS_TEST_DIR="$tmp" TMPDIR="$tmp"
export PATH="$tmp:$PATH"

cat >"$tmp/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
count=$(cat "$DEV_SCRIPTS_TEST_DIR/count" 2>/dev/null || echo 0)
case "$*" in
    'api user --jq .login') echo tester ;;
    'issue list '*) echo '[{"number":10,"title":"Ticket 10","labels":[{"name":"ready-for-agent"},{"name":"difficulty:medium"},{"name":"priority:high"}],"assignees":[]}]' ;;
    'api repos/'*) echo 0 ;;
    'issue view '*'--json state --jq .state')
        if [[ "${TEST_MODE:-}" == stale ]] || ((count >= 2)); then echo CLOSED; else echo OPEN; fi ;;
    'issue view '*) echo '{"number":10,"title":"Ticket 10","url":"https://example.test/10","body":"","comments":[]}' ;;
    'issue edit '*) ;;
    *) echo "unexpected gh: $*" >&2; exit 99 ;;
esac
EOF
cat >"$tmp/git" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case "$*" in
    'rev-parse --show-toplevel') echo "$DEV_SCRIPTS_TEST_DIR" ;;
    'status '*)
        count=$(cat "$DEV_SCRIPTS_TEST_DIR/count" 2>/dev/null || echo 0)
        if [[ "${TEST_MODE:-}" == dirty ]] && ((count == 2)); then echo ' M tracked.txt'; fi ;;
    # Completion must not require a new commit (already-implemented work).
    'rev-parse HEAD') echo old-head ;;
    *) echo "unexpected git: $*" >&2; exit 99 ;;
esac
EOF
cat >"$tmp/pi" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
count=$(cat "$DEV_SCRIPTS_TEST_DIR/count" 2>/dev/null || echo 0)
count=$((count + 1))
echo "$count" >"$DEV_SCRIPTS_TEST_DIR/count"
printf '%s' "${!#}" >"$DEV_SCRIPTS_TEST_DIR/prompt-$count.txt"
if ((count == 1)) && [[ "$FIRST_RESULT" == provider ]]; then
    echo 'HTTP 503 service unavailable'
    exit 1
fi
EOF
cp "$tmp/pi" "$tmp/claude"
chmod +x "$tmp/gh" "$tmp/git" "$tmp/pi" "$tmp/claude"

assert_contains() {
    if ! grep -Fq -- "$2" "$1"; then
        echo "missing prompt policy in $1: $2" >&2
        exit 1
    fi
}
assert_policy() {
    local prompt=$1
    assert_contains "$prompt" '1. Inner development loop: incrementally build only the changed targets and required dependencies'
    assert_contains "$prompt" 'specific new, affected, or failing checks'
    assert_contains "$prompt" 'Do not routinely run whole-project builds or full regression suites after every edit'
    assert_contains "$prompt" '2. Feature milestones:'
    assert_contains "$prompt" 'affected modules and relevant integration/contract coverage'
    assert_contains "$prompt" 'Broaden validation when shared code or cross-module dependencies warrant it'
    assert_contains "$prompt" '3. Before completion: perform the repository-required full validation matrix on the final source state'
    assert_contains "$prompt" 'one successful final validation pass per required configuration'
    assert_contains "$prompt" 'Repository instructions and ticket acceptance criteria take precedence; staging must not omit required coverage'
    assert_contains "$prompt" "Use the repository's supported configurations, commands, and validation scripts"
    assert_contains "$prompt" 'do not impose CMake/CTest or Debug/Release on repositories that do not require them'
    assert_contains "$prompt" 'Reuse compatible build directories and incremental outputs; do not clean or reconfigure unnecessarily'
    assert_contains "$prompt" 'After a validation failure, use focused checks for the repair loop before returning to the required final validation'
    assert_contains "$prompt" 'Validation evidence must match the final source state:'
    assert_contains "$prompt" 'invalidate and rerun the relevant coverage; do not treat an earlier pass as final verification'
    assert_contains "$prompt" 'Ensure that all tests are headless'
    assert_contains "$prompt" 'Preserve unrelated and pre-existing untracked files'
    assert_contains "$prompt" 'Close #10 with a concise comment containing the commit hash and validation performed'
    assert_contains "$prompt" 'leave the issue open, do not commit partial work'
}

for backend in pi claude; do
    for result in recovery provider; do
        rm -f "$tmp/count" "$tmp"/prompt-*.txt
        FIRST_RESULT=$result "$script_dir/ralph_loop.sh" --agent "$backend" \
            --repo owner/repo --once --quiet --initial-retry-interval-seconds 1 >"$tmp/output" 2>&1 || {
                cat "$tmp/output" >&2
                exit 1
            }
        [[ $(<"$tmp/count") == 2 ]]
        assert_policy "$tmp/prompt-1.txt"
        assert_policy "$tmp/prompt-2.txt"
        if [[ "$result" == provider ]]; then
            cmp "$tmp/prompt-1.txt" "$tmp/prompt-2.txt"
        else
            initial=$(<"$tmp/prompt-1.txt")
            retry=$(<"$tmp/prompt-2.txt")
            [[ "$retry" == "$initial"$'\n\n## Recovery attempt\n'* ]]
        fi
    done
done

for backend in pi claude; do
    # A permanently stale listing must terminate without claiming or launching.
    rm -f "$tmp/count" "$tmp"/prompt-*.txt
    TEST_MODE=stale timeout 10 "$script_dir/ralph_loop.sh" --agent "$backend" \
        --repo owner/repo --quiet >"$tmp/output" 2>&1
    [[ ! -f "$tmp/count" ]]

    # Also suppress stale re-selection after this run closes the ticket.
    TEST_MODE=normal FIRST_RESULT=recovery timeout 10 "$script_dir/ralph_loop.sh" --agent "$backend" \
        --repo owner/repo --quiet >"$tmp/output" 2>&1
    [[ $(<"$tmp/count") == 2 ]]

    # Closed is not sufficient when tracked changes remain; explain that reason.
    rm -f "$tmp/count" "$tmp"/prompt-*.txt
    TEST_MODE=dirty FIRST_RESULT=recovery timeout 10 "$script_dir/ralph_loop.sh" --agent "$backend" \
        --repo owner/repo --once --quiet >"$tmp/output" 2>&1
    [[ $(<"$tmp/count") == 3 ]]
    assert_contains "$tmp/prompt-2.txt" 'Completion check: Issue state is OPEN, not CLOSED.'
    assert_contains "$tmp/prompt-3.txt" 'Completion check: Issue is closed but the tracked worktree is dirty.'
    if grep -Fq 'without closing ticket' "$tmp/prompt-3.txt"; then exit 1; fi
done

echo 'ok - staged prompts, stale listings, unchanged HEAD, and accurate recovery checks for pi/Claude'
