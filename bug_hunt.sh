#!/usr/bin/env bash
# Run a thorough, non-interactive bug hunt with pi or Claude Code and publish tickets.
set -uo pipefail

usage() {
    cat <<'EOF'
Usage: bug_hunt.sh --agent {pi|claude} --model MODEL --effort LEVEL --publish {tracker|docs} [options]

Hunts for bugs without implementing fixes. Each credible bug is published as a
separate ticket with bug, difficulty, priority, and ready-for-agent labels.

Required:
  --agent NAME       pi or claude
  --model MODEL      Agent model
  --effort LEVEL     off|minimal|low|medium|high|xhigh|max
  --publish TARGET   tracker to create GitHub issues, or docs to write Markdown
                     tickets under docs/tickets/bug-hunt/

Options:
  --branch-only              Inspect only commits unique to the current branch and the
                             changes introduced by those commits
  --labels LABEL[,LABEL...]  Additional labels for every published ticket; may be repeated
  --help

Environment:
  BUG_HUNT_MEMORY_MAX
                     Memory limit for the agent and all commands it starts when
                     a user systemd instance is available (default: 16G). Set
                     to an empty value to disable the limit.

Examples:
  tools/bug_hunt.sh --agent pi --model openai-codex/gpt-5.6-sol \
    --effort high --publish tracker
  tools/bug_hunt.sh --agent claude --model opus --effort high \
    --publish docs --branch-only
EOF
}

die() { echo "error: $*" >&2; exit 1; }
require_value() { [[ $# -ge 2 ]] || { echo "error: $1 requires a value" >&2; exit 2; }; }

agent="" model="" effort="" publish="" branch_only=0
labels=()
while (($#)); do
    case "$1" in
        --agent) require_value "$@"; agent=$2; shift 2 ;;
        --model) require_value "$@"; model=$2; shift 2 ;;
        --effort) require_value "$@"; effort=$2; shift 2 ;;
        --publish) require_value "$@"; publish=$2; shift 2 ;;
        --branch-only) branch_only=1; shift ;;
        --labels)
            require_value "$@"
            IFS=',' read -ra new_labels <<<"$2"
            for new_label in "${new_labels[@]}"; do
                [[ -z "$new_label" ]] || labels+=("$new_label")
            done
            shift 2 ;;
        --help|-h) usage; exit 0 ;;
        *) echo "error: unknown argument: $1" >&2; usage >&2; exit 2 ;;
    esac
done

[[ "$agent" == pi || "$agent" == claude ]] || { echo "error: --agent must be pi or claude" >&2; exit 2; }
[[ -n "$model" ]] || { echo "error: --model is required" >&2; exit 2; }
[[ -n "$effort" ]] || { echo "error: --effort is required" >&2; exit 2; }
[[ "$effort" =~ ^(off|minimal|low|medium|high|xhigh|max)$ ]] \
    || { echo "error: unsupported --effort '$effort'" >&2; exit 2; }
[[ "$agent" != claude || "$effort" =~ ^(low|medium|high|xhigh|max)$ ]] \
    || { echo "error: effort '$effort' is not supported by claude; use low, medium, high, xhigh, or max" >&2; exit 2; }
[[ "$publish" == tracker || "$publish" == docs ]] \
    || { echo "error: --publish must be tracker or docs" >&2; exit 2; }

for command in git "$agent"; do
    command -v "$command" >/dev/null 2>&1 || die "$command is required but was not found on PATH."
done
if [[ "$agent" == pi ]]; then
    command -v jq >/dev/null 2>&1 || die "jq is required to format Pi's JSON output but was not found on PATH."
fi
if [[ "$publish" == tracker ]]; then
    command -v gh >/dev/null 2>&1 || die "gh is required to publish to the tracker but was not found on PATH."
fi

repo_root=$(git rev-parse --show-toplevel 2>/dev/null) || die "Run this script from inside a Git repository."
cd "$repo_root" || exit 1
log_directory="${TMPDIR:-/tmp}/$agent-bug-hunt"
mkdir -p "$log_directory"

