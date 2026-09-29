# Native Windows port of ralph_loop.sh. See /help for Windows-style options.
. "$PSScriptRoot/windows_common.ps1"
function Show-Usage {
    Write-Host @'
Usage: ralph_loop.ps1 /agent {pi|claude} [options]

Options:
  /agent NAME                       pi or claude (required)
  /model MODEL                      Agent model (default: Sol for pi, opus for claude)
  /effort LEVEL                     off|minimal|low|medium|high|xhigh|max
  /adaptive-model-and-effort        Select model/effort from difficulty label
                                     (cannot be combined with /model or /effort)
  /difficulty-override D=M:E        Override model/effort for matching difficulty D;
                                     may be repeated and combined with fixed selection
  /repo OWNER/NAME                  Repository (inferred when omitted)
  /ready-label LABEL                Eligibility label (default: ready-for-agent)
  /labels LABEL[,LABEL...]          Additional required labels; may be repeated.
                                     Also applied to tickets created by /bug-hunt
  /use-branch BRANCH                Check out/create this branch
  /bug-hunt MODEL:EFFORT            Run bug_hunt.ps1 after the main loop
  /fix-bugs                         After bug hunting, process its 'bug' tickets;
                                     also applies every /labels filter
  /initial-retry-interval-seconds N  (default: 30)
  /max-retry-interval-seconds N      (default: 900)
  /usage-poll-seconds N              (default: 600)
  /once                             Process at most one ticket
  /dry-run                          List eligible tickets in processing order with
                                     difficulty, priority, model/effort. Claims/runs nothing.
  /quiet                            Suppress routine and agent output
  /verbose                          Enable loop and agent diagnostics
  /help
'@
}
$options = Read-Options $args @('/agent', '/model', '/effort', '/repo', '/ready-label', '/labels', '/use-branch', '/bug-hunt', '/difficulty-override', '/initial-retry-interval-seconds', '/max-retry-interval-seconds', '/usage-poll-seconds') @('/adaptive-model-and-effort', '/fix-bugs', '/once', '/dry-run', '/quiet', '/verbose') ${function:Show-Usage}
$agent = Get-Option $options '/agent'
$model = Get-Option $options '/model'
$effort = Get-Option $options '/effort' 'medium'
$repo = Get-Option $options '/repo'
$readyLabel = Get-Option $options '/ready-label' 'ready-for-agent'
$useBranch = Get-Option $options '/use-branch'
$labels = @(Get-Labels $options)
$adaptive = $options.ContainsKey('/adaptive-model-and-effort')
$once = $options.ContainsKey('/once')
$dryRun = $options.ContainsKey('/dry-run')
$quiet = $options.ContainsKey('/quiet')
$verbose = $options.ContainsKey('/verbose')
$bugHunt = $options.ContainsKey('/bug-hunt')
$fixBugs = $options.ContainsKey('/fix-bugs')
Assert-Agent $agent $effort 1
if ($adaptive -and ($options.ContainsKey('/model') -or $options.ContainsKey('/effort'))) {
    $conflicts = @('/model', '/effort' | Where-Object { $options.ContainsKey($_) }) -join ' and '
    Stop-Script "$conflicts cannot be used with /adaptive-model-and-effort, which picks both from each ticket's difficulty label. Drop /adaptive-model-and-effort to pin them, or drop $conflicts to let the loop choose." 2
}
$overrides = @{}
$overrideSpecs = @()
if ($options.ContainsKey('/difficulty-override')) { $overrideSpecs = $options['/difficulty-override'] }
foreach ($spec in $overrideSpecs) {
    if ($spec -cnotmatch '^(trivial|easy|small|low|medium|large|high|hard)=(.+):(off|minimal|low|medium|high|xhigh|max)$') {
        Stop-Script '/difficulty-override must be in the form DIFFICULTY=MODEL:EFFORT, with a supported difficulty and effort' 2
    }
    $overrides[$Matches[1]] = @{ Model = $Matches[2]; Effort = $Matches[3] }
}
$bugHuntModel = ''; $bugHuntEffort = ''
if ($bugHunt) {
    $spec = Get-Option $options '/bug-hunt'
    if ($spec -cnotmatch '^(.+):(off|minimal|low|medium|high|xhigh|max)$') { Stop-Script '/bug-hunt must be in the form MODEL:EFFORT, with a supported effort' 2 }
    $bugHuntModel = $Matches[1]; $bugHuntEffort = $Matches[2]
}
$initialRetry = Get-Option $options '/initial-retry-interval-seconds' '30'
$maxRetry = Get-Option $options '/max-retry-interval-seconds' '900'
$usagePoll = Get-Option $options '/usage-poll-seconds' '600'
foreach ($interval in @($initialRetry, $maxRetry, $usagePoll)) {
    if ($interval -notmatch '^[0-9]+$') { Stop-Script 'Retry intervals must be integers.' }
}
$initialRetry = [long]$initialRetry; $maxRetry = [long]$maxRetry; $usagePoll = [long]$usagePoll
if ($initialRetry -lt 1 -or $maxRetry -lt $initialRetry) { Stop-Script 'Retry intervals must be positive and max must be at least initial.' }
if ($usagePoll -lt 1) { Stop-Script 'Usage poll interval must be positive.' }
if ($quiet -and $verbose) { Stop-Script '/quiet and /verbose cannot be used together.' }
if ($agent -eq 'claude') {
    if ($bugHunt -and $bugHuntEffort -cnotmatch '^(low|medium|high|xhigh|max)$') { Stop-Script "Bug-hunt effort '$bugHuntEffort' is not supported by claude. Use low, medium, high, xhigh, or max." }
    foreach ($mapping in $overrides.Values) {
        if ($mapping.Effort -cnotmatch '^(low|medium|high|xhigh|max)$') { Stop-Script "Difficulty override effort '$($mapping.Effort)' is not supported by claude. Use low, medium, high, xhigh, or max." }
    }
}
if ($fixBugs -and !$bugHunt) { Write-WarningLine '/fix-bugs has no effect without /bug-hunt.'; $fixBugs = $false }
Require-Commands @('gh', 'git', $agent)
if (!$model) { $model = if ($agent -eq 'pi') { 'openai-codex/gpt-5.6-sol' } else { 'opus' } }
function Write-Status([string] $Message) { if (!$quiet) { Write-Host $Message } }
function Write-Diagnostic([string] $Message) { if ($verbose) { Write-Host "verbose: $Message" } }
function Get-Priority($Issue) {
    $ranks = @(foreach ($name in @(Get-LabelNames $Issue)) {
        switch -Regex ($name.ToLowerInvariant()) {
            '^(priority[:/]\s*)?(critical|urgent|p0)$' { 0; break }
            '^(priority[:/]\s*)?(high|p1)$' { 1; break }
            '^(priority[:/]\s*)?(medium|normal|p2)$' { 2; break }
            '^(priority[:/]\s*)?(low|p3)$' { 3; break }
            '^priority[:/]\s*([0-9]+)$' { [long]$Matches[1]; break }
            default { 100 }
        }
    })
    if (!$ranks.Count) { return 100 }
    return ($ranks | Measure-Object -Minimum).Minimum
}
function Get-Difficulties($Issue) {
    @(foreach ($name in @(Get-LabelNames $Issue)) {
        if ($name.ToLowerInvariant() -match '^difficulty[:/]\s*(trivial|easy|small|low|medium|large|high|hard)$') { $Matches[1] }
    }) | Sort-Object -Unique
}
function Get-PriorityLabel($Issue) {
    foreach ($name in @(Get-LabelNames $Issue)) {
        if ($name.ToLowerInvariant() -match '^priority[:/]\s*(critical|urgent|p0|high|p1|medium|normal|p2|low|p3)$') { return $Matches[1] }
    }
    return ([string][char]0x2014)
}
function Get-AdaptiveMapping([string] $Difficulty) {
    if ($overrides.ContainsKey($Difficulty)) { return $overrides[$Difficulty] }
    $small = if ($agent -eq 'pi') { 'openai-codex/gpt-5.6-terra' } else { 'sonnet' }
    $large = if ($agent -eq 'pi') { 'openai-codex/gpt-5.6-sol' } else { 'opus' }
    switch -Regex ($Difficulty) {
        '^trivial$' { return @{ Model = $small; Effort = 'medium' } }
        '^(easy|small|low)$' { return @{ Model = $small; Effort = 'high' } }
        '^medium$' { return @{ Model = $large; Effort = 'medium' } }
        '^(large|high|hard)$' { return @{ Model = $large; Effort = 'high' } }
    }
    Stop-Script "Unsupported difficulty '$Difficulty'."
}
function Get-Selection($Issue, [switch] $Preview) {
    $selection = @{ Model = $model; Effort = $effort; Source = 'command line/default' }
    $diffs = @(Get-Difficulties $Issue)
    $matchesOverride = @($diffs | Where-Object { $overrides.ContainsKey($_) }).Count
    if ($diffs.Count -gt 1) {
        if ($adaptive -or $matchesOverride -gt 0) {
            if (!$Preview) { Stop-Script "Model and effort selection found conflicting difficulty labels: $($diffs -join ' ')." }
            return @{ Model = '(conflict)'; Effort = '(conflict)'; Source = "conflicting difficulty labels [$($diffs -join ',')]" }
        }
        return $selection
    }
    if ($matchesOverride -gt 0) {
        $mapping = Get-AdaptiveMapping $diffs[0]
        return @{ Model = $mapping.Model; Effort = $mapping.Effort; Source = "difficulty override:$($diffs[0])" }
    }
    if ($adaptive) {
        if (!$diffs.Count) {
            if (!$Preview) { Stop-Script 'Adaptive model and effort requires one supported difficulty label.' }
            return @{ Model = '(unresolved)'; Effort = '(unresolved)'; Source = 'adaptive: no difficulty label' }
        }
        $mapping = Get-AdaptiveMapping $diffs[0]
        return @{ Model = $mapping.Model; Effort = $mapping.Effort; Source = "adaptive difficulty:$($diffs[0])" }
    }
    return $selection
}
function Get-Assignees($Issue) { foreach ($assignee in @(Get-Field $Issue 'assignees' @())) { [string]$assignee.login } }
function Get-Ranking($Issue) {
    $assignees = @(Get-Assignees $Issue)
    $rank = if ($currentUser -cin $assignees) { 0 } else { 1 }
    return '{0}:{1:D10}:{2:D10}' -f $rank, [long](Get-Priority $Issue), [long]$Issue.number
}
function Get-NextTicket([string[]] $LoopLabels) {
    $queryArgs = @('issue', 'list', '--repo', $repo, '--state', 'open', '--label', $readyLabel)
    foreach ($label in $LoopLabels) { if ($label) { $queryArgs += @('--label', $label) } }
    $queryArgs += @('--limit', '100', '--json', 'number,title,body,labels,assignees,url')
    $issues = @(Invoke-GhJson $queryArgs)
    $parents = @(Get-ParentNumbers $issues)
    $best = $null; $bestKey = ''
    foreach ($issue in $issues) {
        if ($issue.number -in $parents) { continue }
        $assignees = @(Get-Assignees $issue)
        if ($assignees.Count -gt 0 -and $currentUser -cnotin $assignees) { continue }
        if ((Get-BlockedCount $repo $issue.number) -ne 0) { continue }
        $key = Get-Ranking $issue
        if (!$bestKey -or [string]::CompareOrdinal($key, $bestKey) -lt 0) { $bestKey = $key; $best = $issue }
    }
    return $best
}
$dryRunQuery = @'
query($q: String!) {
  search(query: $q, type: ISSUE, first: 100) {
    nodes {
      ... on Issue {
        number
        title
        url
        labels(first: 20) { nodes { name } }
        assignees(first: 10) { nodes { login } }
        blockedBy(first: 50) { nodes { number state } }
      }
    }
  }
}
'@
function Invoke-DryRun {
    $searchQuery = "repo:$repo is:issue is:open"
    foreach ($label in @($readyLabel) + $labels) {
        if ($label) { $searchQuery += ' label:"' + $label.Replace('"', '') + '"' }
    }
    $payload = @{ query = $dryRunQuery; variables = @{ q = $searchQuery } } | ConvertTo-Json -Depth 10 -Compress
    $data = Invoke-GhJson @('api', 'graphql', '--input', '-') $payload
    $nodes = @($data.data.search.nodes)
    if (!$nodes.Count) { Write-Host "No open tickets match: $searchQuery"; return }
    $nodeOf = @{}; $blockersOf = @{}; $completed = @{}
    foreach ($node in $nodes) {
        $n = [long]$node.number
        $nodeOf[$n] = [pscustomobject]@{ number = $n; title = $node.title; url = $node.url; labels = @($node.labels.nodes); assignees = @($node.assignees.nodes) }
        $blockersOf[$n] = @($node.blockedBy.nodes | Where-Object { $_.state -ceq 'OPEN' } | ForEach-Object { [long]$_.number })
    }
    Write-Host "Dry run - $agent, filter: $searchQuery"
    if ($adaptive) { Write-Host 'Model/effort: adaptive from the difficulty label.' }
    else { Write-Host "Model/effort: fixed at '$model' / '$effort' (pass /adaptive-model-and-effort to vary by difficulty)." }
    if ($overrideSpecs.Count) { Write-Host "Difficulty overrides: $($overrideSpecs -join ' ')." }
    Write-Host ''
    $format = '{0,-6} {1,-8} {2,-11} {3,-10} {4,-28} {5,-8} {6}'
    Write-Host ($format -f 'Order', 'Ticket', 'Difficulty', 'Priority', 'Model', 'Effort', 'Selection source')
    $processed = 0
    while ($true) {
        $best = $null; $bestKey = ''
        foreach ($n in $nodeOf.Keys) {
            if ($completed.ContainsKey($n)) { continue }
            $issue = $nodeOf[$n]; $assignees = @(Get-Assignees $issue)
            if ($assignees.Count -gt 0 -and $currentUser -cnotin $assignees) { continue }
            $unmet = @($blockersOf[$n] | Where-Object { !$completed.ContainsKey($_) })
            if ($unmet.Count) { continue }
            $key = Get-Ranking $issue
            if (!$bestKey -or [string]::CompareOrdinal($key, $bestKey) -lt 0) { $bestKey = $key; $best = $n }
        }
        if ($null -eq $best) { break }
        $processed++; $completed[$best] = $true
        $selection = Get-Selection $nodeOf[$best] -Preview
        Write-Host ($format -f $processed, "#$best", (@(Get-Difficulties $nodeOf[$best]) -join ','), (Get-PriorityLabel $nodeOf[$best]), $selection.Model, $selection.Effort, $selection.Source)
    }
    $stranded = @($nodeOf.Keys | Where-Object { !$completed.ContainsKey($_) } | Sort-Object)
    Write-Host ''
    if (!$stranded.Count) { Write-Host "All $($nodes.Count) eligible tickets are runnable. Nothing stranded."; return }
    Write-Host "Not runnable by this loop ($($stranded.Count) of $($nodes.Count)):"
    foreach ($n in $stranded) {
        $reasons = @(); $assignees = @(Get-Assignees $nodeOf[$n])
        if ($assignees.Count -gt 0 -and $currentUser -cnotin $assignees) { $reasons += "assigned to $($assignees -join ', '), not $currentUser" }
        $unmet = @(foreach ($b in $blockersOf[$n]) {
            if (!$completed.ContainsKey($b)) { if ($nodeOf.ContainsKey($b)) { "#$b" } else { "#$b (outside label filter)" } }
        })
        if ($unmet.Count) { $reasons += "blocked by $($unmet -join ' ')" }
        if (!$reasons.Count) { $reasons += 'not reached' }
        Write-Host ('  #{0,-7} {1}' -f $n, ($reasons -join '; '))
    }
}
function Get-TicketPrompt([long] $Number) {
    $issue = Invoke-GhJson @('issue', 'view', "$Number", '--repo', $repo, '--json', 'number,title,body,comments,url')
    $comments = if (@($issue.comments).Count) { @($issue.comments | ForEach-Object { $_.body }) -join "`n`n---`n`n" } else { '(No comments.)' }
    return @"
Implement GitHub ticket #$($issue.number): $($issue.title)
$($issue.url)

You are running non-interactively. Work autonomously through implementation; do not stop at a plan and do not ask the user questions. Read and follow the repository instructions and domain documentation. Inspect the current worktree first because this may be a retry after a provider failure.

Only implement this ticket, not its parent or blocked follow-up tickets. Use the ticket's acceptance criteria as the contract. Run focused tests while developing, then the relevant builds, formatting checks, and tests before completion. Preserve unrelated and pre-existing untracked files.

Ensure that all tests are headless and there are no dialog boxes or anything that may block non-interactive automation.

When the ticket is fully implemented and verified:
1. Commit all tracked changes on the current branch with a message referencing #$($issue.number).
2. Close #$($issue.number) with a concise comment containing the commit hash and validation performed.
3. Finish with a concise implementation summary.

If implementation cannot be completed for a code, test, or specification reason, leave the issue open, do not commit partial work merely to satisfy this prompt, and explain the blocker in your final response.

## Ticket body

$($issue.body)

## Ticket comments

$comments
"@
}
function Test-TicketComplete([long] $Number, [string] $StartingHead) {
    $state = Invoke-Native gh @('issue', 'view', "$Number", '--repo', $repo, '--json', 'state', '--jq', '.state')
    if ($state.Code -ne 0 -or $state.Text.Trim() -cne 'CLOSED') { return $false }
    $head = Invoke-Native git @('rev-parse', 'HEAD')
    $worktree = Invoke-Native git @('status', '--porcelain', '--untracked-files=no')
    return ($head.Code -eq 0 -and $worktree.Code -eq 0 -and $head.Text.Trim() -cne $StartingHead -and !$worktree.Text)
}
function Get-SessionUsage([string] $Kind, [string[]] $Sources) {
    $files = @()
    if ($Kind -eq 'pi') { $files = @(Get-ChildItem -LiteralPath $Sources[0] -Filter '*.jsonl' -File -Recurse -ErrorAction SilentlyContinue) }
    else {
        $configRoot = if ($env:CLAUDE_CONFIG_DIR) { $env:CLAUDE_CONFIG_DIR } else { Join-Path $HOME '.claude' }
        $projects = Join-Path $configRoot 'projects'
        if (!(Test-Path -LiteralPath $projects)) { return $null }
        foreach ($id in $Sources) { $files += @(Get-ChildItem -LiteralPath $projects -Filter "$id.jsonl" -File -Recurse -ErrorAction SilentlyContinue) }
    }
    $result = @{ provider = ''; model = ''; input = 0L; output = 0L; cacheRead = 0L; cacheWrite = 0L; reasoning = 0L; total = 0L; cost = 0.0; costKnown = ($Kind -eq 'pi') }
    $count = 0
    foreach ($file in $files) {
        foreach ($line in [IO.File]::ReadLines($file.FullName)) {
            try { $event = ConvertFrom-Json $line } catch { continue }
            $message = Get-Field $event 'message'
            $usage = Get-Field $message 'usage'
            if (!$usage) { continue }
            if ($Kind -eq 'pi') {
                if ((Get-Field $event 'type') -cne 'message' -or (Get-Field $message 'role') -cne 'assistant') { continue }
                $provider = Get-Field $message 'provider' ''
                if ($provider) { $result.provider = $provider }
                foreach ($field in @('input', 'output', 'cacheRead', 'cacheWrite', 'reasoning')) { $result[$field] += [long](Get-Field $usage $field 0) }
                $result.total += [long](Get-Field $usage 'totalTokens' 0)
                $result.cost += [double](Get-Field (Get-Field $usage 'cost') 'total' 0)
            } else {
                if ((Get-Field $event 'type') -cne 'assistant') { continue }
                $result.provider = 'anthropic'
                $fields = @{ input = 'input_tokens'; output = 'output_tokens'; cacheRead = 'cache_read_input_tokens'; cacheWrite = 'cache_creation_input_tokens' }
                foreach ($field in $fields.Keys) {
                    $value = [long](Get-Field $usage $fields[$field] 0)
                    $result[$field] += $value; $result.total += $value
                }
                $result.reasoning += [long](Get-Field (Get-Field $usage 'output_tokens_details') 'thinking_tokens' 0)
            }
            $eventModel = Get-Field $message 'model' ''
            if ($eventModel) { $result.model = $eventModel }
            $count++
        }
    }
    if (!$count) { return $null }
    return [pscustomobject]$result
}
function Show-TicketSummary([long] $Number, [DateTimeOffset] $Started, [DateTimeOffset] $Ended, $Usage) {
    $duration = [long]($Ended.ToUnixTimeSeconds() - $Started.ToUnixTimeSeconds())
    Write-Host "Ticket #$Number summary"
    Write-Host "  Started: $($Started.ToString('yyyy-MM-ddTHH:mm:sszzz'))"
    Write-Host "  Ended: $($Ended.ToString('yyyy-MM-ddTHH:mm:sszzz'))"
    Write-Host ('  Duration: {0:D2}:{1:D2}:{2:D2}' -f [long][Math]::Floor($duration / 3600), [long][Math]::Floor(($duration % 3600) / 60), ($duration % 60))
    if (!$Usage) { Write-Host '  Total tokens spent: unavailable'; return }
    $cost = if ($Usage.costKnown) { 'cost $' + $Usage.cost } else { 'cost not reported by this agent' }
    Write-Host "  Total tokens spent: $($Usage.total) (input $($Usage.input), output $($Usage.output), reasoning $($Usage.reasoning), cache read $($Usage.cacheRead), cache write $($Usage.cacheWrite)); $cost"
}
function Show-Window([string] $Name, $Window) {
    if (!$Window) { Write-Host "  ${Name}: not reported"; return }
    $used = Get-Field $Window 'used_percent' (Get-Field $Window 'utilization')
    $reset = Get-Field $Window 'reset_after_seconds'
    if ($null -eq $reset -and (Get-Field $Window 'resets_at')) {
        try { $reset = ([DateTimeOffset]::Parse($Window.resets_at) - [DateTimeOffset]::UtcNow).TotalSeconds } catch { }
    }
    $resetText = 'reset unknown'
    if ($null -ne $reset) {
        $reset = [long][Math]::Max(0, [Math]::Truncate([double]$reset))
        if ($reset -ge 86400) { $resetText = 'resets in {0}d {1}h' -f [Math]::Floor($reset / 86400), [Math]::Floor(($reset % 86400) / 3600) }
        elseif ($reset -ge 3600) { $resetText = 'resets in {0}h {1}m' -f [Math]::Floor($reset / 3600), [Math]::Floor(($reset % 3600) / 60) }
        else { $resetText = 'resets in {0}m' -f [Math]::Floor(($reset + 59) / 60) }
    }
    if ($null -eq $used) { Write-Host "  ${Name}: usage not reported; $resetText" }
    else { Write-Host ('  {0}: {1:F1}% used, {2:F1}% remaining; {3}' -f $Name, [double]$used, [Math]::Max(0, 100 - [double]$used), $resetText) }
}
function Show-ProviderUsage($Usage) {
    Write-Host "Provider usage ($($Usage.provider)/$($Usage.model))"
    if ($Usage.provider -notin @('anthropic', 'openai-codex')) {
        Write-Host '  Current window: not available from this provider'; Write-Host '  Weekly: not available from this provider'; return
    }
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
        if ($Usage.provider -eq 'anthropic') {
            $root = if ($env:CLAUDE_CONFIG_DIR) { $env:CLAUDE_CONFIG_DIR } else { Join-Path $HOME '.claude' }
            $credential = Get-Content -LiteralPath (Join-Path $root '.credentials.json') -Raw -Encoding UTF8 | ConvertFrom-Json
            $token = $credential.claudeAiOauth.accessToken
            if (!$token) { throw 'No OAuth access token' }
            $response = Invoke-RestMethod 'https://api.anthropic.com/api/oauth/usage' -Headers @{ Authorization = "Bearer $token"; 'anthropic-beta' = 'oauth-2025-04-20' }
            $current = Get-Field $response 'five_hour'; $weekly = Get-Field $response 'seven_day'
        } else {
            $root = if ($env:PI_CODING_AGENT_DIR) { $env:PI_CODING_AGENT_DIR } else { Join-Path $HOME '.pi/agent' }
            $credential = Get-Content -LiteralPath (Join-Path $root 'auth.json') -Raw -Encoding UTF8 | ConvertFrom-Json
            $auth = $credential.'openai-codex'
            if ($auth.type -cne 'oauth' -or !$auth.access) { throw 'No OAuth access token' }
            $response = Invoke-RestMethod 'https://chatgpt.com/backend-api/wham/usage' -Headers @{ Authorization = "Bearer $($auth.access)"; 'ChatGPT-Account-Id' = (Get-Field $auth 'accountId' '') }
            $limits = Get-Field $response 'rate_limit'
            $current = Get-Field $limits 'primary_window'; $weekly = Get-Field $limits 'secondary_window'
            if ($current -and !$weekly -and (Get-Field $current 'limit_window_seconds' 0) -ge 518400) { $weekly = $current; $current = $null }
        }
        Show-Window 'Current window' $current; Show-Window 'Weekly' $weekly
    } catch {
        Write-WarningLine 'Could not read provider usage.'; Write-Host '  Current window: unavailable'; Write-Host '  Weekly: unavailable'
    }
}
$usageErrorPattern = 'usage limit|usage_limit_reached|usage cap|quota exceeded|insufficient_quota|out of credits|credit balance|billing limit|subscription limit|weekly limit|monthly limit|weighted tokens|token limit.*reset|rate limit.*reset|limit resets? at'
$serverErrorPattern = 'HTTP\s*(408|409|425|429|5[0-9][0-9])|status\s*(408|409|425|429|5[0-9][0-9])|server error|internal server error|service unavailable|bad gateway|gateway timeout|overloaded|temporarily unavailable|request timeout|timed out|ECONNRESET|ECONNREFUSED|ENETUNREACH|EAI_AGAIN|socket hang up|connection reset|connection closed|fetch failed|network error|server_error|stream.*(closed|terminated)'
function Invoke-TicketLoop([string] $LoopName, [string[]] $ExtraLabels = @()) {
    $loopLabels = @($labels) + $ExtraLabels
    while ($true) {
        $ticket = Get-NextTicket $loopLabels
        if (!$ticket) { Write-Status "No unblocked, unclaimed '$readyLabel' tickets are available for the $LoopName loop."; break }
        $number = $ticket.number
        Write-Status "Selected #${number}: $($ticket.title)"
        $selection = Get-Selection $ticket
        Write-Host "Ticket #$number model: $($selection.Model); effort: $($selection.Effort) ($($selection.Source))."
        if (!@(Get-Assignees $ticket).Count) {
            $null = Invoke-Checked gh @('issue', 'edit', "$number", '--repo', $repo, '--add-assignee', '@me')
            Write-Status "Claimed #$number as $currentUser."
        }
        $started = [DateTimeOffset]::Now
        $timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
        $ticketSessionDirectory = Join-Path $logDirectory "issue-$number-$timestamp-sessions"
        $sessionIds = @()
        if ($agent -eq 'pi') { [void][IO.Directory]::CreateDirectory($ticketSessionDirectory) }
        Write-Status "Ticket #$number started at $($started.ToString('yyyy-MM-ddTHH:mm:sszzz'))."
        $startingHead = Invoke-Checked git @('rev-parse', 'HEAD')
        $originalPrompt = Get-TicketPrompt $number
        $prompt = $originalPrompt; $retryInterval = $initialRetry; $attempt = 0
        while ($true) {
            $attempt++; $attemptTimestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
            $logPath = Join-Path $logDirectory "issue-$number-$attemptTimestamp-attempt-$attempt.log"
            Write-Status "Starting $agent for #$number (attempt $attempt). Log: $logPath"
            if ($agent -eq 'pi') {
                $sessionDirectory = Join-Path $ticketSessionDirectory "attempt-$attempt"
                [void][IO.Directory]::CreateDirectory($sessionDirectory)
                Write-Diagnostic "Session directory: $sessionDirectory"
                $agentArgs = @('--print', '--approve', '--model', $selection.Model, '--thinking', $selection.Effort, '--name', "ralph-$number", '--session-dir', $sessionDirectory)
            } else {
                $sessionId = [guid]::NewGuid().ToString(); $sessionIds += $sessionId
                Write-Diagnostic "Session id: $sessionId"
                $agentArgs = @('--print', '--dangerously-skip-permissions', '--model', $selection.Model, '--effort', $selection.Effort, '--session-id', $sessionId)
            }
            if ($verbose) { $agentArgs += '--verbose' }
            $result = Invoke-Native $agent $agentArgs -InputText $prompt -LogPath $logPath -StripControl -Live:(!$quiet)
            if (Test-TicketComplete $number $startingHead) { Write-Status "Ticket #$number completed successfully."; break }
            if ($result.Code -eq 0) {
                Write-WarningLine "$agent exited successfully without completing #$number. Starting a recovery attempt using $logPath."
                $prompt = @"
$originalPrompt

## Recovery attempt

A previous agent attempt exited successfully without closing ticket #$number.
Inspect the previous attempt log at:

$logPath

Determine why that attempt did not complete the original request, then resolve the issue recorded in the log and finish the original ticket. Continue from the current worktree and repository state. Do not merely repeat the previous explanation or stop after describing the blocker; try to resolve it and carry the original request through implementation, verification, commit, and issue closure.
"@
                continue
            }
            $log = Get-Content -LiteralPath $logPath -Raw -Encoding UTF8
            if ($log -match $usageErrorPattern) { Write-WarningLine "Usage limit detected for #$number. Retrying in $usagePoll seconds."; Start-Sleep -Seconds $usagePoll; continue }
            if ($log -match $serverErrorPattern) {
                Write-WarningLine "Server/API failure detected for #$number. Retrying in $retryInterval seconds."
                Start-Sleep -Seconds $retryInterval
                $retryInterval = [Math]::Min($retryInterval * 2, $maxRetry)
                continue
            }
            Stop-Script "$agent failed for a non-retryable implementation reason on #$number. The issue remains assigned and open. Inspect $logPath."
        }
        $ended = [DateTimeOffset]::Now
        if ($agent -eq 'pi') { $usageSource = $ticketSessionDirectory; $usage = Get-SessionUsage pi @($ticketSessionDirectory) }
        else { $usageSource = "Claude Code sessions $($sessionIds -join ' ')"; $usage = Get-SessionUsage claude $sessionIds }
        Show-TicketSummary $number $started $ended $usage
        if (!$usage) { Write-WarningLine "Could not read current-ticket usage from $usageSource." } else { Show-ProviderUsage $usage }
        if ($once) { break }
    }
}
$originalLocation = Get-Location
try {
    $repoRoot = Enter-Repository
    if (!$dryRun) {
        $worktree = Invoke-Checked git @('status', '--porcelain', '--untracked-files=no')
        if ($worktree) { Stop-Script 'The tracked worktree is not clean. Commit or restore tracked changes before starting the loop.' }
        if ($useBranch -and (Invoke-Checked git @('rev-parse', '--abbrev-ref', 'HEAD')) -cne $useBranch) {
            $localBranch = Invoke-Native git @('show-ref', '--verify', '--quiet', "refs/heads/$useBranch")
            if ($localBranch.Code -eq 0) { $checkoutArgs = @('checkout', $useBranch) }
            else {
                $remote = Invoke-Native git @('ls-remote', '--exit-code', '--heads', 'origin', $useBranch)
                $checkoutArgs = if ($remote.Code -eq 0) { @('checkout', '-b', $useBranch, '--track', "origin/$useBranch") } else { @('checkout', '-b', $useBranch) }
            }
            $checkout = Invoke-Native git $checkoutArgs
            if ($checkout.Code -ne 0) { Stop-Script "Failed to check out branch '$useBranch'." }
            Write-Status "Switched to branch '$useBranch'."
        }
    }
    if (!$repo) { $repo = Invoke-Checked gh @('repo', 'view', '--json', 'nameWithOwner', '--jq', '.nameWithOwner') }
    $currentUser = Invoke-Checked gh @('api', 'user', '--jq', '.login')
    $logDirectory = New-LogDirectory "$agent-ralph_loop"
    if ($dryRun) { Invoke-DryRun; exit 0 }
    Invoke-TicketLoop 'initial'
    if ($bugHunt) {
        $huntArgs = @('/agent', $agent, '/model', $bugHuntModel, '/effort', $bugHuntEffort, '/publish', 'tracker')
        if ($useBranch) { $huntArgs += '/branch-only' }
        if ($options.ContainsKey('/labels')) { foreach ($spec in $options['/labels']) { $huntArgs += @('/labels', $spec) } }
        Write-Status "Starting post-loop bug hunt with $bugHuntModel at $bugHuntEffort effort."
        # Separate process keeps the child script's exit and functions isolated.
        $engine = (Get-Process -Id $PID).Path
        $result = Invoke-Native $engine (@('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $PSScriptRoot 'bug_hunt.ps1')) + $huntArgs) -Live
        if ($result.Code -ne 0) {
            if ($fixBugs) { Stop-Script 'Bug hunt failed; bug-fix loop will not start.' }
            exit $result.Code
        }
        if ($fixBugs) { Write-Status 'Starting post-hunt bug-fix loop.'; Invoke-TicketLoop 'post-hunt bug-fix' @('bug') }
    }
    exit 0
} finally { Set-Location -LiteralPath $originalLocation.Path }
