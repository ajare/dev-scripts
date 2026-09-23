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
    cat <<'JSON'
{"data":{"search":{"nodes":[
  {"number":10,"title":"Closed prerequisite","url":"https://example.test/10","labels":{"nodes":[{"name":"ready-for-agent"},{"name":"feature:test"},{"name":"difficulty:medium"},{"name":"priority:high"}]},"assignees":{"nodes":[]},"blockedBy":{"nodes":[{"number":9,"state":"CLOSED"}]}},
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
