#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

cat >"$tmp/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "$*" == "api user --jq .login" ]]; then
    echo tester
elif [[ "$*" == "api graphql --input -" ]]; then
    cat >/dev/null
    if [[ ${DRY_RUN_EMPTY:-0} == 1 ]]; then
        echo '{"data":{"search":{"nodes":[]}}}'
        exit 0
    fi
    cat <<'JSON'
{"data":{"search":{"nodes":[
  {"number":10,"title":"Closed prerequisite","url":"https://example.test/10","labels":{"nodes":[{"name":"ready-for-agent"},{"name":"feature:test"},{"name":"difficulty:medium"},{"name":"priority:high"}]},"assignees":{"nodes":[]},"blockedBy":{"nodes":[{"number":9,"state":"CLOSED"}]}},
  {"number":12,"title":"Dependent ticket","url":"https://example.test/12","labels":{"nodes":[]},"assignees":{"nodes":[]},"blockedBy":{"nodes":[{"number":10,"state":"OPEN"}]}},
  {"number":11,"title":"Open external prerequisite","url":"https://example.test/11","labels":{"nodes":[{"name":"ready-for-agent"},{"name":"feature:test"},{"name":"difficulty:medium"},{"name":"priority:high"}]},"assignees":{"nodes":[]},"blockedBy":{"nodes":[{"number":8,"state":"OPEN"}]}}
]}}}
JSON
else
    echo "unexpected gh invocation: $*" >&2
    exit 1
fi
EOF
chmod +x "$tmp/gh"

output=$(PATH="$tmp:$PATH" "$script_dir/ralph_loop.sh" \
    --agent pi --repo owner/repo --labels feature:test --dry-run)

if ! grep -Eq '^1 +#10 ' <<<"$output"; then
    echo "expected ticket #10, whose only blocker is closed, to be runnable" >&2
    echo "$output" >&2
    exit 1
fi
if ! grep -Eq '^ +#11 +blocked by #8 \(outside label filter\)$' <<<"$output"; then
    echo "expected ticket #11's open external blocker to remain visible" >&2
    echo "$output" >&2
    exit 1
fi
if grep -q '#9 (outside label filter)' <<<"$output"; then
    echo "closed blocker #9 must not be reported as active" >&2
    echo "$output" >&2
    exit 1
fi

echo "ok - dry run ignores closed blockers"

for cap in 1 2 3; do
    output=$(PATH="$tmp:$PATH" "$script_dir/ralph_loop.sh" \
        --agent pi --repo owner/repo --labels feature:test --dry-run --max-tickets "$cap")
    expected=$cap
    ((expected > 2)) && expected=2
    count=$(grep -Ec '^[0-9]+ +#[0-9]+ ' <<<"$output")
    if [[ "$count" -ne "$expected" ]]; then
        echo "expected $expected dry-run rows with cap $cap, got $count" >&2
        echo "$output" >&2
        exit 1
    fi
    grep -Eq '^1 +#10 ' <<<"$output"
    if ((cap == 1)); then
        ! grep -Eq '#(11|12) ' <<<"$output"
    else
        grep -Eq '^2 +#12 ' <<<"$output"
    fi
    if ((cap <= 2)); then
        ! grep -q 'Not runnable\|Nothing stranded' <<<"$output"
        grep -q "Maximum ticket count ($cap) reached" <<<"$output"
    else
        grep -Eq '^ +#11 +blocked by #8' <<<"$output"
    fi
done

echo "ok - dry run respects max tickets and dependency order"

# Every post-loop option is previewed even when the ticket listing hits its cap.
# Fail immediately if a dry-run accidentally launches an agent.
printf '#!/usr/bin/env bash\nexit 99\n' >"$tmp/pi"
cp "$tmp/pi" "$tmp/claude"
chmod +x "$tmp/pi" "$tmp/claude"
for backend in pi claude; do
    output=$(PATH="$tmp:$PATH" "$script_dir/ralph_loop.sh" \
        --agent "$backend" --repo owner/repo --dry-run --max-tickets 1 \
        --bug-hunt hunt/model:high --fix-bugs --model fix/model --effort medium \
        --difficulty-override easy=override/model:high --use-branch feature/test \
        --labels feature:test --once)
    grep -Fq "Bug hunt: $backend; model 'hunt/model'; effort 'high'" <<<"$output"
    grep -Fq 'Scope: all commits' <<<"$output"
    grep -Fq "Branch filter: current branch 'feature/test' only" <<<"$output"
    grep -Fq 'Labels on filed bugs: feature:test.' <<<"$output"
    grep -Fq "Bug-fix loop: after a successful hunt; $backend" <<<"$output"
    grep -Fq "fixed at 'fix/model' / 'medium' (not the hunt model)" <<<"$output"
    grep -Fq 'Difficulty overrides apply: easy=override/model:high.' <<<"$output"
    grep -Fq 'ignores --max-tickets' <<<"$output"
    grep -Fq -- '--once: fixes at most one bug ticket.' <<<"$output"

    output=$(PATH="$tmp:$PATH" "$script_dir/ralph_loop.sh" \
        --agent "$backend" --repo owner/repo --dry-run \
        --bug-hunt-implemented-only hunt/model:high --fix-bugs \
        --adaptive-model-and-effort --difficulty-override hard=custom/model:xhigh)
    grep -Fq 'tickets actually completed by the initial loop' <<<"$output"
    grep -Fq 'skip hunt and fixes if none complete' <<<"$output"
    grep -Fq "adaptive from each bug ticket's difficulty label" <<<"$output"
    grep -Fq 'hard: custom/model / xhigh' <<<"$output"

    output=$(PATH="$tmp:$PATH" "$script_dir/ralph_loop.sh" \
        --agent "$backend" --repo owner/repo --dry-run --bug-hunt hunt/model:high)
    grep -Fq 'findings are filed but not automatically fixed' <<<"$output"
done

# Empty search results still show the hunt plan. Unexpected mutation/agent calls
# fail through the gh or agent stubs.
export DRY_RUN_EMPTY=1
output=$(PATH="$tmp:$PATH" "$script_dir/ralph_loop.sh" \
    --agent pi --repo owner/repo --dry-run --bug-hunt-implemented-only hunt/model:high --fix-bugs)
grep -Fq 'No open tickets match' <<<"$output"
grep -Fq 'skip hunt and fixes if none complete' <<<"$output"
output=$(PATH="$tmp:$PATH" "$script_dir/ralph_loop.sh" \
    --agent pi --repo owner/repo --dry-run --fix-bugs 2>&1)
grep -Fq -- '--fix-bugs has no effect without a bug hunt' <<<"$output"
grep -Fq 'Bug hunt: disabled. Bug-fix loop: disabled' <<<"$output"
echo 'ok - dry run previews hunt scope, models, fix policy, limits, and empty results'
