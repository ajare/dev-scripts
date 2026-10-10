# Development scripts

The three root-level Bash scripts also have native Windows PowerShell versions:

| Bash | Windows |
| --- | --- |
| `bug_hunt.sh` | `bug_hunt.ps1` |
| `pre_ralph_validate.sh` | `pre_ralph_validate.ps1` |
| `ralph_loop.sh` | `ralph_loop.ps1` |

## Windows

Requires Windows PowerShell 5.1 or PowerShell 7 on Windows. Keep
`windows_common.ps1` beside the three scripts. No Bash, WSL, jq, Perl, curl, or
other Unix utilities are needed. Install the native Windows commands on PATH:

- `bug_hunt.ps1`: Git and the selected `pi` or `claude` agent; GitHub CLI (`gh`)
  when publishing to the tracker (also used as a fallback for branch discovery).
- `pre_ralph_validate.ps1`: authenticated GitHub CLI.
- `ralph_loop.ps1`: Git, authenticated GitHub CLI, and the selected agent.

Use `/option value`, not `--option value`. Quote values containing spaces, and
quote comma-separated labels when calling from PowerShell. Options such as
`/labels` and `/difficulty-override` may be repeated. `/help` lists all options.
The flags passed **internally** to Git, GitHub CLI, and agents remain unchanged.

```powershell
.\pre_ralph_validate.ps1 /label 'feature:example'

.\ralph_loop.ps1 /agent pi /labels 'feature:example' /dry-run

.\ralph_loop.ps1 /agent pi /labels 'feature:example' `
    /use-branch feature/example /adaptive-model-and-effort `
    /bug-hunt 'openai-codex/gpt-5.6-sol:high' /fix-bugs

.\bug_hunt.ps1 /agent claude /model opus /effort high `
    /publish docs /branch-only /labels 'bug-hunt,feature:example'
```

From Command Prompt (or when a local execution policy prevents direct use):

```bat
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\ralph_loop.ps1 /agent pi /dry-run
```

The ports preserve the existing selection rules, validation rules, agent prompts,
retry/recovery behavior, and reporting. In particular, the validator retains the
Bash validator's accepted difficulty labels; it does not add `difficulty:easy`.
Post-loop bug hunting uses the **sibling** `bug_hunt.ps1`, so the scripts work both
at a repository root and in a `tools` directory.

### Windows-specific implementation

- Agent prompts travel over UTF-8 stdin rather than command-line arguments to
  avoid Windows command-line length limits. Both agents' print modes support this.
- Logs use `TMPDIR` if set, otherwise the Windows temporary directory.
- Bug hunts use a Windows Job Object instead of systemd to clean up descendant
  processes and limit their combined committed memory. `BUG_HUNT_MEMORY_MAX`
  defaults to `16G`; byte counts and binary suffixes (`K`, `M`, `G`, etc.) are
  accepted. Use `0` to disable the memory limit while retaining cleanup. Windows
  PowerShell removes environment variables assigned an empty string, so use `0`
  rather than an empty assignment to override the default there. Windows does
  not provide systemd's separate `MemorySwapMax=0` setting.

### Ticket limit

Use `ralph_loop.sh --agent pi --max-tickets 5` or
`ralph_loop.ps1 /agent pi /max-tickets 5` to complete at most five tickets.
Omitting the option leaves the ticket count unlimited. The value must be a
positive integer (1–2147483647).

The budget is shared by the initial and post-hunt bug-fix loops. Retries and
skipped closed tickets do not count. Bug hunting still runs if requested;
`--once` (`/once`) retains its one-ticket-per-loop behavior, subject to the
shared cap. Dry-run continues to list all eligible tickets without running them.

### Ticket completion

Ralph rechecks issue state before claiming or launching a selected ticket because
GitHub's open-issue listing can briefly lag closure. Closed or completed tickets
are ignored for the remainder of that ticket loop, even if stale listings keep
returning them. Completion requires a closed issue and a clean tracked worktree;
it does not require a new commit when the work is already implemented. Recovery
prompts report the actual failed check (issue state, worktree, or query failure).

### Tests

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\windows_scripts_test.ps1
```

The tests use compiled local stubs for Git, GitHub CLI, and agents. They do not
contact GitHub, invoke real agents, or change your repository. The test harness
requires Windows PowerShell 5.1 to compile its temporary `.exe` fixtures.
