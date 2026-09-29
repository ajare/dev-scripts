# Native Windows port of bug_hunt.sh. Invoke with /agent, /model, etc.
. "$PSScriptRoot/windows_common.ps1"
function Show-Usage {
    Write-Host @'
Usage: bug_hunt.ps1 /agent {pi|claude} /model MODEL /effort LEVEL /publish {tracker|docs} [options]

Hunts for bugs without implementing fixes. Each credible bug is published as a
separate ticket with bug, difficulty, priority, and ready-for-agent labels.

Required:
  /agent NAME       pi or claude
  /model MODEL      Agent model
  /effort LEVEL     off|minimal|low|medium|high|xhigh|max
  /publish TARGET   tracker to create GitHub issues, or docs to write Markdown
                    tickets under docs/tickets/bug-hunt/
Options:
  /branch-only              Inspect only commits unique to the current branch
  /labels LABEL[,LABEL...]  Additional labels for every ticket; may be repeated
  /help
Environment:
  BUG_HUNT_MEMORY_MAX       Combined agent/descendant memory limit (default: 16G).
                            Set to 0 to disable the memory limit.
                            A Windows Job Object cleans up detached descendants.
Examples:
  .\bug_hunt.ps1 /agent pi /model openai-codex/gpt-5.6-sol /effort high /publish tracker
  .\bug_hunt.ps1 /agent claude /model opus /effort high /publish docs /branch-only
'@
}
$options = Read-Options $args @('/agent', '/model', '/effort', '/publish', '/labels') @('/branch-only') ${function:Show-Usage}
$agent = Get-Option $options '/agent'
$model = Get-Option $options '/model'
$effort = Get-Option $options '/effort'
$publish = Get-Option $options '/publish'
Assert-Agent $agent $effort
if (!$model) { Stop-Script '/model is required' 2 }
if ($publish -cnotin @('tracker', 'docs')) { Stop-Script '/publish must be tracker or docs' 2 }
Require-Commands @('git', $agent)
if ($publish -eq 'tracker') { Require-Commands @('gh') }
$originalLocation = Get-Location
try {
    $repoRoot = Enter-Repository
    $logDirectory = New-LogDirectory "$agent-bug-hunt"
    $scopePrompt = 'Review the entire codebase.'
    if ($options.ContainsKey('/branch-only')) {
        $branch = Invoke-Native git @('symbolic-ref', '--quiet', '--short', 'HEAD')
        if ($branch.Code -ne 0) { Stop-Script '/branch-only requires a checked-out branch (HEAD is detached).' }
        $currentBranch = $branch.Text.Trim()
        $ref = Invoke-Native git @('symbolic-ref', '--quiet', '--short', 'refs/remotes/origin/HEAD')
        $defaultRef = if ($ref.Code -eq 0) { $ref.Text.Trim() } else { '' }
        if (!$defaultRef -and (Get-Command gh -CommandType Application -ErrorAction SilentlyContinue)) {
            $ref = Invoke-Native gh @('repo', 'view', '--json', 'defaultBranchRef', '--jq', '.defaultBranchRef.name')
            if ($ref.Code -eq 0 -and $ref.Text.Trim()) { $defaultRef = 'origin/' + $ref.Text.Trim() }
        }
        if (!$defaultRef) { Stop-Script 'Could not determine the default branch from origin/HEAD or GitHub.' }
        $ref = Invoke-Native git @('rev-parse', '--verify', "$defaultRef^{commit}")
        if ($ref.Code -ne 0) { Stop-Script "Default branch ref '$defaultRef' is not available locally." }
        $base = Invoke-Native git @('merge-base', 'HEAD', $defaultRef)
        if ($base.Code -ne 0) { Stop-Script "Current branch and '$defaultRef' have no merge base." }
        $mergeBase = $base.Text.Trim()
        $commitRange = "$defaultRef..HEAD"
        $uniqueCount = Invoke-Checked git @('rev-list', '--count', $commitRange)
        $scopePrompt = @"
Confine the hunt to commits unique to the current branch '$currentBranch' and to bugs introduced by their changes. The default branch ref is '$defaultRef', the merge base is '$mergeBase', and the unique commit range is '$commitRange' ($uniqueCount commits). Start with ``git log $commitRange`` and ``git diff $mergeBase..HEAD``. You may inspect surrounding code and run focused tests only to understand or prove those changes, but do not report pre-existing bugs outside this branch scope.
"@
    }
    if ($publish -eq 'tracker') {
        $publishPrompt = @'
Publish every ticket to this repository's GitHub issue tracker with `gh`; do not merely propose issue text in your response. Before publishing, inspect open and closed issues to avoid duplicates and inspect the repository's available labels. Apply exactly one existing `difficulty:*` label and exactly one existing `priority:*` label, plus `bug` and `ready-for-agent`, to every issue. If one new issue depends on another, create them in dependency order and set GitHub's native blocked-by relationship (`blockedBy`) on the dependent issue. A body link or textual "blocked by" note alone is not sufficient. Verify the final labels and native dependency metadata after creation.
'@
    } else {
        $publishPrompt = @'
Publish every ticket as a separate Markdown file under `docs/tickets/bug-hunt/`; do not create GitHub issues. Create the directory if needed, inspect existing tickets to avoid duplicates, and use stable, descriptive kebab-case filenames. Begin each file with YAML front matter containing `labels` with `bug`, exactly one `difficulty:*`, exactly one `priority:*`, and `ready-for-agent`. Include a `blockedBy` list containing the relative filenames of prerequisite tickets (or an empty list) so all dependencies are explicit and machine-readable. Do not modify files outside `docs/tickets/bug-hunt/`.
'@
    }
    $labels = @(Get-Labels $options)
    if ($labels.Count) {
        $publishPrompt += "`n`nApply each of these additional labels to every published ticket (without duplicating labels):"
        foreach ($label in $labels) { $publishPrompt += "`n- $label" }
    }
    $prompt = @"
Perform a thorough bug hunt of this repository. You are running non-interactively: work autonomously, carry the investigation through publication, and do not stop at a plan or ask the user questions. Read and follow all repository instructions, domain documentation, and relevant ADRs before investigating.

$scopePrompt

Use code inspection, history, lightweight static analysis, and focused tests or builds where useful. Look for concrete correctness, safety, state-management, concurrency, persistence, error-handling, boundary-condition, and regression bugs. Trace behavior across call sites and test assumptions rather than relying on superficial pattern matching. Do not implement fixes and do not modify source code. Do not publish speculative concerns, style suggestions, refactors, feature requests, or test-only gaps unless they demonstrate a real product bug.

Keep every individual build, test, or analysis tool call bounded to at most 300 seconds and stream periodic progress to the tool output; do not hide all output in a file. Do not run GCC's ``-fanalyzer``, Clang Static Analyzer, or another whole-project path-sensitive compiler analysis: these can consume unbounded time and memory on this codebase. Prefer the repository's normal build and focused test targets. If a command approaches its bound or shows pathological resource use, stop it and continue with other evidence.

For each distinct, credible bug, write a self-contained implementation-ready ticket containing:
- a precise title and concise impact summary;
- the affected files/symbols and evidence or reproduction steps;
- expected versus actual behavior and the likely root cause;
- focused acceptance criteria, including regression-test expectations;
- one estimated difficulty label from difficulty:trivial, difficulty:easy, difficulty:medium, or difficulty:hard;
- one priority label from priority:low, priority:medium, or priority:high.

Split independently fixable bugs into separate tickets. Combine only when one fix necessarily resolves the same root cause. Model dependencies only where work genuinely must be completed in order, and ensure every dependent ticket's blockedBy metadata is set correctly. If no credible bugs are found, publish nothing and report that result clearly.

$publishPrompt

At the end, summarize the investigation performed and list the tickets actually published, including their URLs or file paths and dependency relationships.
"@
    if ($agent -eq 'pi') {
        $agentArgs = @('--mode', 'json', '--print', '--approve', '--model', $model, '--thinking', $effort, '--name', 'bug-hunt')
    } else {
        $agentArgs = @('--print', '--dangerously-skip-permissions', '--model', $model, '--effort', $effort)
    }
    $memorySpec = [Environment]::GetEnvironmentVariable('BUG_HUNT_MEMORY_MAX')
    if ($null -eq $memorySpec) { $memorySpec = '16G' }
    [UInt64]$memory = 0
    if ($memorySpec) {
        if ($memorySpec -notmatch '^(\d+(?:\.\d+)?)\s*([KMGTPE]?)(?:i?B)?$') { Stop-Script "Invalid BUG_HUNT_MEMORY_MAX '$memorySpec'." }
        $power = @('', 'K', 'M', 'G', 'T', 'P', 'E').IndexOf($Matches[2].ToUpperInvariant())
        $memory = [UInt64]([double]$Matches[1] * [Math]::Pow(1024, $power))
    }
    $logPath = Join-Path $logDirectory ('bug-hunt-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.log')
    Write-Host "Starting $agent bug hunt. Log: $logPath"
    $result = Invoke-Native $agent $agentArgs -InputText $prompt -LogPath $logPath -Live -JsonLines:($agent -eq 'pi') -Contained -Memory $memory
    exit $result.Code
} finally { Set-Location -LiteralPath $originalLocation.Path }
