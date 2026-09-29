# Shared Windows PowerShell 5.1+ support. No Bash or Unix utilities required.
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = New-Object Text.UTF8Encoding($false)

function Stop-Script([string] $Message, [int] $Code = 1) {
    [Console]::Error.WriteLine("error: $Message")
    exit $Code
}
function Write-WarningLine([string] $Message) { [Console]::Error.WriteLine("warning: $Message") }
function Read-Options([object[]] $Tokens, [string[]] $Values, [string[]] $Flags, [scriptblock] $Usage) {
    $result = @{}
    for ($i = 0; $i -lt $Tokens.Count; $i++) {
        $key = [string]$Tokens[$i]
        if ($key -cin @('/help', '/h', '/?')) { & $Usage; exit 0 }
        if ($key -cin $Values) {
            if (++$i -ge $Tokens.Count) { Stop-Script "$key requires a value" 2 }
            if (!$result.ContainsKey($key)) { $result[$key] = @() }
            $result[$key] += [string]$Tokens[$i]
        } elseif ($key -cin $Flags) { $result[$key] = $true }
        else { [Console]::Error.WriteLine("error: unknown argument: $key"); & $Usage; exit 2 }
    }
    return $result
}
function Get-Option($Options, [string] $Name, [string] $Default = '') {
    if ($Options.ContainsKey($Name)) { return [string]$Options[$Name][-1] }
    return $Default
}
function Get-Labels($Options) {
    if ($Options.ContainsKey('/labels')) {
        foreach ($spec in $Options['/labels']) { foreach ($label in $spec.Split(',')) { if ($label.Length) { $label } } }
    }
}
function Assert-Agent([string] $Agent, [string] $Effort, [int] $UnsupportedClaudeCode = 2) {
    if ($Agent -cnotin @('pi', 'claude')) { Stop-Script '/agent must be pi or claude' 2 }
    if ($Effort -cnotmatch '^(off|minimal|low|medium|high|xhigh|max)$') { Stop-Script "unsupported /effort '$Effort'" 2 }
    if ($Agent -ceq 'claude' -and $Effort -cnotmatch '^(low|medium|high|xhigh|max)$') {
        Stop-Script "effort '$Effort' is not supported by claude; use low, medium, high, xhigh, or max" $UnsupportedClaudeCode
    }
}
function Require-Commands([string[]] $Names, [int] $Code = 1) {
    foreach ($name in $Names) {
        if (!(Get-Command $name -CommandType Application -ErrorAction SilentlyContinue)) {
            Stop-Script "$name is required but was not found on PATH." $Code
        }
    }
}
function Get-Field($Object, [string] $Name, $Default = $null) {
    if ($null -ne $Object -and $null -ne $Object.PSObject.Properties[$Name]) { return $Object.$Name }
    return $Default
}
function Get-LabelNames($Issue) { foreach ($label in @(Get-Field $Issue 'labels' @())) { [string]$label.name } }

