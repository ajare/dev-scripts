# Native Windows port of pre_ralph_validate.sh.
. "$PSScriptRoot/windows_common.ps1"
function Show-Usage {
    Write-Host @'
Usage: pre_ralph_validate.ps1 /label LABEL

Validates executable open tickets carrying LABEL. Parent specification issues
referenced by a ticket's "## Parent" section are ignored.
'@
}
$options = Read-Options $args @('/label') @() ${function:Show-Usage}
$label = Get-Option $options '/label'
if (!$label) { Show-Usage; Stop-Script '/label is required' 2 }
Require-Commands @('gh') 2
$repository = Invoke-Checked gh @('repo', 'view', '--json', 'nameWithOwner', '--jq', '.nameWithOwner') '' 2
$allIssues = @(Invoke-GhJson @('issue', 'list', '--repo', $repository, '--state', 'open', '--label', $label, '--limit', '1000', '--json', 'number,title,body,labels,url') '' 2)
if (!$allIssues.Count) { Stop-Script "No open tickets carry label '$label' in $repository." }
$parents = @(Get-ParentNumbers $allIssues)
$issues = @($allIssues | Where-Object { $_.number -notin $parents })
if (!$issues.Count) { Stop-Script "No executable open tickets carry label '$label' in $repository." }
$ignored = $allIssues.Count - $issues.Count
$ignoredText = if ($ignored -gt 0) { " ($ignored parent specification issue(s) ignored)" } else { '' }
Write-Host "Validating $($issues.Count) executable open ticket(s) carrying '$label' in $repository$ignoredText."
$failureCount = 0
$blockedTicketCount = 0
foreach ($issue in $issues) {
    $failures = @()
    $names = @(Get-LabelNames $issue)
    if ('ready-for-agent' -notin $names) { $failures += 'missing ready-for-agent' }
    $difficultyLabels = @($names | Where-Object { $_ -match '^difficulty[/:]\s*' })
    if (!$difficultyLabels.Count) { $failures += 'missing difficulty label' }
    foreach ($name in $difficultyLabels) {
        $value = $name -replace '^[^:/]+[:/]\s*', ''
        if ($value -notmatch '^(trivial|small|low|medium|large|high|hard)$') { $failures += "unsupported difficulty label '$name'" }
    }
    $priorityLabels = @($names | Where-Object { $_ -match '^(critical|urgent|p0|high|p1|medium|normal|p2|low|p3)$|^priority[/:]\s*' })
    if (!$priorityLabels.Count) { $failures += 'missing priority label' }
    foreach ($name in $priorityLabels) {
        if ($name -match '^priority[:/]') {
            $value = $name -replace '^[^:/]+[:/]\s*', ''
            if ($value -notmatch '^(critical|urgent|p0|high|p1|medium|normal|p2|low|p3|[0-9]+)$') { $failures += "unsupported priority label '$name'" }
        }
    }
    $blockedBy = Get-BlockedCount $repository $issue.number 2
    if ($blockedBy -gt 0) { $blockedTicketCount++ }
    if (!$failures.Count) { Write-Host "PASS #$($issue.number): $($issue.title) (blocked by $blockedBy)" }
    else {
        [Console]::Error.WriteLine("FAIL #$($issue.number): $($issue.title)")
        foreach ($failure in $failures) { [Console]::Error.WriteLine("  - $failure") }
        $failureCount += $failures.Count
    }
}
if (!$blockedTicketCount) {
    [Console]::Error.WriteLine('error: At least one matching ticket must have native GitHub blocked_by metadata.')
    $failureCount++
}
if ($failureCount) { Stop-Script "Validation failed with $failureCount problem(s)." }
Write-Host "Validation passed: $($issues.Count) ticket(s), $blockedTicketCount blocked ticket(s)."
exit 0
