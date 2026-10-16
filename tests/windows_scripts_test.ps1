# Windows PowerShell 5.1+. Hermetic: all git/gh/agent commands are local stubs.
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
. "$root/windows_common.ps1"
$temp = Join-Path ([IO.Path]::GetTempPath()) ('dev-scripts-test-' + [guid]::NewGuid())
[void][IO.Directory]::CreateDirectory($temp)
$oldPath = $env:PATH; $oldTmp = $env:TMPDIR
$engine = (Get-Process -Id $PID).Path
$env:DEV_SCRIPTS_TEST_DIR = $temp
$env:TMPDIR = $temp
$env:PATH = "$temp;$env:PATH"
$utf8 = New-Object Text.UTF8Encoding($false)
$script:checks = 0
function Assert($Condition, [string] $Message) {
    if (!$Condition) { throw "FAIL: $Message" }
    $script:checks++
}
function Set-Fixture($Fixture) {
    [IO.File]::WriteAllText((Join-Path $temp 'fixture.json'), ($Fixture | ConvertTo-Json -Depth 50), $utf8)
    foreach ($name in @('calls.jsonl', 'agent-count', 'prompt.txt')) { Remove-Item -LiteralPath (Join-Path $temp $name) -ErrorAction SilentlyContinue }
    Get-ChildItem -LiteralPath $temp -Filter 'prompt-*.txt' | Remove-Item
}
function Assert-StagedValidation([string] $Prompt) {
    Assert ($Prompt -match '1\. Inner development loop: incrementally build only the changed targets and required dependencies' -and $Prompt -match 'specific new, affected, or failing checks' -and $Prompt -match 'Do not routinely run whole-project builds or full regression suites after every edit') 'focused inner development loop'
    Assert ($Prompt -match '2\. Feature milestones:' -and $Prompt -match 'affected modules and relevant integration/contract coverage' -and $Prompt -match 'Broaden validation when shared code or cross-module dependencies warrant it') 'milestone validation'
    Assert ($Prompt -match '3\. Before completion: perform the repository-required full validation matrix on the final source state' -and $Prompt -match 'one successful final validation pass per required configuration') 'required final validation'
    Assert ($Prompt -match 'Validation evidence must match the final source state:' -and $Prompt -match 'invalidate and rerun the relevant coverage; do not treat an earlier pass as final verification') 'final-source-state evidence'
    Assert ($Prompt -match 'Before considering the ticket complete, bug-check your own work' -and $Prompt -match 'Resolve every issue you find and re-run the affected validation') 'self bug-check before completion'
}
function Run-Script([string] $Name, [string[]] $Tokens) {
    Invoke-Native $engine (@('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $root "$Name.ps1")) + $Tokens)
}
function Get-Calls { @(Get-Content -LiteralPath (Join-Path $temp 'calls.jsonl') -Encoding UTF8 | ForEach-Object { ConvertFrom-Json $_ }) }
function New-Issue([int] $Number, [string[]] $Labels = @('ready-for-agent', 'difficulty:medium', 'priority:high'), [string[]] $Assignees = @(), [string] $Body = '') {
    @{ number = $Number; title = "Ticket $Number"; url = "https://example.test/$Number"; body = $Body
       labels = @($Labels | ForEach-Object { @{ name = $_ } }); assignees = @($Assignees | ForEach-Object { @{ login = $_ } }); comments = @() }
}
function New-Node($Issue, $Blockers = @()) {
    @{ number = $Issue.number; title = $Issue.title; url = $Issue.url; body = $Issue.body
       labels = @{ nodes = $Issue.labels }; assignees = @{ nodes = $Issue.assignees }; blockedBy = @{ nodes = @($Blockers) } }
}
try {
    Add-Type -ReferencedAssemblies 'System.Web.Extensions' -OutputAssembly (Join-Path $temp 'gh.exe') -OutputType ConsoleApplication -TypeDefinition @'
using System;
using System.IO;
using System.Collections;
using System.Collections.Generic;
using System.Diagnostics;
using System.Text;
using System.Web.Script.Serialization;
public class Stub {
    static JavaScriptSerializer json = new JavaScriptSerializer();
    static string dir = Environment.GetEnvironmentVariable("DEV_SCRIPTS_TEST_DIR");
    static Dictionary<string, object> fixture;
    static object Field(string key, object fallback) { object value; return fixture.TryGetValue(key, out value) ? value : fallback; }
    static void Print(object value) { Console.WriteLine(json.Serialize(value)); }
    public static int Main(string[] args) {
        Console.OutputEncoding = new UTF8Encoding(false);
        Console.InputEncoding = new UTF8Encoding(false);
        fixture = json.Deserialize<Dictionary<string, object>>(File.ReadAllText(Path.Combine(dir, "fixture.json")));
        string name = Path.GetFileNameWithoutExtension(Process.GetCurrentProcess().MainModule.FileName);
        File.AppendAllText(Path.Combine(dir, "calls.jsonl"), json.Serialize(new { name = name, args = args }) + "\n", new UTF8Encoding(false));
        string command = String.Join(" ", args);
        string counter = Path.Combine(dir, "agent-count");
        int count = File.Exists(counter) ? Int32.Parse(File.ReadAllText(counter)) : 0;
        if (name == "probe") {
            if (command == "sleep") { System.Threading.Thread.Sleep(60000); return 0; }
            if (command == "spawn") {
                var child = Process.Start(new ProcessStartInfo(Process.GetCurrentProcess().MainModule.FileName, "sleep") { UseShellExecute = false, CreateNoWindow = true });
                File.WriteAllText(Path.Combine(dir, "child-pid"), child.Id.ToString());
                return 0;
            }
            Print(new { args = args, directory = Environment.CurrentDirectory, input = Console.In.ReadToEnd() });
            Console.Error.WriteLine("stderr diagnostic");
            return 0;
        }
        if (name == "pi" || name == "claude") {
            string prompt = Console.In.ReadToEnd();
            File.WriteAllText(Path.Combine(dir, "prompt.txt"), prompt, new UTF8Encoding(false));
            File.WriteAllText(counter, (++count).ToString());
            File.WriteAllText(Path.Combine(dir, "prompt-" + count + ".txt"), prompt, new UTF8Encoding(false));
            IList codes = (IList)Field("agentCodes", new object[] { 0 });
            int code = Convert.ToInt32(codes[Math.Min(count - 1, codes.Count - 1)]);
            Console.WriteLine(Field("agentOutput", "agent output"));
            Console.Error.WriteLine("agent diagnostic");
            // Emit usage in the session directory, including a malformed JSONL line.
            int session = Array.IndexOf(args, "--session-dir");
            if (session >= 0) File.WriteAllText(Path.Combine(args[session + 1], "usage.jsonl"), "not json\n{\"type\":\"message\",\"message\":{\"role\":\"assistant\",\"provider\":\"test\",\"model\":\"test-model\",\"usage\":{\"input\":2,\"output\":3,\"totalTokens\":5,\"cost\":{\"total\":0.01}}}}\n");
            return code;
        }
        if (name == "git") {
            if (command == "rev-parse --show-toplevel") Console.WriteLine(dir);
            else if (command == "rev-parse HEAD") Console.WriteLine(Convert.ToBoolean(Field("unchangedHead", false)) ? "old-head" : (count >= Convert.ToInt32(Field("completeAfter", 1)) ? "new-head" : "old-head"));
            else if (command.StartsWith("status ")) Console.Write(count == Convert.ToInt32(Field("dirtyAfter", -1)) ? " M tracked.txt" : (string)Field("worktree", ""));
            else if (command == "rev-parse --abbrev-ref HEAD" || command == "symbolic-ref --quiet --short HEAD") Console.WriteLine("feature/test");
            else if (command == "symbolic-ref --quiet --short refs/remotes/origin/HEAD") Console.WriteLine("origin/main");
            else if (command.StartsWith("merge-base ")) Console.WriteLine("base-commit");
            else if (command.StartsWith("log ")) { foreach (var line in (IList)Field("logLines", new object[0])) Console.WriteLine(line); }
            else if (command.StartsWith("rev-list ")) Console.WriteLine("3");
            else if (command.StartsWith("checkout ") || command.StartsWith("show-ref ") || command.StartsWith("rev-parse --verify ")) { }
            else { Console.Error.WriteLine("unexpected git: " + command); return 99; }
            return Convert.ToInt32(Field("gitCode", 0));
        }
        if (name == "gh") {
            if (command == "api user --jq .login") Console.WriteLine("tester");
            else if (command == "repo view --json nameWithOwner --jq .nameWithOwner") Console.WriteLine("owner/repo");
            else if (command == "api graphql --input -") {
                File.WriteAllText(Path.Combine(dir, "graphql.json"), Console.In.ReadToEnd());
                Print(new { data = new { search = new { nodes = Field("nodes", new object[0]) } } });
            } else if (command.StartsWith("issue list ")) Print(command.Contains("--label bug") ? Field("bugIssues", new object[0]) : Field("issues", new object[0]));
            else if (command.StartsWith("api repos/")) {
                var blocked = (Dictionary<string, object>)Field("blocked", new Dictionary<string, object>());
                string number = args[1].Substring(args[1].LastIndexOf('/') + 1);
                object value; if (!blocked.TryGetValue(number, out value)) value = 0;
                Print(new { issue_dependencies_summary = new { blocked_by = value } });
            } else if (command.StartsWith("issue view ") && command.EndsWith("--json state --jq .state")) {
                int completeAfter = Convert.ToBoolean(Field("sequentialTickets", false)) ? Int32.Parse(args[2]) + 1 : Convert.ToInt32(Field("completeAfter", 1));
                Console.WriteLine(count >= completeAfter ? "CLOSED" : "OPEN");
            }
            else if (command.StartsWith("issue view ")) Print(Field("ticket", null));
            else if (command.StartsWith("issue edit ") || command.StartsWith("label create ")) { }
            else { Console.Error.WriteLine("unexpected gh: " + command); return 99; }
            return Convert.ToInt32(Field("ghCode", 0));
        }
        return 99;
    }
}
'@
    foreach ($name in @('git', 'pi', 'claude', 'probe')) { Copy-Item -LiteralPath (Join-Path $temp 'gh.exe') -Destination (Join-Path $temp "$name.exe") }
    Set-Fixture @{}
    $probeArgs = @('', 'two words', 'embedded"quote', 'trailing\', 'a&b|c', ('unicode-' + [char]0x03bb))
    $stdin = ('a long prompt ' * 2000) + "`n" + [char]0x03bb
    Push-Location $temp
    try { $r = Invoke-Native probe $probeArgs -InputText $stdin } finally { Pop-Location }
    $probe = ConvertFrom-Json $r.Text
    Assert ($r.Code -eq 0 -and $probe.directory -eq $temp) 'native process uses PowerShell working directory'
    Assert (($probe.args | ConvertTo-Json -Compress) -eq ($probeArgs | ConvertTo-Json -Compress)) 'native argument quoting and UTF-8'
    Assert ($probe.input -ceq $stdin -and $r.ErrorText -eq 'stderr diagnostic') 'large UTF-8 stdin and separated stderr'
    $shim = Join-Path $temp 'mock shim.cmd'
    [IO.File]::WriteAllText($shim, ('@"' + (Join-Path $temp 'probe.exe') + '" %*'), $utf8)
    $r = Invoke-Native $shim @('--model', 'provider/model with spaces', 'a&b') -InputText $stdin
    $probe = ConvertFrom-Json $r.Text
    Assert ($r.Code -eq 0 -and $probe.args[1] -eq 'provider/model with spaces' -and $probe.args[2] -eq 'a&b' -and $probe.input -ceq $stdin) 'Windows .cmd launcher with spaces and stdin'
    # A child does not inherit redirected handles here, so the parent can exit.
    $r = Invoke-Native probe @('spawn') -Contained -Memory 1GB
    $childId = [int](Get-Content -LiteralPath (Join-Path $temp 'child-pid'))
    Start-Sleep -Milliseconds 200
    Assert ($r.Code -eq 0 -and !(Get-Process -Id $childId -ErrorAction SilentlyContinue)) 'job object cleans up descendant processes'
    foreach ($script in @('bug_hunt', 'pre_ralph_validate', 'ralph_loop')) {
        $r = Run-Script $script @('/help'); Assert ($r.Code -eq 0 -and $r.Text -match "Usage: $script.ps1 /") "$script help: $($r.ErrorText)"
        $r = Run-Script $script @('--help'); Assert ($r.Code -eq 2) "$script rejects Unix options"
        $valueOption = if ($script -eq 'pre_ralph_validate') { '/label' } else { '/agent' }
        $r = Run-Script $script @($valueOption); Assert ($r.Code -eq 2 -and $r.ErrorText -match 'requires a value') "$script missing option value"
    }
    $r = Run-Script ralph_loop @('/agent', 'pi', '/adaptive-model-and-effort', '/model', 'test'); Assert ($r.Code -eq 2) 'adaptive/fixed conflict'
    $r = Run-Script ralph_loop @('/agent', 'claude', '/effort', 'off'); Assert ($r.Code -eq 1) 'Claude effort validation'
    $r = Run-Script ralph_loop @('/agent', 'pi', '/difficulty-override', 'nope=x:high'); Assert ($r.Code -eq 2) 'override validation'
    $r = Run-Script ralph_loop @('/agent', 'pi', '/quiet', '/verbose'); Assert ($r.Code -eq 1) 'quiet/verbose conflict'
    $r = Run-Script ralph_loop @('/agent', 'pi', '/initial-retry-interval-seconds', '0'); Assert ($r.Code -eq 1) 'retry validation'

    foreach ($value in @('0', '-1', '1.5', 'abc', '01', '2147483648', '999999999999999999999')) {
        $r = Run-Script ralph_loop @('/agent', 'pi', '/max-tickets', $value)
        Assert ($r.Code -eq 2 -and $r.ErrorText -match 'max-tickets') "invalid ticket cap: $value"
    }
    $r = Run-Script ralph_loop @('/agent', 'pi', '/max-tickets')
    Assert ($r.Code -eq 2) 'missing ticket cap'
    foreach ($backend in @('pi', 'claude')) {
        foreach ($cap in @(0, 1, 2)) {
            Set-Fixture @{ issues = @((New-Issue 1), (New-Issue 2), (New-Issue 3)); ticket = (New-Issue 1); sequentialTickets = $true }
            $tokens = @('/agent', $backend, '/repo', 'owner/repo', '/quiet')
            if ($cap) { $tokens += @('/max-tickets', "$cap") }
            $r = Run-Script ralph_loop $tokens
            $expected = if ($cap) { $cap } else { 3 }
            $claims = @(Get-Calls | Where-Object { $_.name -eq 'gh' -and ($_.args -join ' ') -like 'issue edit *' })
            Assert ($r.Code -eq 0 -and $claims.Count -eq $expected) "$backend ticket cap $cap"
            Assert ((Get-Content -LiteralPath (Join-Path $temp 'agent-count')) -eq ($expected + 1)) 'recovery does not consume the ticket cap'
        }
        Set-Fixture @{ issues = @((New-Issue 1), (New-Issue 2)); ticket = (New-Issue 1); sequentialTickets = $true }
        $r = Run-Script ralph_loop @('/agent', $backend, '/repo', 'owner/repo', '/max-tickets', '2', '/once', '/quiet')
        Assert ($r.Code -eq 0 -and (Get-Content -LiteralPath (Join-Path $temp 'agent-count')) -eq 2) 'once remains more restrictive than ticket cap'

        # Each sub-issue consumes its own slot, even when siblings share a parent.
        Set-Fixture @{ issues = @(
            (New-Issue 1),
            (New-Issue 2 @('ready-for-agent') @() "## Parent`n#1"),
            (New-Issue 3 @('ready-for-agent') @() "## Parent`n#1"),
            (New-Issue 4 @('ready-for-agent'))
        ); ticket = (New-Issue 2 @('ready-for-agent') @() "## Parent`n#1"); sequentialTickets = $true }
        $r = Run-Script ralph_loop @('/agent', $backend, '/repo', 'owner/repo', '/max-tickets', '1', '/quiet')
        Assert ($r.Code -eq 0) "$backend sub-issue cap: $($r.ErrorText) $($r.Text)"
        $claims = @(Get-Calls | Where-Object { $_.name -eq 'gh' -and ($_.args -join ' ') -like 'issue edit *' })
        Assert (($claims | ForEach-Object { $_.args[2] }) -join ',' -eq '2') "$backend cap 1 stops before the second sub-issue"
        Set-Fixture @{ issues = @(
            (New-Issue 1),
            (New-Issue 2 @('ready-for-agent') @() "## Parent`n#1"),
            (New-Issue 3 @('ready-for-agent') @() "## Parent`n#1"),
            (New-Issue 4 @('ready-for-agent'))
        ); ticket = (New-Issue 2 @('ready-for-agent') @() "## Parent`n#1"); sequentialTickets = $true }
        $r = Run-Script ralph_loop @('/agent', $backend, '/repo', 'owner/repo', '/max-tickets', '2', '/quiet')
        Assert ($r.Code -eq 0) "$backend sub-issue cap 2: $($r.ErrorText) $($r.Text)"
        $claims = @(Get-Calls | Where-Object { $_.name -eq 'gh' -and ($_.args -join ' ') -like 'issue edit *' })
        Assert (($claims | ForEach-Object { $_.args[2] }) -join ',' -eq '2,3') "$backend cap 2 fills the second slot with the sibling sub-issue"
    }

    $ten = New-Issue 10
    $eleven = New-Issue 11
    $twelve = New-Issue 12 @('ready-for-agent', 'difficulty:easy', 'priority:low') @('tester')
    $thirteen = New-Issue 13 @('ready-for-agent', 'difficulty:hard', 'priority:high') @('someone-else')
    Set-Fixture @{ worktree = ' M dirty.txt'; nodes = @(
        (New-Node $ten @(@{ number = 9; state = 'CLOSED' })),
        (New-Node $eleven @(@{ number = 8; state = 'OPEN' })),
        (New-Node $twelve), (New-Node $thirteen),
        (New-Node (New-Issue 14) @(@{ number = 10; state = 'OPEN' }))
    ) }
    $r = Run-Script ralph_loop @('/agent', 'pi', '/repo', 'owner/repo', '/labels', 'feature:test', '/labels', 'label with spaces', '/dry-run', '/adaptive-model-and-effort', '/difficulty-override', 'easy=custom/model:xhigh')
    Assert ($r.Code -eq 0) "dry run: $($r.ErrorText) $($r.Text)"
    Assert ($r.Text -match '(?m)^1 +#12 +easy +low +custom/model +xhigh +difficulty override:easy') 'assigned-first and override selection'
    Assert ($r.Text -match '(?m)^2 +#10 ') 'closed blocker ignored'
    Assert ($r.Text -match '(?m)^3 +#14 ') 'dependency ordering'
    Assert ($r.Text -match '#11 +blocked by #8 \(outside label filter\)') 'open external blocker'
    Assert ($r.Text -match '#13 +assigned to someone-else, not tester') 'other assignee stranded'
    Assert ($r.Text -notmatch '#9 \(outside label filter\)') 'closed external blocker not reported'
    $query = Get-Content -LiteralPath (Join-Path $temp 'graphql.json') -Raw | ConvertFrom-Json
    Assert ($query.variables.q -eq 'repo:owner/repo is:issue is:open label:"ready-for-agent" label:"feature:test" label:"label with spaces"') 'AND label search'
    Assert (@(Get-Calls | Where-Object { $_.name -in @('pi', 'claude') -or ($_.args -contains 'edit') -or ($_.args -contains 'checkout') }).Count -eq 0) 'dry run never mutates or runs agents'

    foreach ($backend in @('pi', 'claude')) {
        foreach ($cap in @(1, 2, 3, 5)) {
            $r = Run-Script ralph_loop @('/agent', $backend, '/repo', 'owner/repo', '/dry-run', '/max-tickets', "$cap")
            $expected = [Math]::Min($cap, 3)
            Assert ($r.Code -eq 0 -and [regex]::Matches($r.Text, '(?m)^[0-9]+ +#[0-9]+ ').Count -eq $expected) "$backend dry-run cap $cap"
            Assert ($r.Text -match '(?m)^1 +#12 ') 'capped preview preserves assigned-first ranking'
            if ($cap -ge 2) { Assert ($r.Text -match '(?m)^2 +#10 ') 'capped preview ignores closed blockers' }
            if ($cap -ge 3) { Assert ($r.Text -match '(?m)^3 +#14 ') 'capped preview preserves dependency order' }
            if ($cap -le 3) {
                Assert ($r.Text -match "Maximum ticket count \($cap\) reached" -and $r.Text -notmatch 'Not runnable|Nothing stranded') 'cap stops before stranded report'
                Assert ($r.Text -notmatch '#11 |#13 ') 'tickets beyond cap are not listed'
            } else { Assert ($r.Text -match '#11 +blocked by #8') 'oversized cap retains stranded report' }
        }
    }
    Assert (@(Get-Calls | Where-Object { $_.name -in @('pi', 'claude') -or ($_.args -contains 'edit') -or ($_.args -contains 'checkout') }).Count -eq 0) 'capped dry run never mutates or runs agents'

    foreach ($backend in @('pi', 'claude')) {
        $r = Run-Script ralph_loop @('/agent', $backend, '/repo', 'owner/repo', '/dry-run', '/max-tickets', '1', '/bug-hunt', 'hunt/model:high', '/fix-bugs', '/model', 'fix/model', '/effort', 'medium', '/difficulty-override', 'easy=override/model:high', '/use-branch', 'feature/test', '/labels', 'feature:test', '/once')
        Assert ($r.Code -eq 0) "$backend post-loop preview"
        Assert ($r.Text -match "Bug hunt: $backend; model 'hunt/model'; effort 'high'") 'hunt model and effort'
        Assert ($r.Text -match 'Scope: all commits' -and $r.Text -match "Branch filter: current branch 'feature/test' only") 'hunt scope and branch filter'
        Assert ($r.Text -match 'Labels on filed bugs: feature:test') 'filed bug labels'
        Assert ($r.Text -match "fixed at 'fix/model' / 'medium' \(not the hunt model\)") 'fix loop uses ticket model'
        Assert ($r.Text -match 'Difficulty overrides apply: easy=override/model:high') 'fix overrides'
        Assert ($r.Text -match 'ignores /max-tickets' -and $r.Text -match '/once: fixes at most one bug ticket') 'fix limits'
        $r = Run-Script ralph_loop @('/agent', $backend, '/repo', 'owner/repo', '/dry-run', '/bug-hunt-implemented-only', 'hunt/model:high', '/fix-bugs', '/adaptive-model-and-effort', '/difficulty-override', 'hard=custom/model:xhigh')
        Assert ($r.Code -eq 0 -and $r.Text -match 'tickets actually completed by the initial loop' -and $r.Text -match 'skip hunt and fixes if none complete') 'implemented scope and skip condition'
        Assert ($r.Text -match "adaptive from each bug ticket's difficulty label" -and $r.Text -match 'hard: custom/model / xhigh') 'adaptive fix models'
        $r = Run-Script ralph_loop @('/agent', $backend, '/repo', 'owner/repo', '/dry-run', '/bug-hunt', 'hunt/model:high')
        Assert ($r.Code -eq 0 -and $r.Text -match 'findings are filed but not automatically fixed') 'hunt without fixing'
    }
    Assert (@(Get-Calls | Where-Object { $_.name -in @('pi', 'claude') -or ($_.args -contains 'edit') -or ($_.args -contains 'checkout') }).Count -eq 0) 'post-loop preview does not mutate or run agents'
    Set-Fixture @{ nodes = @() }
    $r = Run-Script ralph_loop @('/agent', 'pi', '/repo', 'owner/repo', '/dry-run', '/bug-hunt-implemented-only', 'hunt/model:high', '/fix-bugs')
    Assert ($r.Code -eq 0 -and $r.Text -match 'No open tickets match' -and $r.Text -match 'skip hunt and fixes if none complete') 'empty preview retains post-loop plan'
    $r = Run-Script ralph_loop @('/agent', 'pi', '/repo', 'owner/repo', '/dry-run', '/fix-bugs')
    Assert ($r.Code -eq 0 -and $r.Text -match 'Bug hunt: disabled. Bug-fix loop: disabled') 'fixing without hunting is disabled'

    # Sub-issues count separately; parent specification issues are ignored.
    $spec = New-Issue 1
    $subOne = New-Issue 2 @('ready-for-agent') @() "## Parent`n#1"
    $subTwo = New-Issue 3 @('ready-for-agent') @() "## Parent`n#1"
    $standalone = New-Issue 4
    Set-Fixture @{ nodes = @(
        (New-Node $spec),
        (New-Node $subOne),
        (New-Node $subTwo @(@{ number = 2; state = 'OPEN' })),
        (New-Node $standalone)
    ) }
    $r = Run-Script ralph_loop @('/agent', 'pi', '/repo', 'owner/repo', '/dry-run')
    Assert ($r.Code -eq 0) "sub-issue dry run: $($r.ErrorText) $($r.Text)"
    Assert ($r.Text -match '1 parent specification issue\(s\) ignored') 'parent specification note'
    Assert ($r.Text -match '(?m)^1 +#2 ' -and $r.Text -match '(?m)^2 +#3 ' -and $r.Text -match '(?m)^3 +#4 ') 'sub-issue chain order'
    Assert ($r.Text -match 'All 3 eligible tickets are runnable') 'parent specification excluded from the total'
    Assert ($r.Text -notmatch '(?m)^[0-9]+ +#1 ') 'parent specification never listed as a ticket'
    $r = Run-Script ralph_loop @('/agent', 'pi', '/repo', 'owner/repo', '/dry-run', '/max-tickets', '1')
    Assert ($r.Code -eq 0 -and [regex]::Matches($r.Text, '(?m)^[0-9]+ +#[0-9]+ ').Count -eq 1) 'each sub-issue consumes its own cap slot'
    Assert ($r.Text -match 'Maximum ticket count \(1\) reached' -and $r.Text -notmatch '#3 |#4 |Not runnable') 'cap stops before the second sub-issue'
    $r = Run-Script ralph_loop @('/agent', 'pi', '/repo', 'owner/repo', '/dry-run', '/max-tickets', '2')
    Assert ($r.Code -eq 0 -and [regex]::Matches($r.Text, '(?m)^[0-9]+ +#[0-9]+ ').Count -eq 2) 'two sub-issues fill two cap slots'
    Assert ($r.Text -match '(?m)^2 +#3 ' -and $r.Text -notmatch '#4 |Not runnable') 'cap 2 preserves sibling dependency order'

    Set-Fixture @{ nodes = @((New-Node (New-Issue 1 @('difficulty:hard', 'difficulty:easy'))), (New-Node (New-Issue 2 @('ready-for-agent')))) }
    $r = Run-Script ralph_loop @('/agent', 'claude', '/dry-run', '/adaptive-model-and-effort')
    Assert ($r.Code -eq 0 -and $r.Text -match '\(conflict\)' -and $r.Text -match '\(unresolved\)') 'preview unresolved/conflicting difficulties'
    Set-Fixture @{}
    $r = Run-Script ralph_loop @('/agent', 'pi', '/dry-run'); Assert ($r.Code -eq 0 -and $r.Text -match 'No open tickets match') 'empty dry run'

    Set-Fixture @{ issues = @((New-Issue 1), (New-Issue 2 @('ready-for-agent', 'difficulty:small', 'priority:2') @() "## Parent`n#1")); blocked = @{ '2' = 1 } }
    $r = Run-Script pre_ralph_validate @('/label', 'feature:test')
    Assert ($r.Code -eq 0 -and $r.Text -match '1 parent specification issue\(s\) ignored' -and $r.Text -match 'Validation passed: 1 ticket\(s\), 1 blocked') "validation success: $($r.ErrorText)"
    Set-Fixture @{ issues = @((New-Issue 3 @('difficulty:easy', 'priority:nope'))) }
    $r = Run-Script pre_ralph_validate @('/label', 'feature:test')
    Assert ($r.Code -eq 1 -and $r.ErrorText -match 'missing ready-for-agent' -and $r.ErrorText -match 'unsupported difficulty' -and $r.ErrorText -match 'unsupported priority' -and $r.ErrorText -match 'native GitHub blocked_by') 'validation failures match shell (including easy label)'
    Set-Fixture @{}
    $r = Run-Script pre_ralph_validate @('/label', 'feature:test'); Assert ($r.Code -eq 1) 'empty validation'
    Set-Fixture @{ ghCode = 7 }
    $r = Run-Script pre_ralph_validate @('/label', 'feature:test'); Assert ($r.Code -eq 2) 'validation API failure exit'

    Set-Fixture @{ agentOutput = '{"type":"test","message":"hello"}' }
    $r = Run-Script bug_hunt @('/agent', 'pi', '/model', 'test/model', '/effort', 'high', '/publish', 'docs', '/branch-only', '/labels', 'one,two', '/labels', 'space & unicode label')
    Assert ($r.Code -eq 0) "bug hunt: $($r.ErrorText) $($r.Text)"
    $prompt = Get-Content -LiteralPath (Join-Path $temp 'prompt.txt') -Raw -Encoding UTF8
    Assert ($prompt -match 'origin/main\.\.HEAD.*3 commits' -and $prompt -match 'git diff base-commit\.\.HEAD') 'branch scope prompt'
    Assert ($prompt -match 'docs/tickets/bug-hunt/' -and $prompt -match '(?m)^- one$' -and $prompt -match '(?m)^- space & unicode label$') 'docs publishing and repeated labels prompt'
    Assert ($prompt -match '`blockedBy`' -and $prompt -match '`-fanalyzer`') 'prompt literal backticks retained'
    $shell = [IO.File]::ReadAllText((Join-Path $root 'bug_hunt.sh')).Replace("`r`n", "`n")
    $template = [regex]::Match($shell, '(?ms)^prompt=\$\(cat <<EOF\n(.*?)\nEOF\n\)').Groups[1].Value
    $scope = [regex]::Match($shell, '(?ms)^    scope_prompt=\$\(cat <<EOF\n(.*?)\nEOF\n\)').Groups[1].Value
    $scope = $scope.Replace('$current_branch', 'feature/test').Replace('$default_ref', 'origin/main').Replace('$merge_base', 'base-commit').Replace('$commit_range', 'origin/main..HEAD').Replace('$unique_count', '3')
    $publish = [regex]::Matches($shell, '(?ms)^    publish_prompt=\$\(cat <<''EOF''\n(.*?)\nEOF\n\)')[1].Groups[1].Value
    $publish += "`n`nApply the label `"assignee:test/model`" to every published ticket (in YAML front matter for docs). For tracker publication, create this label with gh label create --force if it does not exist before applying it. Verify it is present on every published ticket."
    $publish += "`n`nApply each of these additional labels to every published ticket (without duplicating labels):`n- one`n- two`n- space & unicode label"
    $expectedPrompt = $template.Replace('$scope_prompt', $scope).Replace('$publish_prompt', $publish).Replace('\`', '`')
    Assert ($prompt.Replace("`r`n", "`n") -ceq $expectedPrompt) 'complete bug-hunt prompt matches Bash verbatim'
    $agentCall = @(Get-Calls | Where-Object { $_.name -eq 'pi' })[0]
    Assert (($agentCall.args -join '|') -eq '--mode|json|--print|--approve|--model|test/model|--thinking|high|--name|bug-hunt') 'agent flags remain Unix-style'
    $log = Get-ChildItem -LiteralPath (Join-Path $temp 'pi-bug-hunt') -Filter '*.log' | Select-Object -Last 1 | Get-Content -Raw
    Assert ($log -match '"type":"test"' -and $log -match 'agent diagnostic') 'raw JSON and stderr logged'
    Set-Fixture @{ agentCodes = @(7) }
    $r = Run-Script bug_hunt @('/agent', 'claude', '/model', 'opus', '/effort', 'high', '/publish', 'tracker')
    Assert ($r.Code -eq 7) "bug hunt propagates agent failure: $($r.Code) $($r.ErrorText) $($r.Text)"
    $prompt = Get-Content -LiteralPath (Join-Path $temp 'prompt.txt') -Raw
    Assert ($prompt -match 'GitHub issue tracker' -and $prompt -match 'Review the entire codebase') 'tracker/full codebase prompt'
    Assert ($prompt.Contains('Apply the label "assignee:opus"')) 'tracker model label'

    Set-Fixture @{ issues = @($ten); ticket = $ten; completeAfter = 2; agentCodes = @(0, 0) }
    $r = Run-Script ralph_loop @('/agent', 'pi', '/once', '/quiet')
    Assert ($r.Code -eq 0) "live recovery: $($r.ErrorText) $($r.Text)"
    Assert ((Get-Content -LiteralPath (Join-Path $temp 'agent-count')) -eq '2') 'successful-but-incomplete recovery'
    $recoveryPrompt = Get-Content -LiteralPath (Join-Path $temp 'prompt.txt') -Raw -Encoding UTF8
    Assert ($recoveryPrompt -match '## Recovery attempt') 'recovery prompt'
    $shell = [IO.File]::ReadAllText((Join-Path $root 'ralph_loop.sh')).Replace("`r`n", "`n")
    $template = [regex]::Match($shell, '(?ms)^    cat <<EOF\n(Implement GitHub ticket.*?)\nEOF').Groups[1].Value
    $expectedPrompt = $template.Replace('$(jq -r .number <<<"$issue")', '10').Replace('$(jq -r .title <<<"$issue")', 'Ticket 10').Replace('$(jq -r .url <<<"$issue")', 'https://example.test/10').Replace('$(jq -r .body <<<"$issue")', '').Replace('$comments', '(No comments.)')
    Assert ($expectedPrompt.Length -gt 1000 -and $recoveryPrompt.Replace("`r`n", "`n").StartsWith($expectedPrompt + "`n`n## Recovery attempt")) 'complete implementation prompt matches Bash verbatim'
    Assert ($r.Text -match 'Total tokens spent: 10' -and $r.Text -notmatch 'agent output') 'usage accumulated and quiet respected'
    Assert (@(Get-Calls | Where-Object { $_.name -eq 'gh' -and $_.args -contains 'edit' }).Count -eq 1) 'claim once'

    foreach ($message in @('HTTP 503 service unavailable', 'usage limit reached')) {
        Set-Fixture @{ issues = @($ten); ticket = $ten; completeAfter = 2; agentCodes = @(1, 0); agentOutput = $message }
        $r = Run-Script ralph_loop @('/agent', 'claude', '/once', '/initial-retry-interval-seconds', '1', '/usage-poll-seconds', '1')
        Assert ($r.Code -eq 0 -and $r.ErrorText -match 'Retrying in 1 seconds') "retry: $message / $($r.ErrorText)"
    }
    foreach ($backend in @('pi', 'claude')) {
        foreach ($firstCode in @(0, 1)) {
            Set-Fixture @{ issues = @($ten); ticket = $ten; completeAfter = 2; agentCodes = @($firstCode, 0); agentOutput = 'HTTP 503 service unavailable' }
            $r = Run-Script ralph_loop @('/agent', $backend, '/once', '/quiet', '/initial-retry-interval-seconds', '1')
            Assert ($r.Code -eq 0) "$backend prompt attempts: $($r.ErrorText)"
            $initialPrompt = [IO.File]::ReadAllText((Join-Path $temp 'prompt-1.txt')).Replace("`r`n", "`n")
            $retryPrompt = [IO.File]::ReadAllText((Join-Path $temp 'prompt-2.txt')).Replace("`r`n", "`n")
            Assert-StagedValidation $initialPrompt
            Assert-StagedValidation $retryPrompt
            Assert ($initialPrompt -ceq $expectedPrompt) "$backend initial prompt matches Bash verbatim"
            if ($firstCode -eq 0) {
                Assert ($retryPrompt.StartsWith($initialPrompt + "`n`n## Recovery attempt")) "$backend recovery retains original prompt"
            } else {
                Assert ($retryPrompt -ceq $initialPrompt) "$backend provider retry retains original prompt"
            }
        }
    }
    foreach ($backend in @('pi', 'claude')) {
        # A stale listing of an already-closed issue never claims or launches it.
        Set-Fixture @{ issues = @($ten); ticket = $ten; completeAfter = 0 }
        $r = Run-Script ralph_loop @('/agent', $backend, '/once')
        Assert ($r.Code -eq 0 -and $r.Text -match 'Skipping already-closed ticket #10') "$backend skips stale closed issue"
        Assert (@(Get-Calls | Where-Object { $_.name -in @('pi', 'claude') -or ($_.args -contains 'edit') }).Count -eq 0) "$backend closed issue never claimed or launched"

        # No new commit is needed, and repeated stale results are ignored.
        Set-Fixture @{ issues = @($ten); ticket = $ten; completeAfter = 1; unchangedHead = $true }
        $r = Run-Script ralph_loop @('/agent', $backend)
        Assert ($r.Code -eq 0 -and (Get-Content -LiteralPath (Join-Path $temp 'agent-count')) -eq '1') "$backend completes with unchanged HEAD and suppresses stale re-selection"

        Set-Fixture @{ issues = @($ten); ticket = $ten; completeAfter = 2; dirtyAfter = 2; unchangedHead = $true }
        $r = Run-Script ralph_loop @('/agent', $backend, '/once', '/quiet')
        Assert ($r.Code -eq 0 -and (Get-Content -LiteralPath (Join-Path $temp 'agent-count')) -eq '3') "$backend recovers closed dirty worktree"
        $openPrompt = [IO.File]::ReadAllText((Join-Path $temp 'prompt-2.txt'))
        $dirtyPrompt = [IO.File]::ReadAllText((Join-Path $temp 'prompt-3.txt'))
        Assert ($openPrompt -match 'Completion check: Issue state is OPEN, not CLOSED\.') "$backend reports open issue"
        Assert ($dirtyPrompt -match 'Completion check: Issue is closed but the tracked worktree is dirty\.' -and $dirtyPrompt -notmatch 'without closing ticket') "$backend reports dirty worktree rather than false closure failure"
    }
    Set-Fixture @{ issues = @($ten); ticket = $ten; completeAfter = 5; agentCodes = @(4) }
    $r = Run-Script ralph_loop @('/agent', 'pi', '/once')
    Assert ($r.Code -eq 1 -and $r.ErrorText -match 'non-retryable implementation reason') 'non-retryable agent failure'
    Set-Fixture @{ worktree = ' M dirty.txt' }
    $r = Run-Script ralph_loop @('/agent', 'pi'); Assert ($r.Code -eq 1 -and $r.ErrorText -match 'tracked worktree is not clean') 'live dirty worktree guard'

    Set-Fixture @{}
    $r = Run-Script ralph_loop @('/agent', 'pi', '/labels', 'feature:test', '/use-branch', 'feature/test', '/bug-hunt', 'test/model:high', '/fix-bugs')
    Assert ($r.Code -eq 0 -and $r.Text -match 'post-hunt bug-fix loop') "post-loop hunt: $($r.ErrorText) $($r.Text)"
    $lists = @(Get-Calls | Where-Object { $_.name -eq 'gh' -and $_.args[0] -eq 'issue' -and $_.args[1] -eq 'list' })
    Assert ($lists.Count -eq 2 -and $lists[1].args -contains 'bug' -and $lists[1].args -contains 'feature:test') 'bug-fix loop retains filters'
    Set-Fixture @{ agentCodes = @(8) }
    $r = Run-Script ralph_loop @('/agent', 'pi', '/bug-hunt', 'test/model:high', '/fix-bugs')
    Assert ($r.Code -eq 1 -and $r.ErrorText -match 'Bug hunt failed') 'failed hunt prevents fixes'

    # /tickets scopes the hunt to the commits referencing those tickets.
    Set-Fixture @{ logLines = @('abc1234 Implement the thing (#7)', 'def5678 Follow-up work (#9)') }
    $r = Run-Script bug_hunt @('/agent', 'pi', '/model', 'test/model', '/effort', 'high', '/publish', 'docs', '/tickets', '7,9')
    Assert ($r.Code -eq 0) "ticket-scoped hunt: $($r.ErrorText) $($r.Text)"
    $prompt = (Get-Content -LiteralPath (Join-Path $temp 'prompt.txt') -Raw -Encoding UTF8).Replace("`r`n", "`n")
    Assert ($prompt -match 'Confine the hunt to bugs introduced by the changes implemented for these tickets: #7, #9\.' -and $prompt -match 'git show') 'ticket scope prompt'
    Assert ($prompt -notmatch 'Review the entire codebase') 'scoped hunt is not codebase-wide'
    $shell = [IO.File]::ReadAllText((Join-Path $root 'bug_hunt.sh')).Replace("`r`n", "`n")
    $ticketTemplate = [regex]::Matches($shell, '(?ms)^    scope_prompt=\$\(cat <<EOF\n(.*?)\nEOF\n\)')[1].Groups[1].Value
    $ticketTemplate = $ticketTemplate.Replace('$ticket_list', '#7, #9').Replace('$range_description', 'HEAD').Replace('$ticket_commits', "- #7: abc1234 Implement the thing (#7)`n- #9: def5678 Follow-up work (#9)").Replace('\`', '`')
    Assert ($prompt.Contains($ticketTemplate)) 'ticket scope prompt matches Bash verbatim'
    Set-Fixture @{}
    $r = Run-Script bug_hunt @('/agent', 'pi', '/model', 'test/model', '/effort', 'high', '/publish', 'docs', '/tickets', '77')
    Assert ($r.Code -eq 0 -and $r.Text -match 'No commits in HEAD reference tickets #77; nothing to hunt\.') 'empty ticket scope launches no agent'
    Assert (!(Test-Path -LiteralPath (Join-Path $temp 'prompt.txt'))) 'empty ticket scope never runs the agent'
    $r = Run-Script bug_hunt @('/agent', 'pi', '/model', 'test/model', '/effort', 'high', '/publish', 'docs', '/tickets', '7,abc')
    Assert ($r.Code -eq 2 -and $r.ErrorText -match 'tickets entries must be positive integers') 'invalid ticket number'

    # /bug-hunt-implemented-only implies the hunt and scopes it to the implemented tickets.
    Set-Fixture @{ issues = @((New-Issue 1), (New-Issue 2)); ticket = (New-Issue 1); sequentialTickets = $true; logLines = @('c0ffee1 Implement #1', 'c0ffee2 Implement #2') }
    $r = Run-Script ralph_loop @('/agent', 'pi', '/repo', 'owner/repo', '/bug-hunt-implemented-only', 'test:high', '/quiet')
    Assert ($r.Code -eq 0) "implemented-only hunt: $($r.ErrorText) $($r.Text)"
    $prompt = Get-Content -LiteralPath (Join-Path $temp 'prompt.txt') -Raw -Encoding UTF8
    Assert ($prompt -match 'these tickets: #1, #2\.' -and $prompt -match '- #2: c0ffee2 Implement #2') 'post-loop hunt scoped to implemented tickets'
    $r = Run-Script ralph_loop @('/agent', 'pi', '/bug-hunt', 'test:high', '/bug-hunt-implemented-only', 'test:high')
    Assert ($r.Code -eq 2 -and $r.ErrorText -match 'mutually exclusive') 'hunt options are mutually exclusive'
    $r = Run-Script ralph_loop @('/agent', 'pi', '/bug-hunt-implemented-only', 'test')
    Assert ($r.Code -eq 2 -and $r.ErrorText -match '/bug-hunt-implemented-only must be in the form MODEL:EFFORT') 'implemented-only spec validation'
    Set-Fixture @{}
    $r = Run-Script ralph_loop @('/agent', 'pi', '/repo', 'owner/repo', '/bug-hunt-implemented-only', 'test:high')
    Assert ($r.Code -eq 0 -and $r.Text -match 'skipping the scoped bug hunt') 'empty implemented set skips the hunt'
    Assert (!(Test-Path -LiteralPath (Join-Path $temp 'agent-count'))) 'skipped hunt never launches an agent'

    foreach ($backend in @('pi', 'claude')) {
        # The main loop stops at the cap; the bug-fix loop ignores it and fixes every bug ticket.
        Set-Fixture @{ issues = @((New-Issue 1), (New-Issue 2), (New-Issue 3)); bugIssues = @((New-Issue 4), (New-Issue 5)); ticket = (New-Issue 1); sequentialTickets = $true }
        $r = Run-Script ralph_loop @('/agent', $backend, '/repo', 'owner/repo', '/max-tickets', '2', '/bug-hunt', 'test:high', '/fix-bugs', '/quiet')
        Assert ($r.Code -eq 0) "$backend uncapped bug-fix loop: $($r.ErrorText) $($r.Text)"
        $claims = @(Get-Calls | Where-Object { $_.name -eq 'gh' -and ($_.args -join ' ') -like 'issue edit *' })
        Assert ($claims.Count -eq 4) "$backend bug-fix loop ignores the ticket cap"
    }
    Write-Host "ok - $script:checks Windows script checks passed"
} finally {
    $env:PATH = $oldPath; $env:TMPDIR = $oldTmp
    Remove-Item Env:DEV_SCRIPTS_TEST_DIR -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $temp -Recurse -Force
}