# ProcessStartInfo avoids PowerShell 5.1's lossy native quote handling. Agents
# receive prompts over stdin, avoiding cmd.exe's 8191-character command limit.
# The queue keeps stdout/stderr live without requiring PowerShell runspaces on
# the asynchronous reader threads. A Job Object owns bug-hunt descendants and
# optionally limits their combined committed memory.
if (-not ('DevScripts.NativeProcess' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Collections.Concurrent;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading.Tasks;
namespace DevScripts {
    public sealed class NativeLine {
        public string Text;
        public bool Error;
        public NativeLine(string text, bool error) { Text = text; Error = error; }
    }
    public sealed class NativeProcess : IDisposable {
        public readonly ConcurrentQueue<NativeLine> Lines = new ConcurrentQueue<NativeLine>();
        public Process Process;
        Task input;
        IntPtr job;
        public static string Quote(string value) {
            var b = new StringBuilder("\""); int slashes = 0;
            foreach (char c in value) {
                if (c == '\\') { slashes++; continue; }
                if (c == '"') { b.Append('\\', slashes * 2 + 1); b.Append(c); }
                else { b.Append('\\', slashes); b.Append(c); }
                slashes = 0;
            }
            b.Append('\\', slashes * 2); b.Append('"'); return b.ToString();
        }
        public void Start(string file, string[] args, string stdin, bool contained, ulong memory, string directory) {
            var command = new StringBuilder();
            foreach (string arg in args) { if (command.Length > 0) command.Append(' '); command.Append(Quote(arg)); }
            var info = new ProcessStartInfo(file, command.ToString());
            if (file.EndsWith(".cmd", StringComparison.OrdinalIgnoreCase) || file.EndsWith(".bat", StringComparison.OrdinalIgnoreCase)) {
                // npm's Windows shims are batch files, not executable images.
                info.FileName = Environment.GetEnvironmentVariable("ComSpec") ?? "cmd.exe";
                info.Arguments = "/d /s /c \"" + Quote(file) + " " + command + "\"";
            }
            info.WorkingDirectory = directory;
            info.UseShellExecute = false; info.CreateNoWindow = true;
            info.RedirectStandardOutput = true; info.RedirectStandardError = true; info.RedirectStandardInput = true;
            info.StandardOutputEncoding = new UTF8Encoding(false); info.StandardErrorEncoding = new UTF8Encoding(false);
            Process = new Process { StartInfo = info };
            Process.OutputDataReceived += (s, e) => { if (e.Data != null) Lines.Enqueue(new NativeLine(e.Data, false)); };
            Process.ErrorDataReceived += (s, e) => { if (e.Data != null) Lines.Enqueue(new NativeLine(e.Data, true)); };
            if (contained) {
                job = CreateJobObject(IntPtr.Zero, null);
                if (job == IntPtr.Zero) throw new System.ComponentModel.Win32Exception();
                var limits = new JOBOBJECT_EXTENDED_LIMIT_INFORMATION();
                limits.BasicLimitInformation.LimitFlags = 0x2000; // KILL_ON_JOB_CLOSE
                if (memory > 0) { limits.BasicLimitInformation.LimitFlags |= 0x200; limits.JobMemoryLimit = new UIntPtr(memory); }
                if (!SetInformationJobObject(job, 9, ref limits, (uint)Marshal.SizeOf(limits))) throw new System.ComponentModel.Win32Exception();
            }
            Process.Start();
            if (job != IntPtr.Zero && !AssignProcessToJobObject(job, Process.Handle)) {
                Process.Kill(); throw new System.ComponentModel.Win32Exception();
            }
            Process.BeginOutputReadLine(); Process.BeginErrorReadLine();
            input = Task.Run(() => {
                try {
                    if (stdin != null) {
                        byte[] bytes = new UTF8Encoding(false).GetBytes(stdin);
                        Process.StandardInput.BaseStream.Write(bytes, 0, bytes.Length);
                    }
                } catch (System.IO.IOException) { } finally { Process.StandardInput.Close(); }
            });
        }
        public bool Finished { get { return Process.HasExited; } }
        public int Finish() { Process.WaitForExit(); input.Wait(); return Process.ExitCode; }
        public void Dispose() {
            if (job != IntPtr.Zero) { CloseHandle(job); job = IntPtr.Zero; }
            if (Process != null) { Process.Dispose(); Process = null; }
        }
        [StructLayout(LayoutKind.Sequential)] struct JOBOBJECT_BASIC_LIMIT_INFORMATION {
            public long PerProcessUserTimeLimit, PerJobUserTimeLimit;
            public uint LimitFlags;
            public UIntPtr MinimumWorkingSetSize, MaximumWorkingSetSize;
            public uint ActiveProcessLimit;
            public UIntPtr Affinity;
            public uint PriorityClass, SchedulingClass;
        }
        [StructLayout(LayoutKind.Sequential)] struct IO_COUNTERS { public ulong a,b,c,d,e,f; }
        [StructLayout(LayoutKind.Sequential)] struct JOBOBJECT_EXTENDED_LIMIT_INFORMATION {
            public JOBOBJECT_BASIC_LIMIT_INFORMATION BasicLimitInformation;
            public IO_COUNTERS IoInfo;
            public UIntPtr ProcessMemoryLimit, JobMemoryLimit, PeakProcessMemoryUsed, PeakJobMemoryUsed;
        }
        [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)] static extern IntPtr CreateJobObject(IntPtr attributes, string name);
        [DllImport("kernel32.dll", SetLastError=true)] static extern bool SetInformationJobObject(IntPtr job, int type, ref JOBOBJECT_EXTENDED_LIMIT_INFORMATION info, uint length);
        [DllImport("kernel32.dll", SetLastError=true)] static extern bool AssignProcessToJobObject(IntPtr job, IntPtr process);
        [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr handle);
    }
}
'@
}
function Remove-Control([string] $Text) {
    $esc = [char]27
    $Text = $Text -replace "$esc\][^\a]*(?:\a|$esc\\)", ''
    $Text = $Text -replace "$esc[PX^_].*?$esc\\", ''
    $Text = $Text -replace "$esc\[[0-?]*[ -/]*[@-~]", ''
    $Text = $Text -replace "$esc[@-_]", ''
    return $Text -replace '[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]', ''
}
function Invoke-Native {
    param([string] $Command, [string[]] $Arguments = @(), [AllowNull()][string] $InputText = $null,
        [string] $LogPath = '', [switch] $Live, [switch] $StripControl, [switch] $JsonLines,
        [switch] $Contained, [UInt64] $Memory = 0)
    $executable = Get-Command $Command -CommandType Application -ErrorAction Stop | Select-Object -First 1
    $process = New-Object DevScripts.NativeProcess
    $lines = New-Object 'System.Collections.Generic.List[string]'
    $errors = New-Object 'System.Collections.Generic.List[string]'
    $writer = $null
    try {
        if ($LogPath) { $writer = New-Object IO.StreamWriter($LogPath, $false, (New-Object Text.UTF8Encoding($false))); $writer.AutoFlush = $true }
        $process.Start($executable.Source, $Arguments, $InputText, $Contained.IsPresent, $Memory, (Get-Location).ProviderPath)
        $finished = $false
        do {
            if ($process.Finished -and !$finished) { $code = $process.Finish(); $finished = $true }
            $entry = $null
            while ($process.Lines.TryDequeue([ref]$entry)) {
                $line = $entry.Text
                if ($StripControl) { $line = Remove-Control $line }
                if ($writer) { $writer.WriteLine($line) }
                elseif ($entry.Error) { $errors.Add($line) }
                else { $lines.Add($line) }
                if ($Live) {
                    $display = $line
                    if ($JsonLines) { try { $display = ConvertTo-Json -InputObject (ConvertFrom-Json $line) -Depth 100 } catch { } }
                    Write-Host $display
                }
            }
            if (!$finished) { Start-Sleep -Milliseconds 30 }
        } until ($finished)
        return [pscustomobject]@{ Code = $code; Text = ($lines -join "`n"); ErrorText = ($errors -join "`n") }
    } finally { if ($writer) { $writer.Dispose() }; $process.Dispose() }
}
function Invoke-Checked([string] $Command, [string[]] $Arguments, [string] $InputText = '', [int] $FailureCode = 1) {
    $r = Invoke-Native $Command $Arguments -InputText $InputText
    if ($r.Code -ne 0) { Stop-Script "$Command failed (exit $($r.Code)): $($r.ErrorText) $($r.Text)" $FailureCode }
    if ($r.ErrorText) { [Console]::Error.WriteLine($r.ErrorText) }
    return $r.Text
}
function Invoke-GhJson([string[]] $Arguments, [string] $InputText = '', [int] $FailureCode = 1) {
    $text = Invoke-Checked gh $Arguments $InputText $FailureCode
    try { $parsed = ConvertFrom-Json $text; return $parsed } catch { Stop-Script "Invalid JSON from gh: $text" $FailureCode }
}
function Enter-Repository {
    $r = Invoke-Native git @('rev-parse', '--show-toplevel')
    if ($r.Code -ne 0) { Stop-Script 'Run this script from inside a Git repository.' }
    Set-Location -LiteralPath $r.Text.Trim()
    return $r.Text.Trim()
}
function New-LogDirectory([string] $Name) {
    $root = if ($env:TMPDIR) { $env:TMPDIR } else { [IO.Path]::GetTempPath() }
    $path = Join-Path $root $Name
    [void][IO.Directory]::CreateDirectory($path)
    return $path
}
function Get-BlockedCount([string] $Repository, [int] $Number, [int] $FailureCode = 1) {
    $issue = Invoke-GhJson @('api', "repos/$Repository/issues/$Number") '' $FailureCode
    return [int](Get-Field (Get-Field $issue 'issue_dependencies_summary') 'blocked_by' 0)
}
function Get-ParentNumbers($Issues) {
    foreach ($issue in $Issues) {
        if ((Get-Field $issue 'body' '') -match '(?im)^## Parent\s*\r?\n+\s*#(?<number>[0-9]+)') { [int]$Matches.number }
    }
}