scope_prompt="Review the entire codebase."
if ((branch_only)); then
    current_branch=$(git symbolic-ref --quiet --short HEAD) \
        || die "--branch-only requires a checked-out branch (HEAD is detached)."
    default_ref=$(git symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || true)
    if [[ -z "$default_ref" ]] && command -v gh >/dev/null 2>&1; then
        default_branch=$(gh repo view --json defaultBranchRef --jq '.defaultBranchRef.name' 2>/dev/null || true)
        [[ -z "$default_branch" ]] || default_ref="origin/$default_branch"
    fi
    [[ -n "$default_ref" ]] \
        || die "Could not determine the default branch from origin/HEAD or GitHub."
    git rev-parse --verify "$default_ref^{commit}" >/dev/null 2>&1 \
        || die "Default branch ref '$default_ref' is not available locally."
    merge_base=$(git merge-base HEAD "$default_ref") \
        || die "Current branch and '$default_ref' have no merge base."
    commit_range="$default_ref..HEAD"
    unique_count=$(git rev-list --count "$commit_range") || exit 1
    scope_prompt=$(cat <<EOF
Confine the hunt to commits unique to the current branch '$current_branch' and to bugs introduced by their changes. The default branch ref is '$default_ref', the merge base is '$merge_base', and the unique commit range is '$commit_range' ($unique_count commits). Start with \`git log $commit_range\` and \`git diff $merge_base..HEAD\`. You may inspect surrounding code and run focused tests only to understand or prove those changes, but do not report pre-existing bugs outside this branch scope.
EOF
)
fi

if [[ "$publish" == tracker ]]; then
    publish_prompt=$(cat <<'EOF'
Publish every ticket to this repository's GitHub issue tracker with `gh`; do not merely propose issue text in your response. Before publishing, inspect open and closed issues to avoid duplicates and inspect the repository's available labels. Apply exactly one existing `difficulty:*` label and exactly one existing `priority:*` label, plus `bug` and `ready-for-agent`, to every issue. If one new issue depends on another, create them in dependency order and set GitHub's native blocked-by relationship (`blockedBy`) on the dependent issue. A body link or textual "blocked by" note alone is not sufficient. Verify the final labels and native dependency metadata after creation.
EOF
)
else
    publish_prompt=$(cat <<'EOF'
Publish every ticket as a separate Markdown file under `docs/tickets/bug-hunt/`; do not create GitHub issues. Create the directory if needed, inspect existing tickets to avoid duplicates, and use stable, descriptive kebab-case filenames. Begin each file with YAML front matter containing `labels` with `bug`, exactly one `difficulty:*`, exactly one `priority:*`, and `ready-for-agent`. Include a `blockedBy` list containing the relative filenames of prerequisite tickets (or an empty list) so all dependencies are explicit and machine-readable. Do not modify files outside `docs/tickets/bug-hunt/`.
EOF
)
fi

if ((${#labels[@]})); then
    publish_prompt+=$'\n\nApply each of these additional labels to every published ticket (without duplicating labels):'
    for label in "${labels[@]}"; do
        publish_prompt+=$'\n'"- $label"
    done
fi

prompt=$(cat <<EOF
Perform a thorough bug hunt of this repository. You are running non-interactively: work autonomously, carry the investigation through publication, and do not stop at a plan or ask the user questions. Read and follow all repository instructions, domain documentation, and relevant ADRs before investigating.

$scope_prompt

Use code inspection, history, lightweight static analysis, and focused tests or builds where useful. Look for concrete correctness, safety, state-management, concurrency, persistence, error-handling, boundary-condition, and regression bugs. Trace behavior across call sites and test assumptions rather than relying on superficial pattern matching. Do not implement fixes and do not modify source code. Do not publish speculative concerns, style suggestions, refactors, feature requests, or test-only gaps unless they demonstrate a real product bug.

Keep every individual build, test, or analysis tool call bounded to at most 300 seconds and stream periodic progress to the tool output; do not hide all output in a file. Do not run GCC's \`-fanalyzer\`, Clang Static Analyzer, or another whole-project path-sensitive compiler analysis: these can consume unbounded time and memory on this codebase. Prefer the repository's normal build and focused test targets. If a command approaches its bound or shows pathological resource use, stop it and continue with other evidence.

For each distinct, credible bug, write a self-contained implementation-ready ticket containing:
- a precise title and concise impact summary;
- the affected files/symbols and evidence or reproduction steps;
- expected versus actual behavior and the likely root cause;
- focused acceptance criteria, including regression-test expectations;
- one estimated difficulty label from difficulty:trivial, difficulty:easy, difficulty:medium, or difficulty:hard;
- one priority label from priority:low, priority:medium, or priority:high.

Split independently fixable bugs into separate tickets. Combine only when one fix necessarily resolves the same root cause. Model dependencies only where work genuinely must be completed in order, and ensure every dependent ticket's blockedBy metadata is set correctly. If no credible bugs are found, publish nothing and report that result clearly.

$publish_prompt

At the end, summarize the investigation performed and list the tickets actually published, including their URLs or file paths and dependency relationships.
EOF
)

if [[ "$agent" == pi ]]; then
    # JSON mode emits one line per session event as it occurs, so tee persists
    # model output to the log throughout the run instead of only at completion.
    agent_args=(--mode json --print --approve --model "$model" --thinking "$effort" --name bug-hunt "$prompt")
else
    agent_args=(--print --dangerously-skip-permissions --model "$model" --effort "$effort" "$prompt")
fi

timestamp=$(date +%Y%m%d-%H%M%S)
log_path="$log_directory/bug-hunt-$timestamp.log"
echo "Starting $agent bug hunt. Log: $log_path"

# Pi starts each shell tool in a detached process group. If the non-interactive
# agent is interrupted, those groups can outlive both Pi and this script. A
# transient systemd scope gives us one boundary that detached descendants cannot
# escape and also keeps pathological analysis commands from exhausting the host.
scope_unit=""
cleanup_scope() {
    if [[ -n "$scope_unit" ]]; then
        systemctl --user stop "$scope_unit" >/dev/null 2>&1 || true
        scope_unit=""
    fi
}
exit_on_signal() {
    local status=$1
    trap - EXIT INT TERM HUP
    cleanup_scope
    exit "$status"
}
trap cleanup_scope EXIT
trap 'exit_on_signal 130' INT
trap 'exit_on_signal 143' TERM
trap 'exit_on_signal 129' HUP

memory_max=${BUG_HUNT_MEMORY_MAX-16G}
output_formatter=(cat)
if [[ "$agent" == pi ]]; then
    # Parse each JSONL event independently so output remains live. Non-JSON
    # diagnostics from stderr pass through unchanged instead of terminating jq.
    output_formatter=(jq --raw-input --raw-output --unbuffered 'fromjson? // .')
fi
if command -v systemd-run >/dev/null 2>&1 \
    && command -v systemctl >/dev/null 2>&1 \
    && systemctl --user show-environment >/dev/null 2>&1; then
    scope_unit="$agent-bug-hunt-$timestamp-$$.scope"
    scope_args=(
        --user --scope --quiet --collect
        --unit "$scope_unit"
        --property KillMode=control-group
    )
    if [[ -n "$memory_max" ]]; then
        scope_args+=(--property "MemoryMax=$memory_max" --property MemorySwapMax=0)
    fi
    systemd-run "${scope_args[@]}" -- "$agent" "${agent_args[@]}" 2>&1 \
        | tee "$log_path" \
        | "${output_formatter[@]}" &
else
    echo "warning: user systemd is unavailable; detached agent commands cannot be resource-isolated." >&2
    "$agent" "${agent_args[@]}" 2>&1 \
        | tee "$log_path" \
        | "${output_formatter[@]}" &
fi
# Waiting through the shell builtin lets the signal traps run immediately. Bash
# otherwise defers a trap while a foreground pipeline is still running.
pipeline_pid=$!
wait "$pipeline_pid"
agent_status=$?
cleanup_scope
trap - EXIT INT TERM HUP
exit "$agent_status"
