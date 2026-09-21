#!/usr/bin/env bash
# Validate that a labelled GitHub issue frontier is ready for ralph_loop.sh.
set -uo pipefail

usage() {
    cat <<'EOF'
Usage: pre_ralph_validate.sh --label LABEL

Validates executable open tickets carrying LABEL. Parent specification issues
referenced by a ticket's "## Parent" section are ignored.
EOF
}

label=""
while (($#)); do
    case "$1" in
        --label) [[ $# -ge 2 ]] || { echo "error: --label requires a value" >&2; exit 2; }; label=$2; shift 2 ;;
        --help|-h) usage; exit 0 ;;
        *) echo "error: unknown argument: $1" >&2; usage >&2; exit 2 ;;
    esac
done
[[ -n "$label" ]] || { echo "error: --label is required" >&2; usage >&2; exit 2; }

for command in gh jq; do
    command -v "$command" >/dev/null 2>&1 || { echo "error: $command is required but was not found on PATH." >&2; exit 2; }
done

repository=$(gh repo view --json nameWithOwner --jq .nameWithOwner) || exit 2
json=$(gh issue list --repo "$repository" --state open --label "$label" --limit 1000 \
    --json number,title,body,labels,url) || exit 2

parsed_count=$(jq 'length' <<<"$json")
if ((parsed_count == 0)); then
    echo "error: No open tickets carry label '$label' in $repository." >&2
    exit 1
fi

# Match the loop: issues referenced by another issue's ## Parent section are specs.
issues=$(jq '
    [.[].body // "" | capture("(?im)^## Parent\\s*\\r?\\n+\\s*#(?<number>[0-9]+)").number | tonumber] as $parents
    | [.[] | select((.number as $n | $parents | index($n)) == null)]
' <<<"$json") || exit 2
issue_count=$(jq 'length' <<<"$issues")
if ((issue_count == 0)); then
    echo "error: No executable open tickets carry label '$label' in $repository." >&2
    exit 1
fi

ignored_count=$((parsed_count - issue_count))
ignored_text=""
((ignored_count > 0)) && ignored_text=" ($ignored_count parent specification issue(s) ignored)"
echo "Validating $issue_count executable open ticket(s) carrying '$label' in $repository$ignored_text."

failure_count=0
blocked_ticket_count=0
while IFS= read -r issue; do
    number=$(jq -r .number <<<"$issue")
    title=$(jq -r .title <<<"$issue")
    failures=()

    jq -e '[.labels[].name | ascii_downcase] | index("ready-for-agent") != null' <<<"$issue" >/dev/null \
        || failures+=("missing ready-for-agent")

    mapfile -t difficulty_labels < <(jq -r '.labels[].name | select(test("^difficulty[/:]\\s*"; "i"))' <<<"$issue")
    if ((${#difficulty_labels[@]} == 0)); then
        failures+=("missing difficulty label")
    else
        for name in "${difficulty_labels[@]}"; do
            value=$(sed -E 's/^[^:\/]+[:\/]\s*//' <<<"${name,,}")
            [[ "$value" =~ ^(trivial|small|low|medium|large|high|hard)$ ]] \
                || failures+=("unsupported difficulty label '$name'")
        done
    fi

    mapfile -t priority_labels < <(jq -r '.labels[].name | select(test("^(critical|urgent|p0|high|p1|medium|normal|p2|low|p3)$|^priority[/:]\\s*"; "i"))' <<<"$issue")
    if ((${#priority_labels[@]} == 0)); then
        failures+=("missing priority label")
    else
        for name in "${priority_labels[@]}"; do
            if [[ "$name" =~ ^[Pp][Rr][Ii][Oo][Rr][Ii][Tt][Yy][:/] ]]; then
                value=$(sed -E 's/^[^:\/]+[:\/]\s*//' <<<"${name,,}")
                [[ "$value" =~ ^(critical|urgent|p0|high|p1|medium|normal|p2|low|p3|[0-9]+)$ ]] \
                    || failures+=("unsupported priority label '$name'")
            fi
        done
    fi

    blocked_by=$(gh api "repos/$repository/issues/$number" --jq '.issue_dependencies_summary.blocked_by // 0') || exit 2
    ((blocked_by > 0)) && ((++blocked_ticket_count))

    if ((${#failures[@]} == 0)); then
        echo "PASS #$number: $title (blocked by $blocked_by)"
    else
        echo "FAIL #$number: $title" >&2
        for failure in "${failures[@]}"; do echo "  - $failure" >&2; done
        ((failure_count += ${#failures[@]}))
    fi
done < <(jq -c '.[]' <<<"$issues")

if ((blocked_ticket_count == 0)); then
    echo "error: At least one matching ticket must have native GitHub blocked_by metadata." >&2
    ((++failure_count))
fi
if ((failure_count > 0)); then
    echo "error: Validation failed with $failure_count problem(s)." >&2
    exit 1
fi

echo "Validation passed: $issue_count ticket(s), $blocked_ticket_count blocked ticket(s)."
