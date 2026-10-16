#!/usr/bin/env bash
# Hermetic bug-hunt scope checks: --tickets confines the hunt to ticket commits.
set -euo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
export DEV_SCRIPTS_TEST_DIR="$tmp" TMPDIR="$tmp"
mkdir -p "$tmp/bin" "$tmp/agentbin"

cat >"$tmp/bin/git" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case "$1" in
    rev-parse)
        if [[ "$*" == *show-toplevel ]]; then echo "$DEV_SCRIPTS_TEST_DIR"; else echo commithash; fi ;;
    symbolic-ref)
        if [[ "$*" == *refs/remotes/origin/HEAD ]]; then echo origin/main; else echo feature/test; fi ;;
    merge-base) echo base123 ;;
    rev-list) echo 4 ;;
    log)
        grep_arg=""
        for a in "$@"; do [[ "$a" == --grep=* ]] && grep_arg=${a#--grep=}; done
        ticket=${grep_arg#\#}; ticket=${ticket%%(*}
        cat "$DEV_SCRIPTS_TEST_DIR/log-$ticket" 2>/dev/null || true ;;
    *) echo "unexpected git: $*" >&2; exit 99 ;;
esac
EOF
cat >"$tmp/agentbin/pi" <<'EOF'
#!/usr/bin/env bash
printf '%s' "${!#}" >"$DEV_SCRIPTS_TEST_DIR/hunt-prompt"
EOF
cp "$tmp/agentbin/pi" "$tmp/agentbin/claude"
cp "$tmp/agentbin/pi" "$tmp/bin/pi"
cp "$tmp/agentbin/claude" "$tmp/bin/claude"
chmod +x "$tmp/bin/git" "$tmp/bin/pi" "$tmp/bin/claude" "$tmp/agentbin/pi" "$tmp/agentbin/claude"

assert_contains() {
    if ! grep -Fq -- "$2" "$1"; then
        echo "missing in $1: $2" >&2
        exit 1
    fi
}

printf 'abc1234 Implement the thing (#7)\n' >"$tmp/log-7"
printf 'def5678 Follow-up work (#9)\n' >"$tmp/log-9"

# A scoped hunt lists each ticket's commits and stays off the whole codebase.
rm -f "$tmp/hunt-prompt"
PATH="$tmp/bin:$PATH" "$root/bug_hunt.sh" --agent pi --model test/model \
    --effort high --publish docs --tickets 7,9 >"$tmp/output" 2>&1 \
    || { cat "$tmp/output" >&2; exit 1; }
assert_contains "$tmp/hunt-prompt" 'Confine the hunt to bugs introduced by the changes implemented for these tickets: #7, #9.'
assert_contains "$tmp/hunt-prompt" 'found by searching HEAD for commit messages referencing each ticket number'
assert_contains "$tmp/hunt-prompt" '- #7: abc1234 Implement the thing (#7)'
assert_contains "$tmp/hunt-prompt" '- #9: def5678 Follow-up work (#9)'
assert_contains "$tmp/hunt-prompt" 'Start with `git show` on these commits'
assert_contains "$tmp/hunt-prompt" 'Apply the label "assignee:test/model" to every published ticket (in YAML front matter for docs).'
assert_contains "$tmp/hunt-prompt" 'create this label with gh label create --force if it does not exist'
if grep -Fq 'Review the entire codebase.' "$tmp/hunt-prompt"; then
    echo 'scoped hunt fell back to the whole-codebase prompt' >&2
    exit 1
fi

# The option may be repeated and combines with --branch-only.
rm -f "$tmp/hunt-prompt"
PATH="$tmp/bin:$PATH" "$root/bug_hunt.sh" --agent claude --model opus \
    --effort high --publish docs --branch-only --tickets 7 --tickets 9 >"$tmp/output" 2>&1 \
    || { cat "$tmp/output" >&2; exit 1; }
assert_contains "$tmp/hunt-prompt" "found by searching 'origin/main..HEAD' (commits unique to branch 'feature/test')"
assert_contains "$tmp/hunt-prompt" '- #9: def5678 Follow-up work (#9)'

# No matching commits: report the empty scope without launching an agent.
rm -f "$tmp/hunt-prompt"
PATH="$tmp/bin:$PATH" "$root/bug_hunt.sh" --agent pi --model test/model \
    --effort high --publish docs --tickets 77 >"$tmp/output" 2>&1 \
    || { cat "$tmp/output" >&2; exit 1; }
grep -q 'No commits in HEAD reference tickets #77; nothing to hunt.' "$tmp/output"
[[ ! -f "$tmp/hunt-prompt" ]]

# Ticket numbers must be positive integers.
if PATH="$tmp/bin:$PATH" "$root/bug_hunt.sh" --agent pi --model test/model \
    --effort high --publish docs --tickets 7,abc >"$tmp/output" 2>&1; then
    echo 'accepted an invalid ticket number' >&2
    exit 1
else
    [[ $? -eq 2 ]]
    grep -q 'tickets entries must be positive integers' "$tmp/output"
fi

# Against a real repository, #1 must not also match #10.
repo="$tmp/repo"
mkdir "$repo"
git -C "$repo" init -q
git -C "$repo" commit -q --allow-empty -m 'first change (#1)'
git -C "$repo" commit -q --allow-empty -m 'unrelated change (#10)'
rm -f "$tmp/hunt-prompt"
(cd "$repo" && PATH="$tmp/agentbin:$PATH" "$root/bug_hunt.sh" --agent pi \
    --model test/model --effort high --publish docs --tickets 1 >"$tmp/output" 2>&1) \
    || { cat "$tmp/output" >&2; exit 1; }
assert_contains "$tmp/hunt-prompt" '- #1: '
assert_contains "$tmp/hunt-prompt" 'first change (#1)'
if grep -Fq 'unrelated change (#10)' "$tmp/hunt-prompt"; then
    echo 'ticket #1 scope leaked the #10 commit' >&2
    exit 1
fi

echo 'ok - ticket-scoped bug hunts, branch combination, empty scope, and ticket-number boundaries'
