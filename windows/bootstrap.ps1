#Requires -Version 5.1
<#
.SYNOPSIS
    Installs and updates this Windows machine's software from packages.psd1.
.PARAMETER Groups
    Limit to named groups, e.g. -Groups shell,cli. Default is every group.
.PARAMETER SkipUpgrade
    Install what is missing, leave installed versions alone.
.PARAMETER SkipCleanup
    Skip the housekeeping phase and leave winget's download cache alone.
.PARAMETER Status
    Print what the last real run did and exit. Exits 1 if that run failed.
.PARAMETER History
    Print the last runs and what each one moved, then exit.
.PARAMETER HistoryLines
    How many runs -History prints. Default 10.
.PARAMETER Doctor
    Check what a shell with the profile loaded actually sees - tools on PATH,
    the prompt, config drift, the task - and exit. Changes nothing. Exits 1 if
    something is wrong.
.PARAMETER SkipShell
    Skip the shell phase: Nerd Font, modules, profile, Windows Terminal.
.PARAMETER SkipMpv
    Skip the mpv phase.
.PARAMETER SkipSchedule
    Skip the schedule phase and leave Task Scheduler alone.
.PARAMETER SkipVsCode
    Skip installing VS Code extensions from the manifest.
.PARAMETER SkipUpdateCheck
    Don't check the GitHub origin for a newer release tag.
.PARAMETER IncludeUnknown
    Pass --include-unknown to winget upgrade.
.PARAMETER Silent
    Pass --silent to winget, suppressing installer UI.
.PARAMETER ListGroups
    Print the groups and their package counts, then exit.
.PARAMETER ListPackages
    Print every package id in every group, then exit.
.PARAMETER ShowVersion
    Print the script version and exit.
.PARAMETER ManifestPath
    Read the manifest from this path instead of packages.psd1 beside the script.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string[]]$Groups,
    [switch]$SkipUpgrade,
    [switch]$SkipCleanup,
    [switch]$Status,
    [switch]$History,
    [int]$HistoryLines = 10,
    [switch]$Doctor,
    [switch]$SkipShell,
    [switch]$SkipMpv,
    [switch]$SkipSchedule,
    [switch]$SkipVsCode,
    [switch]$SkipUpdateCheck,
    [switch]$IncludeUnknown,
    [switch]$Silent,
    [switch]$ListGroups,
    [switch]$ListPackages,
    [switch]$ShowVersion,
    [string]$ManifestPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:BootstrapVersion = '1.42.1'

if ($ShowVersion) {
    Write-Output $script:BootstrapVersion
    return
}

$script:ToolRoot = $PSScriptRoot
if (-not $script:ToolRoot) { $script:ToolRoot = Split-Path -Parent $MyInvocation.MyCommand.Path }

$script:ProfileSource = Join-Path $script:ToolRoot 'profile.ps1'
$script:StarshipTomlSource = Join-Path (Split-Path $script:ToolRoot -Parent) 'starship.toml'
$script:AtuinSource = Join-Path (Split-Path $script:ToolRoot -Parent) 'atuin'
$script:BatSource = Join-Path (Split-Path $script:ToolRoot -Parent) 'bat'
$script:TealdeerSource = Join-Path (Split-Path $script:ToolRoot -Parent) 'tealdeer'
$script:CarapaceSource = Join-Path (Split-Path $script:ToolRoot -Parent) 'carapace'
$script:MergeScript = Join-Path $script:ToolRoot 'merge-terminal-settings.ps1'
$script:MpvSource = Join-Path $script:ToolRoot 'mpv'

$script:ScriptSelf = Join-Path $script:ToolRoot 'bootstrap.ps1'

$script:PwshForTask = @(
    (Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps\pwsh.exe')
    (Join-Path $env:ProgramFiles 'PowerShell\7\pwsh.exe')
    (Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe')
) | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $ManifestPath) { $ManifestPath = Join-Path $script:ToolRoot 'packages.psd1' }
# Output helpers

$script:Results = New-Object System.Collections.ArrayList

# Run state.
#
# An unattended run is a run nobody watches: the task starts at 04:20, tees
# into a log file and exits. Every real run leaves one key=value record behind
# - the same shape the Linux and macOS scripts write - and -Status reads it
# back. Interactive is decided by whether stdout is redirected, which is the
# same test the other two make with [ -t 1 ]: the scheduled task pipes through
# Tee-Object, so it always reads as unattended.
$script:RunStarted = Get-Date
$script:RunInteractive = -not [Console]::IsOutputRedirected
$script:RunRecording = $false
$script:RunLog = ''
$script:NotifyOnFailure = $true
$script:StatusExit = 0
$script:StateRoot = if ($env:LOCALAPPDATA) { $env:LOCALAPPDATA } else { [IO.Path]::GetTempPath() }
$script:StateFile = Join-Path $script:StateRoot 'windows-bootstrap\last-run'
$script:HistoryFile = Join-Path $script:StateRoot 'windows-bootstrap\history'
# What this run moved: "id old>new" for an upgrade, "+id version" for an
# install, from the winget export taken before the packages phase against one
# taken after it.
$script:RunChanged = ''
$script:PackagesBefore = $null

function Write-Phase {
    param([string]$Text)
    Write-Host ''
    Write-Host "== $Text " -ForegroundColor Cyan -NoNewline
    Write-Host ('=' * [Math]::Max(0, 60 - $Text.Length)) -ForegroundColor DarkCyan
}

function Add-Result {
    param(
        [string]$Group,
        [string]$Id,
        [ValidateSet('installed', 'upgraded', 'current', 'held', 'present',
                     'missing', 'failed', 'would-install', 'would-upgrade', 'skipped',
                     'ok', 'broken')]
        [string]$Action,
        [string]$Detail = ''
    )
    $colour = switch ($Action) {
        'installed'     { 'Green' }
        'upgraded'      { 'Green' }
        'would-install' { 'Yellow' }
        'would-upgrade' { 'Yellow' }
        'held'          { 'DarkYellow' }
        'missing'       { 'Yellow' }
        'failed'        { 'Red' }
        'ok'            { 'Green' }
        'broken'        { 'Red' }
        default        { 'DarkGray' }
    }
    Write-Host ('  {0,-14}' -f $Action) -ForegroundColor $colour -NoNewline
    Write-Host ('{0,-44}' -f $Id) -NoNewline
    Write-Host $Detail -ForegroundColor DarkGray
    [void]$script:Results.Add([pscustomobject]@{
            Group = $Group; Id = $Id; Action = $Action; Detail = $Detail
        })
}

# Run state
#
# Written from two places: the Summary, for a run that finishes, and the trap
# below, for one that throws on the way there - a run that dies in phase 1 is
# exactly the run worth knowing about, and recording only at the end would
# leave yesterday's success sitting there looking current. -WhatIf never
# records: a dry run is a question, and it should not overwrite the answer to
# the last real one.

# [Math]::Floor, not [int]: casting a double to [int] in PowerShell *rounds*
# (to even, at that), so [int](94 / 60) is 2 and a 94-second run reported
# itself as "2m 34s".
function Format-Duration {
    param([int]$Seconds)
    if ($Seconds -lt 60) { return "${Seconds}s" }
    if ($Seconds -lt 3600) {
        return '{0}m {1}s' -f [int][Math]::Floor($Seconds / 60), ($Seconds % 60)
    }
    if ($Seconds -lt 86400) {
        return '{0}h {1}m' -f [int][Math]::Floor($Seconds / 3600), [int][Math]::Floor(($Seconds % 3600) / 60)
    }
    return '{0}d {1}h' -f [int][Math]::Floor($Seconds / 86400), [int][Math]::Floor(($Seconds % 86400) / 3600)
}

# On PowerShell 7, Measure-Object emits nothing at all for empty input, so
# (... | Measure-Object -Sum).Sum is $null.Sum and strict mode throws.
function Format-Size {
    param([System.IO.FileInfo[]]$Files)
    $bytes = 0L
    foreach ($file in $Files) { $bytes += $file.Length }
    return '{0:N1} MB' -f ($bytes / 1MB)
}

function Write-RunRecord {
    param([int]$ExitCode, [string]$ErrorMessage = '')
    if (-not $script:RunRecording) { return }
    if ($WhatIfPreference) { return }

    $finished = Get-Date
    $counts = @($script:Results | Group-Object Action |
        ForEach-Object { '{0}={1}' -f $_.Name, $_.Count }) -join ' '
    # Comma-separated: an id can contain spaces ("log pruning").
    $failedIds = @($script:Results | Where-Object { $_.Action -eq 'failed' } |
        ForEach-Object { $_.Id }) -join ', '

    $message = $ErrorMessage -replace '[\r\n]+', ' ' -replace "'", ''
    if ($message.Length -gt 200) { $message = $message.Substring(0, 200) }

    $lines = @(
        "version=$script:BootstrapVersion"
        "started=$($script:RunStarted.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ'))"
        "finished_epoch=$([DateTimeOffset]::new($finished).ToUnixTimeSeconds())"
        "duration_seconds=$([int]($finished - $script:RunStarted).TotalSeconds)"
        "exit=$ExitCode"
        "interactive=$(if ($script:RunInteractive) { 'yes' } else { 'no' })"
        "failed='$($failedIds -replace "'", '')'"
        "counts='$counts'"
        "log=$script:RunLog"
        "error='$message'"
        "changed='$($script:RunChanged -replace "'", '')'"
    )

    try {
        $dir = Split-Path -Parent $script:StateFile
        if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        Set-Content -LiteralPath $script:StateFile -Value $lines -Encoding UTF8 -WhatIf:$false
    } catch {
        # A run that cannot write its own record is not a run that failed -
        # but -Verbose should say so rather than leaving you wondering why
        # -Status still shows yesterday.
        Write-Verbose ("could not write $script:StateFile - {0}" -f $_.Exception.Message)
    }

    Add-HistoryEntry -ExitCode $ExitCode -Finished $finished
}

# One line per run, oldest first, so a week of unattended runs reads at once.
# Bounded at 200 lines - eight months of nightly runs - because a file that
# grows forever is a file somebody eventually has to deal with.
function Add-HistoryEntry {
    param([int]$ExitCode, [datetime]$Finished)
    $tally = '{0}/{1}/{2}' -f `
        @($script:Results | Where-Object { $_.Action -eq 'installed' }).Count,
        @($script:Results | Where-Object { $_.Action -eq 'upgraded' }).Count,
        @($script:Results | Where-Object { $_.Action -eq 'failed' }).Count
    $changed = $script:RunChanged
    if ($changed.Length -gt 300) { $changed = $changed.Substring(0, 300) }
    $interactive = if ($script:RunInteractive) { 'yes' } else { 'no' }
    $line = ("{0}`t{1}`t{2}`t{3}`t{4}`t{5}" -f
        [DateTimeOffset]::new($Finished).ToUnixTimeSeconds(), $ExitCode,
        [int]($Finished - $script:RunStarted).TotalSeconds, $interactive, $tally, $changed)

    try {
        $dir = Split-Path -Parent $script:HistoryFile
        if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        $kept = @()
        if (Test-Path -LiteralPath $script:HistoryFile) {
            $kept = @(Get-Content -LiteralPath $script:HistoryFile -ErrorAction SilentlyContinue |
                Select-Object -Last 199)
        }
        Set-Content -LiteralPath $script:HistoryFile -Value ($kept + $line) -Encoding UTF8 -WhatIf:$false
    } catch {
        Write-Verbose ("could not write $script:HistoryFile - {0}" -f $_.Exception.Message)
    }
}

function Show-RunHistory {
    Write-Phase 'History'
    if (-not (Test-Path -LiteralPath $script:HistoryFile)) {
        Add-Result -Group 'history' -Id 'history' -Action 'missing' `
            -Detail "nothing recorded yet - $script:HistoryFile"
        Write-Host ''
        return
    }
    if ($HistoryLines -lt 1) { $HistoryLines = 10 }

    Write-Host ('  {0,-17} {1,-8} {2,-8} {3,-7} {4}' -f 'when', 'took', 'result', 'i/u/f', 'what moved') `
        -ForegroundColor DarkGray
    $rows = @(Get-Content -LiteralPath $script:HistoryFile | Select-Object -Last $HistoryLines)
    foreach ($row in $rows) {
        $cell = $row -split "`t"
        if ($cell.Count -lt 5) { continue }
        [int64]$epoch = 0
        [void][int64]::TryParse($cell[0], [ref]$epoch)
        $when = [DateTimeOffset]::FromUnixTimeSeconds($epoch).ToLocalTime().ToString('yyyy-MM-dd HH:mm')
        # An unattended run is the one worth spotting in a list of runs.
        if ($cell[3] -eq 'no') { $when += '*' }
        [int]$seconds = 0
        [void][int]::TryParse($cell[2], [ref]$seconds)
        $verdict = if ($cell[1] -eq '0') { 'ok' } else { "exit $($cell[1])" }
        $colour = if ($cell[1] -eq '0') { 'Green' } else { 'Red' }

        Write-Host ('  {0,-17} {1,-8} ' -f $when, (Format-Duration $seconds)) -NoNewline
        Write-Host ('{0,-8}' -f $verdict) -ForegroundColor $colour -NoNewline
        Write-Host (' {0,-7} ' -f $cell[4]) -NoNewline
        $moved = if ($cell.Count -gt 5) { $cell[5] } else { '' }
        Write-Host $moved -ForegroundColor DarkGray
    }
    Write-Host ('  {0} run(s), * = unattended' -f $rows.Count) -ForegroundColor DarkGray
    Write-Host ''
}

# What moved between two winget exports: the same question `brew list
# --versions` answers on macOS and dpkg-query on Linux.
function Get-PackageDelta {
    param([hashtable]$Before, [hashtable]$After)
    if (-not $Before -or -not $After) { return '' }
    $moved = @()
    foreach ($id in ($After.Keys | Sort-Object)) {
        if (-not $Before.ContainsKey($id)) {
            $moved += ('+{0} {1}' -f $id, $After[$id])
        } elseif ($Before[$id] -ne $After[$id]) {
            $moved += ('{0} {1}>{2}' -f $id, $Before[$id], $After[$id])
        }
    }
    if ($moved.Count -eq 0) { return '' }
    if ($moved.Count -gt 8) {
        return (($moved[0..7] -join ', ') + (', +{0} more' -f ($moved.Count - 8)))
    }
    return ($moved -join ', ')
}

# One notification for a run nobody was watching. There is no single channel
# that exists everywhere: the event log needs no module and works with nobody
# logged on, BurntToast is the nice one but only if it happens to be installed,
# and msg.exe is missing on Home editions. Each is tried, each is optional, and
# an interactive run is never notified - it printed the failures in red already.
function Send-FailureNotification {
    param([int]$ExitCode, [string]$Message = '')
    if ($ExitCode -eq 0) { return }
    if (-not $script:RunRecording) { return }
    if ($WhatIfPreference) { return }
    if ($script:RunInteractive) { return }
    if (-not $script:NotifyOnFailure) { return }

    $failedCount = @($script:Results | Where-Object { $_.Action -eq 'failed' }).Count
    $headline = if ($failedCount -gt 0) { "$failedCount step(s) failed" } else { "aborted, exit $ExitCode" }
    $body = if ($Message) { $Message } elseif ($script:RunLog) { $script:RunLog } else { 'bootstrap.ps1 -Status' }

    try {
        if (Get-Module -ListAvailable -Name BurntToast -ErrorAction SilentlyContinue) {
            Import-Module BurntToast -ErrorAction Stop
            New-BurntToastNotification -Text 'windows-bootstrap', $headline, $body | Out-Null
            return
        }
    } catch {
        Write-Verbose ('BurntToast did not work - {0}' -f $_.Exception.Message)
    }

    try {
        [System.Diagnostics.EventLog]::WriteEntry(
            'windows-bootstrap', "$headline`n$body",
            [System.Diagnostics.EventLogEntryType]::Error)
        return
    } catch {
        # PowerShell 7 does not always carry System.Diagnostics.EventLog, and
        # registering a new source needs an elevated run. Neither is fatal.
        Write-Verbose ('the event log did not work - {0}' -f $_.Exception.Message)
    }

    try {
        $msg = Get-Command msg.exe -ErrorAction SilentlyContinue
        if ($msg) { & $msg.Source '*' "windows-bootstrap: $headline - $body" 2>$null }
    } catch {
        # Home editions have no msg.exe. There is nothing left to try, and a
        # missing notification is not itself a failure.
        Write-Verbose ('msg.exe did not work - {0}' -f $_.Exception.Message)
    }
}

function Show-RunStatus {
    $script:StatusExit = 0
    Write-Phase 'Last run'
    if (-not (Test-Path -LiteralPath $script:StateFile)) {
        Add-Result -Group 'status' -Id 'last run' -Action 'missing' `
            -Detail "nothing recorded yet - $script:StateFile"
        Write-Host ''
        return
    }

    $record = @{}
    foreach ($entry in (Get-Content -LiteralPath $script:StateFile)) {
        $pair = $entry -split '=', 2
        if ($pair.Count -eq 2) { $record[$pair[0]] = $pair[1].Trim("'") }
    }
    $field = {
        param($name)
        if ($record.ContainsKey($name)) { $record[$name] } else { '' }
    }

    [int64]$finishedEpoch = 0
    [void][int64]::TryParse((& $field 'finished_epoch'), [ref]$finishedEpoch)
    $stamp = if ($finishedEpoch -gt 0) {
        [DateTimeOffset]::FromUnixTimeSeconds($finishedEpoch).ToLocalTime().ToString('yyyy-MM-dd HH:mm:ss')
    } else { 'unknown' }
    $ago = Format-Duration ([int]([DateTimeOffset]::UtcNow.ToUnixTimeSeconds() - $finishedEpoch))
    $duration = 0
    [void][int]::TryParse((& $field 'duration_seconds'), [ref]$duration)
    $trigger = if ((& $field 'interactive') -eq 'no') {
        'unattended - the scheduled task, or output redirected'
    } else { 'a terminal' }

    Write-Host ('  {0,-16}{1}  ' -f 'when', $stamp) -NoNewline
    Write-Host "($ago ago)" -ForegroundColor DarkGray
    Write-Host ('  {0,-16}{1}' -f 'trigger', $trigger)
    Write-Host ('  {0,-16}v{1}' -f 'version', (& $field 'version'))
    Write-Host ('  {0,-16}{1}' -f 'duration', (Format-Duration $duration))

    $exitCode = (& $field 'exit')
    if ($exitCode -eq '0') {
        Write-Host ('  {0,-16}' -f 'result') -NoNewline
        Write-Host 'clean - every step did what it said' -ForegroundColor Green
    } else {
        $script:StatusExit = 1
        Write-Host ('  {0,-16}' -f 'result') -NoNewline
        Write-Host "exit $exitCode" -ForegroundColor Red
        if (& $field 'failed') {
            Write-Host ('  {0,-16}' -f 'failed') -NoNewline
            Write-Host (& $field 'failed') -ForegroundColor Yellow
        }
        if (& $field 'error') {
            Write-Host ('  {0,-16}' -f 'aborted') -NoNewline
            Write-Host (& $field 'error') -ForegroundColor Yellow
        }
    }
    if (& $field 'counts') { Write-Host ('  {0,-16}{1}' -f 'counts', (& $field 'counts')) }
    if (& $field 'log') { Write-Host ('  {0,-16}{1}' -f 'log', (& $field 'log')) }
    Write-Host ('  {0,-16}' -f 'record') -NoNewline
    Write-Host $script:StateFile -ForegroundColor DarkGray
    Write-Host ''
}

# Doctor
#
# Every phase here asserts that a package is installed. This asserts that it is
# in *effect*, which is not the same thing and is where this changelog's bugs
# live: %USERPROFILE%\go\bin missing from PATH, the mise shims missing from
# PATH, JAVA_HOME unset, a profile that was deployed but never loaded. All of
# them were found by somebody noticing, months later.
#
# So the questions are asked of a shell with the profile loaded, in one probe:
# what each tool resolves to, whether anything shadows it, what the prompt
# function is, what is on PATH. PSReadLine is the exception - it only loads in
# an interactive console host, so a probe cannot see it and the check is that
# the module is there and the profile configures it.
#
# It reports and never fixes. The fix is bootstrap.ps1 itself.

$script:DoctorOk = 0
$script:DoctorBroken = 0
$script:DoctorProbe = @{}

function Add-DoctorOk {
    param([string]$Id, [string]$Detail)
    $script:DoctorOk++
    Add-Result -Group 'doctor' -Id $Id -Action 'ok' -Detail $Detail
}

function Add-DoctorBroken {
    param([string]$Id, [string]$Detail)
    $script:DoctorBroken++
    Add-Result -Group 'doctor' -Id $Id -Action 'broken' -Detail $Detail
}

function Add-DoctorNote {
    param([string]$Id, [string]$Detail)
    Add-Result -Group 'doctor' -Id $Id -Action 'present' -Detail $Detail
}

# package -> command, from the table CI enforces. Three rows need saying
# differently: zoxide's cell is the `z` function it defines rather than its
# binary, and 7-Zip and the two Linux-only entries put nothing on a Windows
# PATH at all.
function Get-DoctorCommands {
    $table = Join-Path (Split-Path $script:ToolRoot -Parent) 'tools\cli-parity.conf'
    $commands = @{}
    if (-not (Test-Path -LiteralPath $table)) { return $commands }
    foreach ($row in (Get-Content -LiteralPath $table)) {
        if ($row -match '^\s*#' -or -not $row.Trim()) { continue }
        $cell = $row -split '\|'
        if ($cell.Count -lt 6) { continue }
        $canonical = $cell[0].Trim()
        $winget = $cell[3].Trim()
        if (-not $winget -or $winget -eq '-') { continue }
        if ($canonical -eq '7zip') { continue }
        $command = if ($canonical -eq 'zoxide') { 'zoxide' } else { ($cell[5].Trim() -split '\s+')[0] }
        if ($command) { $commands[$command] = $winget }
    }
    return $commands
}

function Invoke-DoctorProbe {
    param([string[]]$Commands)
    $script:DoctorProbe = @{}
    if (-not $script:PwshForTask) { return $false }

    $list = ($Commands | ForEach-Object { "'$_'" }) -join ','
    $probe = @"
`$out = @()
foreach (`$c in @($list)) {
    `$found = @(Get-Command `$c -ErrorAction SilentlyContinue)
    `$first = if (`$found.Count) { `$found[0].Source } else { '' }
    `$out += "resolve:`$c=`$first"
    `$out += "count:`$c=`$(`$found.Count)"
}
`$out += "env:PATH=`$env:PATH"
`$out += "env:JAVA_HOME=`$env:JAVA_HOME"
`$prompt = Get-Command prompt -CommandType Function -ErrorAction SilentlyContinue
`$out += "fn:prompt=`$(if (`$prompt) { `$prompt.Definition -replace '\s+', ' ' } else { '' })"
`$out -join [Environment]::NewLine
"@

    try {
        # No -NoProfile on purpose: the profile is the thing under test.
        $raw = & $script:PwshForTask -NoLogo -NonInteractive -Command $probe 2>$null
    } catch {
        Write-Verbose ('the probe shell failed - {0}' -f $_.Exception.Message)
        return $false
    }
    foreach ($line in ($raw -split "`r?`n")) {
        $pair = $line -split '=', 2
        if ($pair.Count -eq 2) { $script:DoctorProbe[$pair[0]] = $pair[1] }
    }
    return ($script:DoctorProbe.Count -gt 0)
}

function Get-ProbeValue {
    param([string]$Key)
    if ($script:DoctorProbe.ContainsKey($Key)) { return $script:DoctorProbe[$Key] }
    return ''
}

function Test-DoctorTools {
    param([hashtable]$Commands)
    foreach ($command in ($Commands.Keys | Sort-Object)) {
        $path = Get-ProbeValue "resolve:$command"
        $count = Get-ProbeValue "count:$command"
        if (-not $path) {
            Add-DoctorBroken $command ('not on PATH - winget says it installs {0}' -f $Commands[$command])
        } elseif ($count -and [int]$count -gt 1) {
            # Two of the same command on PATH is how a stale copy wins for
            # months without anybody noticing.
            Add-DoctorNote $command ("$path - and $count copies on PATH")
        } else {
            Add-DoctorOk $command $path
        }
    }
}

function Test-DoctorShell {
    $prompt = Get-ProbeValue 'fn:prompt'
    if ($prompt -match 'starship') {
        Add-DoctorOk 'starship prompt' 'the prompt function comes from starship'
    } elseif ($prompt) {
        Add-DoctorBroken 'starship prompt' 'a prompt function is defined, but not by starship'
    } else {
        Add-DoctorBroken 'starship prompt' 'no prompt function - the profile did not load'
    }

    foreach ($target in @(
            (Join-Path $env:USERPROFILE 'Documents\WindowsPowerShell\Microsoft.PowerShell_profile.ps1'),
            (Join-Path $env:USERPROFILE 'Documents\PowerShell\Microsoft.PowerShell_profile.ps1'))) {
        $label = 'profile: ' + (Split-Path (Split-Path $target -Parent) -Leaf)
        if (-not (Test-Path -LiteralPath $target)) {
            Add-DoctorBroken $label "not deployed at $target"
        } elseif ((Get-Content -LiteralPath $target -Raw) -eq (Get-Content -LiteralPath $script:ProfileSource -Raw)) {
            Add-DoctorOk $label $target
        } else {
            Add-DoctorNote $label "$target differs from the repo - the next run would replace it"
        }
    }

    # PSReadLine only loads in an interactive console host, so a probe shell
    # cannot report on it; what can be checked is that it is installed and that
    # the profile configures it.
    if (Get-Module -ListAvailable -Name PSReadLine -ErrorAction SilentlyContinue) {
        Add-DoctorOk 'PSReadLine' 'installed'
    } else {
        Add-DoctorBroken 'PSReadLine' 'not installed - no history search, no predictions'
    }
    if ((Test-Path -LiteralPath $script:ProfileSource) -and
        (Select-String -LiteralPath $script:ProfileSource -Pattern 'Set-PSReadLineOption' -Quiet)) {
        Add-DoctorOk 'PSReadLine options' 'the profile sets them'
    } else {
        Add-DoctorBroken 'PSReadLine options' 'the profile does not configure PSReadLine'
    }
}

# mise keeps its data under %LOCALAPPDATA% on Windows, not ~/.local/share. An
# activated shell resolves a runtime to its installs\ directory, which
# `mise activate` puts ahead of the shims; anything else resolves through the
# shims. Either one is mise's.
function Test-DoctorRuntimes {
    $miseRoot = Join-Path $env:LOCALAPPDATA 'mise'
    $shims = Join-Path $miseRoot 'shims'
    foreach ($tool in @('node', 'go', 'java')) {
        $path = Get-ProbeValue "resolve:$tool"
        if (-not $path) {
            Add-DoctorBroken $tool 'not on PATH'
        } elseif ($path -like "$shims\*" -or $path -like "$miseRoot\installs\*") {
            Add-DoctorOk $tool $path
        } else {
            Add-DoctorNote $tool "$path - not managed by mise"
        }
    }

    $javaHome = Get-ProbeValue 'env:JAVA_HOME'
    if (-not $javaHome) {
        Add-DoctorBroken 'JAVA_HOME' 'unset - Gradle, Maven and the IDEs that read it will not find the JDK'
    } else {
        Add-DoctorOk 'JAVA_HOME' $javaHome
    }

    $path = Get-ProbeValue 'env:PATH'
    foreach ($dir in @($shims, (Join-Path $env:USERPROFILE 'go\bin'))) {
        if (($path -split ';') -contains $dir) {
            Add-DoctorOk "PATH $dir" 'present'
        } else {
            Add-DoctorBroken "PATH $dir" 'missing from a profile-loaded shell'
        }
    }
}

function Test-DoctorConfig {
    $pairs = @(
        @{ Label = 'starship.toml'; Source = $script:StarshipTomlSource
           Target = (Join-Path $env:USERPROFILE '.config\starship.toml') }
        @{ Label = 'atuin config'; Source = (Join-Path $script:AtuinSource 'config.toml')
           Target = (Join-Path $env:USERPROFILE '.config\atuin\config.toml') }
        @{ Label = 'tealdeer config'; Source = (Join-Path $script:TealdeerSource 'config.toml')
           Target = (Join-Path $env:APPDATA 'tealdeer\config\config.toml') }
    )
    foreach ($pair in $pairs) {
        if (-not (Test-Path -LiteralPath $pair.Target)) {
            Add-DoctorBroken $pair.Label ('not deployed at {0}' -f $pair.Target)
        } elseif (-not (Test-Path -LiteralPath $pair.Source)) {
            Add-DoctorNote $pair.Label ('deployed, but the repo copy is missing at {0}' -f $pair.Source)
        } elseif ((Get-FileHash -LiteralPath $pair.Source).Hash -eq (Get-FileHash -LiteralPath $pair.Target).Hash) {
            Add-DoctorOk $pair.Label $pair.Target
        } else {
            Add-DoctorNote $pair.Label ('{0} differs from the repo - the next run would replace it' -f $pair.Target)
        }
    }
}

function Test-DoctorSchedule {
    param($Schedule)
    if (-not $Schedule.Enabled) {
        Add-DoctorNote 'scheduled task' 'Enabled is false in the manifest'
        return
    }
    $task = Get-ScheduledTask -TaskName $Schedule.TaskName -ErrorAction SilentlyContinue
    if (-not $task) {
        Add-DoctorBroken 'scheduled task' ('{0} does not exist - the daily run has never been registered' -f $Schedule.TaskName)
    } elseif ($task.State -eq 'Disabled') {
        Add-DoctorBroken 'scheduled task' ('{0} exists but is disabled' -f $Schedule.TaskName)
    } else {
        Add-DoctorOk 'scheduled task' ('{0} is {1}' -f $Schedule.TaskName, $task.State)
    }
}

function Invoke-Doctor {
    param($Manifest)
    $commands = Get-DoctorCommands
    $probeList = @($commands.Keys) + @('starship', 'atuin', 'carapace', 'mise', 'uv',
        'git', 'gh', 'node', 'go', 'java', 'kubectl', 'code', 'winget')

    Write-Phase 'Doctor - what a shell with your profile sees'
    if (-not (Invoke-DoctorProbe -Commands $probeList)) {
        Add-Result -Group 'doctor' -Id 'probe shell' -Action 'failed' `
            -Detail 'could not start a shell to ask, or it answered nothing'
        return 1
    }
    Add-DoctorOk 'probe shell' ('{0} - asked once, with the profile loaded' -f $script:PwshForTask)

    Write-Phase 'Doctor - the cli group on PATH'
    Test-DoctorTools -Commands $commands

    Write-Phase 'Doctor - shell integration'
    Test-DoctorShell

    Write-Phase 'Doctor - runtimes and PATH'
    Test-DoctorRuntimes

    Write-Phase 'Doctor - deployed config'
    Test-DoctorConfig

    Write-Phase 'Doctor - the daily run'
    Test-DoctorSchedule -Schedule $Manifest.Schedule

    Write-Phase 'Doctor summary'
    Write-Host ('  {0,-16}' -f 'ok') -NoNewline
    Write-Host $script:DoctorOk -ForegroundColor Green
    if ($script:DoctorBroken -gt 0) {
        Write-Host ('  {0,-16}' -f 'broken') -NoNewline
        Write-Host $script:DoctorBroken -ForegroundColor Red
        Write-Host ''
        Write-Host '  Run .\bootstrap.ps1 to fix what it can.' -ForegroundColor DarkGray
        Write-Host ''
        return 1
    }
    Write-Host ''
    Write-Host '  Everything the manifest promises is in effect.' -ForegroundColor DarkGray
    Write-Host ''
    return 0
}

# Errors are terminating ($ErrorActionPreference = 'Stop'), so anything this
# script does not handle itself lands here. Record it, say so if nobody is
# watching, then `break` to let the error surface and stop the run as before.
trap {
    Write-RunRecord -ExitCode 1 -ErrorMessage $_.Exception.Message
    Send-FailureNotification -ExitCode 1 -Message $_.Exception.Message
    break
}

# Environment

function Get-GitHubLatestTag {
    param([string]$RepoSlug)
    try {
        return (Invoke-RestMethod -Uri "https://api.github.com/repos/$RepoSlug/releases/latest" -TimeoutSec 5 -ErrorAction Stop).tag_name
    } catch {
        return $null
    }
}

# Compares the checkout's own tag against its GitHub origin's latest release -
# not $script:BootstrapVersion, which is this script's own number and never
# lines up with the vYYYY.MM.DD bundle tag. Silent whenever it can't be sure:
# no git checkout (a release zip), no GitHub origin (a fork hosted elsewhere),
# no tags, or no network - this never blocks or fails the run over it.
function Test-BootstrapUpdate {
    if ($SkipUpdateCheck) { return }
    if (-not (Get-Command git -ErrorAction SilentlyContinue)) { return }

    git -C $script:ToolRoot rev-parse --is-inside-work-tree *> $null
    if ($LASTEXITCODE -ne 0) { return }

    $originUrl = (git -C $script:ToolRoot remote get-url origin 2>$null) -replace '\.git$', ''
    if (-not $originUrl -or $originUrl -notmatch 'github\.com[:/](?<slug>[^/]+/[^/]+)$') { return }
    $repoSlug = $Matches['slug']

    $localTag = git -C $script:ToolRoot describe --tags --abbrev=0 2>$null
    if (-not $localTag) { return }

    $remoteTag = Get-GitHubLatestTag -RepoSlug $repoSlug
    if (-not $remoteTag -or $remoteTag -eq $localTag) { return }

    Write-Host ('  update          {0} available (you have {1}) - https://github.com/{2}/releases/tag/{3}' `
            -f $remoteTag, $localTag, $repoSlug, $remoteTag) -ForegroundColor Yellow
}

function Test-Elevated {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    return (New-Object Security.Principal.WindowsPrincipal $id).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Update-SessionPath {
    $registry = @(
        [Environment]::GetEnvironmentVariable('Path', 'Machine')
        [Environment]::GetEnvironmentVariable('Path', 'User')
    ) | Where-Object { $_ }
    $fromRegistry = @(($registry -join ';') -split ';' | Where-Object { $_ })

    $extra = @($env:Path -split ';' | Where-Object { $_ -and $fromRegistry -notcontains $_ })
    $env:Path = (@($fromRegistry) + $extra | Select-Object -Unique) -join ';'
}

# winget

$script:WingetNoop = 'No applicable upgrade|No available upgrade|No newer package|No applicable update|already installed|No installed package found'

$script:WingetUnknownVersion = "version number cannot be determined|--include-unknown"

function Invoke-Winget {
    param([string[]]$WingetArgs)
    $output = & {
        $ErrorActionPreference = 'Continue'
        & winget @WingetArgs 2>&1
    } | Out-String
    return [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = $output.Trim() }
}

function Get-WingetCommonArgs {
    $a = @('-e', '--accept-source-agreements', '--accept-package-agreements', '--disable-interactivity')
    if ($Silent) { $a += '--silent' }
    return $a
}

function Get-LastLine {
    param([string]$Text)
    $lines = @($Text -split "`r?`n" | Where-Object { $_.Trim() })
    if ($lines.Count -eq 0) { return '' }
    return $lines[-1].Trim()
}

function Get-InstalledPackages {
    $file = Join-Path $env:TEMP ('winget-export-{0}.json' -f [guid]::NewGuid())
    try {
        $null = Invoke-Winget @('export', '-o', $file, '--include-versions',
            '--accept-source-agreements', '--disable-interactivity')
        if (-not (Test-Path $file)) { return $null }
        $json = Get-Content $file -Raw | ConvertFrom-Json
        if (-not $json.PSObject.Properties['Sources']) { return $null }
        $map = @{}
        foreach ($source in $json.Sources) {
            if (-not $source.PSObject.Properties['Packages']) { continue }
            foreach ($pkg in $source.Packages) {
                $version = ''
                if ($pkg.PSObject.Properties['Version']) { $version = $pkg.Version }
                $map[$pkg.PackageIdentifier] = $version
            }
        }
        return $map
    } catch {
        Write-Warning "winget export failed ($($_.Exception.Message)); falling back to per-package probes."
        return $null
    } finally {
        Remove-Item $file -ErrorAction SilentlyContinue -WhatIf:$false
    }
}

function Get-UpgradeListing {
    $a = @('upgrade', '--accept-source-agreements', '--disable-interactivity')
    if ($IncludeUnknown) { $a += '--include-unknown' }
    return (Invoke-Winget $a).Output
}

function Test-UpgradeListed {
    param([string]$Id, [string]$Listing)
    if ([string]::IsNullOrWhiteSpace($Listing)) { return $true }
    return $Listing -match ('(?<![\w.]){0}(?![\w.])' -f [regex]::Escape($Id))
}

function Get-AvailableVersion {
    param([string]$Id, [string]$Listing)
    if ([string]::IsNullOrWhiteSpace($Listing)) { return '' }
    $id = [regex]::Escape($Id)
    foreach ($pattern in @(
            "(?m)^.*?\s$id\s+(\S+)\s+(\S+)\s+\S+\s*$"   # ... Id Version Available Source
            "(?m)^.*?\s$id\s+(\S+)\s+(\S+)\s*$"         # ... Id Version Available
        )) {
        $m = [regex]::Match($Listing, $pattern)
        if ($m.Success) { return $m.Groups[2].Value }
    }
    return ''
}

function Format-VersionChange {
    param([string]$From, [string]$To)
    if ($From -and $To) { return "$From -> $To" }
    if ($From) { return $From }
    return $To
}

function Test-PackageInstalled {
    param([string]$Id, $InstalledMap)
    if ($null -ne $InstalledMap) { return $InstalledMap.ContainsKey($Id) }
    $probe = Invoke-Winget @('list', '--id', $Id, '-e', '--accept-source-agreements', '--disable-interactivity')
    return ($probe.ExitCode -eq 0 -and $probe.Output -notmatch 'No installed package found')
}

function Install-Package {
    param([string]$Group, [string]$Id)
    if (-not $PSCmdlet.ShouldProcess($Id, 'winget install')) {
        Add-Result -Group $Group -Id $Id -Action 'would-install'
        return
    }
    $r = Invoke-Winget (@('install', '--id', $Id) + (Get-WingetCommonArgs))
    if ($r.ExitCode -eq 0) {
        Add-Result -Group $Group -Id $Id -Action 'installed'
    } elseif ($r.Output -match $script:WingetNoop) {
        Add-Result -Group $Group -Id $Id -Action 'current'
    } else {
        Add-Result -Group $Group -Id $Id -Action 'failed' -Detail ('exit {0}: {1}' -f $r.ExitCode, (Get-LastLine $r.Output))
    }
}

function Update-Package {
    param([string]$Group, [string]$Id, [string]$Version, [string]$Available)
    $change = Format-VersionChange -From $Version -To $Available
    if (-not $PSCmdlet.ShouldProcess($Id, 'winget upgrade')) {
        Add-Result -Group $Group -Id $Id -Action 'would-upgrade' -Detail $change
        return
    }
    $a = @('upgrade', '--id', $Id) + (Get-WingetCommonArgs)
    if ($IncludeUnknown) { $a += '--include-unknown' }
    $r = Invoke-Winget $a
    if ($r.ExitCode -eq 0) {
        Add-Result -Group $Group -Id $Id -Action 'upgraded' -Detail $change
    } elseif ($r.Output -match $script:WingetNoop) {
        Add-Result -Group $Group -Id $Id -Action 'current' -Detail $Version
    } elseif ($r.Output -match $script:WingetUnknownVersion) {
        Add-Result -Group $Group -Id $Id -Action 'skipped' -Detail 'winget cannot read its version; it has its own updater'
    } else {
        Add-Result -Group $Group -Id $Id -Action 'failed' -Detail ('exit {0}: {1}' -f $r.ExitCode, (Get-LastLine $r.Output))
    }
}

# Managed files

function Deploy-ManagedFile {
    param(
        [string]$Source,
        [string]$Target,
        [string]$Label,
        [string]$Group,
        [string]$Marker = 'managed by windows/bootstrap.ps1'
    )
    $existing = if (Test-Path $Target) { Get-Content $Target -Raw } else { $null }
    if ($null -ne $existing -and $existing -eq (Get-Content $Source -Raw)) {
        Add-Result -Group $Group -Id $Label -Action 'current'
        return
    }
    if (-not $PSCmdlet.ShouldProcess($Target, 'deploy file')) {
        Add-Result -Group $Group -Id $Label -Action 'would-install'
        return
    }
    $detail = ''
    if ($null -ne $existing -and $existing -notmatch [regex]::Escape($Marker)) {
        Copy-Item $Target "$Target.bak" -Force
        $detail = 'unmanaged file backed up to .bak'
    }
    New-Item -ItemType Directory -Path (Split-Path $Target -Parent) -Force | Out-Null
    Copy-Item $Source $Target -Force
    Unblock-File $Target -ErrorAction SilentlyContinue
    Add-Result -Group $Group -Id $Label -Action 'installed' -Detail $detail
}

function Install-NerdFont {
    param(
        [string]$Name,   # e.g. 'Meslo' - the release asset name
        [string]$Repo,   # e.g. 'ryanoasis/nerd-fonts'
        [string]$Match   # face-table match, e.g. 'MesloLGMNerdFont'
    )
    $fontDir = Join-Path $env:LOCALAPPDATA 'Microsoft\Windows\Fonts'
    $already = (Test-Path $fontDir) -and
        @(Get-ChildItem $fontDir -Filter "$Match*" -ErrorAction SilentlyContinue).Count -gt 0
    $label = 'font: {0}' -f $Name
    if ($already) {
        Add-Result -Group 'shell' -Id $label -Action 'current'
        return
    }
    if (-not $PSCmdlet.ShouldProcess($Name, 'install Nerd Font')) {
        Add-Result -Group 'shell' -Id $label -Action 'would-install'
        return
    }

    $tmp = Join-Path $env:TEMP ('nerdfont-{0}-{1}' -f $Name, [guid]::NewGuid())
    New-Item -ItemType Directory -Path $tmp -Force | Out-Null
    try {
        $archive = Join-Path $tmp "$Name.zip"
        Invoke-WebRequest -Uri "https://github.com/$Repo/releases/latest/download/$Name.zip" `
            -OutFile $archive -UseBasicParsing
        Expand-Archive -Path $archive -DestinationPath $tmp -Force

        $fonts = @(Get-ChildItem $tmp -Filter "$Match*.ttf" -Recurse)
        if ($fonts.Count -eq 0) {
            Add-Result -Group 'shell' -Id $label -Action 'failed' -Detail 'archive carried no matching .ttf files'
            return
        }

        New-Item -ItemType Directory -Path $fontDir -Force | Out-Null
        Add-Type -AssemblyName System.Drawing
        $regPath = 'HKCU:\Software\Microsoft\Windows NT\CurrentVersion\Fonts'
        foreach ($font in $fonts) {
            $destPath = Join-Path $fontDir $font.Name
            Copy-Item $font.FullName -Destination $destPath -Force

            $pfc = New-Object System.Drawing.Text.PrivateFontCollection
            $pfc.AddFontFile($destPath)
            $familyName = $pfc.Families[0].Name
            $pfc.Dispose()

            New-ItemProperty -Path $regPath -Name "$familyName (TrueType)" `
                -Value $font.Name -PropertyType String -Force | Out-Null
        }

        if (-not ('Win32.FontBroadcast' -as [type])) {
            Add-Type -Namespace Win32 -Name FontBroadcast -MemberDefinition '
                [DllImport("user32.dll", SetLastError = true, CharSet = CharSet.Auto)]
                public static extern IntPtr SendMessageTimeout(IntPtr hWnd, uint Msg, UIntPtr wParam, IntPtr lParam, uint fuFlags, uint uTimeout, out UIntPtr lpdwResult);
            '
        }
        $broadcastResult = [UIntPtr]::Zero
        [void][Win32.FontBroadcast]::SendMessageTimeout([IntPtr]0xffff, 0x001D, [UIntPtr]::Zero, [IntPtr]::Zero, 2, 1000, [ref]$broadcastResult)

        Add-Result -Group 'shell' -Id $label -Action 'installed' -Detail ('{0} face(s) -> {1}' -f $fonts.Count, $fontDir)
    } finally {
        Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Get-CliToolsIndex {
    param([string]$ParityPath)
    $index = @{}
    if (-not (Test-Path $ParityPath)) { return $index }
    foreach ($line in Get-Content $ParityPath) {
        if ($line -notmatch '\|') { continue }
        $fields = $line -split '\|'
        if ($fields.Count -lt 7) { continue }
        $canonical = $fields[0].Trim()
        if (-not $canonical -or $canonical.StartsWith('#')) { continue }
        $win = $fields[3].Trim()
        if (-not $win -or $win -eq '-') { continue }
        $index[$win] = [pscustomobject]@{
            Cmd  = $fields[5].Trim()
            Desc = $fields[6].Trim()
        }
    }
    return $index
}

function Deploy-ToolsList {
    param([string]$Target)
    $cliIndex = Get-CliToolsIndex -ParityPath (Join-Path (Split-Path $script:ToolRoot -Parent) 'tools\cli-parity.conf')
    $cliGroup = $manifest.Groups | Where-Object { $_.Name -eq 'cli' } | Select-Object -First 1
    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add('# managed by windows/bootstrap.ps1 - regenerated every run, edits here do not stick')
    # One row per package, then one loop that colours the columns: the package
    # id dimmed, the command to type in green (Catppuccin's, via the terminal
    # scheme), the description in the normal foreground.
    $quote = { param($s) "'" + ([string]$s).Replace("'", "''") + "'" }
    $lines.Add('function tools {')
    $lines.Add('    $rows = @(')
    if ($cliGroup) {
        foreach ($p in $cliGroup.Packages) {
            $cmd = ''; $desc = ''
            if ($cliIndex.ContainsKey($p)) {
                $cmd = $cliIndex[$p].Cmd
                $desc = $cliIndex[$p].Desc
            }
            $cells = @((& $quote $p), (& $quote $cmd), (& $quote $desc))
            $lines.Add('        ,@({0}, {1}, {2})' -f $cells)
        }
    }
    $lines.Add('    )')
    $lines.Add('    Write-Host ""')
    $lines.Add('    foreach ($r in $rows) {')
    $lines.Add('        Write-Host (''  {0,-26} '' -f $r[0]) -NoNewline -ForegroundColor DarkGray')
    $lines.Add('        Write-Host (''{0,-42} '' -f $r[1]) -NoNewline -ForegroundColor Green')
    $lines.Add('        Write-Host $r[2]')
    $lines.Add('    }')
    $lines.Add('    Write-Host ""')
    $lines.Add('}')
    $content = ($lines -join "`r`n") + "`r`n"

    $label = 'tools list: ' + (Split-Path (Split-Path $Target -Parent) -Leaf)
    $existing = if (Test-Path $Target) { Get-Content $Target -Raw } else { $null }
    if ($existing -eq $content) {
        Add-Result -Group 'shell' -Id $label -Action 'current'
        return
    }
    if (-not $PSCmdlet.ShouldProcess($Target, 'write tools list')) {
        Add-Result -Group 'shell' -Id $label -Action 'would-install'
        return
    }
    New-Item -ItemType Directory -Path (Split-Path $Target -Parent) -Force | Out-Null
    Set-Content -Path $Target -Value $content -NoNewline
    Add-Result -Group 'shell' -Id $label -Action 'installed'
}

# mpv add-ons

function Get-RegValue {
    param($Props, [string]$Name)
    if ($null -eq $Props) { return $null }
    $prop = $Props.PSObject.Properties[$Name]
    if ($null -eq $prop) { return $null }
    return $prop.Value
}

function Add-UserPathEntry {
    param([string]$Directory, [string]$Group, [string]$Label)

    $key = 'HKCU:\Environment'
    $raw = ''
    $kind = [Microsoft.Win32.RegistryValueKind]::ExpandString
    try {
        $item = Get-Item -Path $key -ErrorAction Stop
        if ($item.GetValueNames() -contains 'Path') {
            $raw = [string]$item.GetValue('Path', '', 'DoNotExpandEnvironmentNames')
            $kind = $item.GetValueKind('Path')
        }
    } catch {
        Add-Result -Group $Group -Id $Label -Action 'failed' -Detail $_.Exception.Message
        return
    }

    $entries = @($raw -split ';' | Where-Object { $_ })
    $wanted = $Directory.TrimEnd('\')
    if (@($entries | Where-Object { $_.TrimEnd('\') -eq $wanted }).Count -gt 0) {
        Add-Result -Group $Group -Id $Label -Action 'current' -Detail $Directory
        return
    }
    if (-not $PSCmdlet.ShouldProcess($Directory, 'add to user PATH')) {
        Add-Result -Group $Group -Id $Label -Action 'would-install' -Detail $Directory
        return
    }
    try {
        Set-ItemProperty -Path $key -Name 'Path' -Value (($entries + $Directory) -join ';') -Type $kind
        $env:Path = $env:Path.TrimEnd(';') + ';' + $Directory
        try {
            if (-not ('NativeMethods.WinApi' -as [type])) {
                Add-Type -Namespace 'NativeMethods' -Name 'WinApi' -MemberDefinition @'
[DllImport("user32.dll", SetLastError = true, CharSet = CharSet.Auto)]
public static extern IntPtr SendMessageTimeout(IntPtr hWnd, uint Msg, UIntPtr wParam,
    string lParam, uint fuFlags, uint uTimeout, out UIntPtr lpdwResult);
'@
            }
            $result = [UIntPtr]::Zero
            [void][NativeMethods.WinApi]::SendMessageTimeout(
                [IntPtr]0xffff, 0x1A, [UIntPtr]::Zero, 'Environment', 0x2, 3000, [ref]$result)
        } catch {
            Write-Verbose "PATH broadcast failed: $($_.Exception.Message)"
        }
        Add-Result -Group $Group -Id $Label -Action 'installed' -Detail $Directory
    } catch {
        Add-Result -Group $Group -Id $Label -Action 'failed' -Detail $_.Exception.Message
    }
}

function Resolve-MpvExe {
    $cmd = Get-Command mpv -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }

    $hives = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall'
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall'
        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall'
    )
    foreach ($hive in $hives) {
        foreach ($key in (Get-ChildItem $hive -ErrorAction SilentlyContinue)) {
            $props = Get-ItemProperty $key.PSPath -ErrorAction SilentlyContinue
            $name = Get-RegValue -Props $props -Name 'DisplayName'
            if ($name -notmatch 'mpv') { continue }
            $location = Get-RegValue -Props $props -Name 'InstallLocation'
            if (-not $location) { continue }
            $exe = Join-Path $location 'mpv.exe'
            if (Test-Path $exe) { return $exe }
        }
    }

    foreach ($dir in @('MPV Player', 'mpv')) {
        $exe = Join-Path $env:ProgramFiles (Join-Path $dir 'mpv.exe')
        if (Test-Path $exe) { return $exe }
    }
    return $null
}

function Format-AddonVersion {
    param([string]$Version)
    if ($Version -match '^[0-9a-f]{40}$') { return $Version.Substring(0, 7) }
    return $Version
}

function Resolve-MpvAddonVersion {
    param($Addon)
    $headers = @{ 'User-Agent' = 'windows-bootstrap' }
    try {
        if ($Addon.Source -eq 'release') {
            $uri = 'https://api.github.com/repos/{0}/releases/latest' -f $Addon.Repo
            $r = Invoke-RestMethod -Uri $uri -Headers $headers -UseBasicParsing
            if ($r.PSObject.Properties['tag_name']) { return [string]$r.tag_name }
            return $null
        }
        $uri = 'https://api.github.com/repos/{0}/commits?per_page=1' -f $Addon.Repo
        if ($Addon.Contains('Path')) { $uri += '&path={0}' -f [uri]::EscapeDataString($Addon.Path) }
        $response = Invoke-RestMethod -Uri $uri -Headers $headers -UseBasicParsing
        $commits = @($response)
        if ($commits.Count -gt 0 -and $commits[0].PSObject.Properties['sha']) {
            return [string]$commits[0].sha
        }
        return $null
    } catch {
        Write-Verbose "Could not resolve $($Addon.Name): $($_.Exception.Message)"
        return $null
    }
}

function Install-MpvAddon {
    param($Addon, [string]$MpvDir)

    $stamp = Join-Path $MpvDir ('.{0}-version' -f $Addon.Name)
    $have = ''
    if (Test-Path $stamp) { $have = (Get-Content $stamp -Raw).Trim() }

    if ($have -and $SkipUpgrade) {
        Add-Result -Group 'mpv' -Id $Addon.Name -Action 'skipped' -Detail (Format-AddonVersion $have)
        return
    }

    $want = Resolve-MpvAddonVersion -Addon $Addon
    if (-not $want) {
        if ($have) {
            Add-Result -Group 'mpv' -Id $Addon.Name -Action 'current' `
                -Detail ('{0} (could not reach GitHub to check for newer)' -f (Format-AddonVersion $have))
        } else {
            Add-Result -Group 'mpv' -Id $Addon.Name -Action 'failed' `
                -Detail 'could not resolve a version from GitHub'
        }
        return
    }

    if ($have -eq $want) {
        Add-Result -Group 'mpv' -Id $Addon.Name -Action 'current' -Detail (Format-AddonVersion $want)
        return
    }

    $change = Format-VersionChange -From (Format-AddonVersion $have) -To (Format-AddonVersion $want)
    if (-not $PSCmdlet.ShouldProcess("$($Addon.Name) $want", 'download and install')) {
        $action = if ($have) { 'would-upgrade' } else { 'would-install' }
        Add-Result -Group 'mpv' -Id $Addon.Name -Action $action -Detail $change
        return
    }

    try {
        $url = $Addon.Url -f $want
        if ($Addon.Kind -eq 'zip') {
            $zip = Join-Path $env:TEMP ('{0}-{1}.zip' -f $Addon.Name, [guid]::NewGuid())
            try {
                Invoke-WebRequest -Uri $url -OutFile $zip -UseBasicParsing
                Expand-Archive -Path $zip -DestinationPath $MpvDir -Force
            } finally {
                Remove-Item $zip -ErrorAction SilentlyContinue -WhatIf:$false
            }
        } else {
            $dir = Join-Path $MpvDir 'scripts'
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
            Invoke-WebRequest -Uri $url -OutFile (Join-Path $dir $Addon.File) -UseBasicParsing
        }
        New-Item -ItemType Directory -Path (Split-Path $stamp -Parent) -Force | Out-Null
        Set-Content -Path $stamp -Value $want -NoNewline
        $action = if ($have) { 'upgraded' } else { 'installed' }
        Add-Result -Group 'mpv' -Id $Addon.Name -Action $action -Detail $change
    } catch {
        Add-Result -Group 'mpv' -Id $Addon.Name -Action 'failed' -Detail $_.Exception.Message
    }
}

if ($Status) { Show-RunStatus; exit $script:StatusExit }
if ($History) { Show-RunHistory; exit 0 }

# Manifest

if (-not (Test-Path $ManifestPath)) { throw "Manifest not found: $ManifestPath" }
$manifest = Import-PowerShellDataFile -Path $ManifestPath

$required = @('Groups', 'Pins', 'Managed', 'Shell', 'Mpv', 'Schedule', 'Housekeeping', 'Git',
    'VsCodeExtensions')
$missing = @($required | Where-Object { -not $manifest.Contains($_) })
if ($missing.Count -gt 0) {
    throw ("Manifest is missing required section(s): {0}. Found: {1}. See {2}." -f
        ($missing -join ', '), (@($manifest.Keys) -join ', '), $ManifestPath)
}

# The run record can now say where an unattended run's output went - the task
# tees into one file per day under the schedule's log directory - and whether a
# failure is allowed to interrupt anybody.
if ($manifest.Schedule.Contains('NotifyOnFailure')) {
    $script:NotifyOnFailure = [bool]$manifest.Schedule.NotifyOnFailure
}
if (-not $script:RunInteractive -and $manifest.Schedule.Contains('LogDir')) {
    $script:RunLog = Join-Path (Join-Path $env:LOCALAPPDATA $manifest.Schedule.LogDir) `
        ('bootstrap-{0:yyyy-MM-dd}.log' -f (Get-Date))
}

if ($ListGroups) {
    Write-Host ''
    foreach ($g in $manifest.Groups) {
        Write-Host ('  {0,-10}' -f $g.Name) -ForegroundColor Cyan -NoNewline
        Write-Host ('{0,-3} packages   ' -f $g.Packages.Count) -NoNewline
        Write-Host $g.Description -ForegroundColor DarkGray
    }
    Write-Host ''
    return
}

if ($ListPackages) {
    Write-Host ''
    foreach ($g in $manifest.Groups) {
        Write-Host ('  {0}' -f $g.Name) -ForegroundColor Cyan
        foreach ($p in $g.Packages) {
            Write-Host ('    {0}' -f $p) -ForegroundColor DarkGray
        }
        if ($g.Contains('UvTools')) {
            foreach ($t in $g.UvTools) {
                Write-Host ('    {0}  (uv tool)' -f $t.Split('|')[0]) -ForegroundColor DarkGray
            }
        }
    }
    Write-Host ''
    return
}

$selected = $manifest.Groups
if ($Groups) {
    $known = @($manifest.Groups | ForEach-Object { $_.Name })
    $unknown = @($Groups | Where-Object { $known -notcontains $_ })
    if ($unknown.Count -gt 0) { throw "Unknown group(s): $($unknown -join ', '). Try -ListGroups." }
    $selected = @($manifest.Groups | Where-Object { $Groups -contains $_.Name })
}

# Preflight

Write-Phase 'Preflight'

if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
    throw @'
winget not found. It ships with App Installer, which is missing or too old.
Install "App Installer" from the Microsoft Store, then re-run this script.
Everything here is built on winget, so there is no fallback path.
'@
}

$elevated = Test-Elevated
$mode = if ($WhatIfPreference) { 'WhatIf - nothing will change' }
elseif ($SkipUpgrade) { 'install only' }
else { 'install + upgrade' }

Write-Host ('  bootstrap       v{0}' -f $script:BootstrapVersion) -ForegroundColor DarkGray
Write-Host ('  winget          {0}' -f (& winget --version)) -ForegroundColor DarkGray
Write-Host ('  PowerShell      {0}' -f $PSVersionTable.PSVersion) -ForegroundColor DarkGray
Write-Host ('  elevated        {0}' -f $elevated) -ForegroundColor DarkGray
Write-Host ('  mode            {0}' -f $mode) -ForegroundColor DarkGray
Test-BootstrapUpdate

if (-not $elevated) {
    Write-Warning @'
Not running elevated. Machine-scope packages (Steam, Chrome, 7-Zip and
others) will raise a UAC prompt each, and any you dismiss are reported as
failures. For an unattended run, start an admin PowerShell first.
'@
}

$blocked = @(
    Get-ChildItem $script:ToolRoot -File | Where-Object {
        Get-Content $_.FullName -Stream Zone.Identifier -ErrorAction SilentlyContinue
    }
)
if ($blocked.Count -gt 0) {
    Write-Host ('  unblocking      {0} file(s) marked as downloaded' -f $blocked.Count) -ForegroundColor DarkGray
    $blocked | Unblock-File
}

Write-Host '  reading installed packages...' -ForegroundColor DarkGray
$installed = Get-InstalledPackages
# The same listing serves as the "before" half of what moved.
$script:PackagesBefore = $installed
if ($null -ne $installed) {
    Write-Host ('  installed       {0} winget-managed packages' -f $installed.Count) -ForegroundColor DarkGray
}

Write-Host '  reading available upgrades...' -ForegroundColor DarkGray
$upgradeListing = Get-UpgradeListing

# The doctor asks the machine questions and changes nothing, so it runs here -
# after the manifest is read, before anything that touches winget.
if ($Doctor) { exit (Invoke-Doctor -Manifest $manifest) }

# Past this line the run counts: the Summary and the trap above both record
# what happened, whether it gets to the end or throws on the way there.

$script:RunRecording = $true

# Phase 1 - packages

foreach ($group in $selected) {
    Write-Phase ('{0} - {1}' -f $group.Name, $group.Description)

    foreach ($id in $group.Packages) {
        $version = ''
        if ($null -ne $installed -and $installed.ContainsKey($id)) { $version = $installed[$id] }

        $available = Get-AvailableVersion -Id $id -Listing $upgradeListing

        if ($manifest.Pins.ContainsKey($id)) {
            $seen = if ($version) { $version } else { 'not winget-managed' }
            if ($available) { $seen = '{0}, {1} available' -f $seen, $available }
            Add-Result -Group $group.Name -Id $id -Action 'held' -Detail ('{0} - {1}' -f $seen, $manifest.Pins[$id])
            continue
        }

        if (-not (Test-PackageInstalled -Id $id -InstalledMap $installed)) {
            Install-Package -Group $group.Name -Id $id
            continue
        }
        if ($SkipUpgrade) {
            Add-Result -Group $group.Name -Id $id -Action 'skipped' -Detail $version
            continue
        }
        if ($WhatIfPreference -and -not (Test-UpgradeListed -Id $id -Listing $upgradeListing)) {
            Add-Result -Group $group.Name -Id $id -Action 'current' -Detail $version
            continue
        }
        Update-Package -Group $group.Name -Id $id -Version $version -Available $available
    }
}

Update-SessionPath

# Python tools - uv tool, per group
#
# The same shape as GROUP_infra_UV in linux/packages.conf: one environment per
# tool, its commands linked onto PATH by uv. These have no usable winget
# package, so uv is how Windows gets them at all; uv itself is astral-sh.uv in
# the dev group, just installed by the loop above.

function Get-UvToolVersion {
    param([string]$Name, [string[]]$Listing)
    foreach ($line in $Listing) {
        # `uv tool list` prints "name vX.Y.Z" per tool and "- command" beneath it
        if ($line -match '^(\S+)\s+v(\S+)' -and $Matches[1] -eq $Name) { return $Matches[2] }
    }
    return ''
}

$uvEntries = @()
foreach ($group in $selected) {
    if ($group.Contains('UvTools')) { $uvEntries += @($group.UvTools) }
}

if ($uvEntries.Count -gt 0) {
    Write-Phase 'Python tools - uv tool, one environment each'
    if (-not (Get-Command uv -ErrorAction SilentlyContinue)) {
        Add-Result -Group 'uv' -Id 'uv tools' -Action 'missing' `
            -Detail 'uv is not on PATH - astral-sh.uv installs it in the dev group'
    } else {
        $uvListing = @(& uv tool list 2>$null)
        foreach ($entry in $uvEntries) {
            $tool = $entry.Split('|')[0]
            $extra = @()
            if ($entry.Contains('|')) {
                $extra = @($entry.Split('|', 2)[1].Split(' ') | Where-Object { $_ })
            }
            $have = Get-UvToolVersion -Name $tool -Listing $uvListing

            if ($have -and $SkipUpgrade) {
                Add-Result -Group 'uv' -Id $tool -Action 'skipped' -Detail $have
            } elseif (-not $have) {
                if (-not $PSCmdlet.ShouldProcess($tool, 'uv tool install')) {
                    Add-Result -Group 'uv' -Id $tool -Action 'would-install' `
                        -Detail ('uv tool install {0}' -f ((@($tool) + $extra) -join ' '))
                    continue
                }
                & uv tool install --quiet $tool @extra *> $null
                if ($LASTEXITCODE -eq 0) {
                    $now = Get-UvToolVersion -Name $tool -Listing @(& uv tool list 2>$null)
                    Add-Result -Group 'uv' -Id $tool -Action 'installed' -Detail $now
                } else {
                    Add-Result -Group 'uv' -Id $tool -Action 'failed' -Detail ('uv tool install {0} failed' -f $tool)
                }
            } elseif (-not $PSCmdlet.ShouldProcess($tool, 'uv tool upgrade')) {
                Add-Result -Group 'uv' -Id $tool -Action 'present' -Detail ('{0} - would run uv tool upgrade' -f $have)
            } else {
                & uv tool upgrade --quiet $tool *> $null
                if ($LASTEXITCODE -ne 0) {
                    Add-Result -Group 'uv' -Id $tool -Action 'failed' -Detail ('uv tool upgrade {0} failed' -f $tool)
                    continue
                }
                $now = Get-UvToolVersion -Name $tool -Listing @(& uv tool list 2>$null)
                if ($now -eq $have) {
                    Add-Result -Group 'uv' -Id $tool -Action 'current' -Detail $have
                } else {
                    Add-Result -Group 'uv' -Id $tool -Action 'upgraded' -Detail ('{0} -> {1}' -f $have, $now)
                }
            }
        }
    }
}

# mise global runtimes - node, go and java from mise/tools.conf at the repo
# root, the one list all three platforms share.
#
# Windows needs more than the shell activation in profile.ps1: Rider, Android
# Studio, Unity and MSBuild start outside PowerShell and would never see a
# mise runtime. The shims directory goes on the *user* PATH so every process
# resolves go/node/java, and JAVA_HOME is written from `mise where`, which the
# JVM build tools read instead of PATH. Both are refreshed on each run, so a
# version bump does not leave a stale path behind.
$miseToolsFile = Join-Path (Split-Path $script:ToolRoot -Parent) 'mise\tools.conf'
Write-Phase 'mise - global runtimes'
if (-not (Get-Command mise -ErrorAction SilentlyContinue)) {
    Add-Result -Group 'mise' -Id 'mise runtimes' -Action 'missing' `
        -Detail 'mise is not on PATH - jdx.mise installs it in the dev group'
} elseif (-not (Test-Path $miseToolsFile)) {
    Add-Result -Group 'mise' -Id 'mise runtimes' -Action 'failed' `
        -Detail ('not found at {0}' -f $miseToolsFile)
} else {
    $miseHave = @(& mise ls -g 2>$null | ForEach-Object { ($_ -split '\s+')[0] })
    $entries = @(Get-Content $miseToolsFile |
        ForEach-Object { ($_ -split '#')[0].Trim() } |
        Where-Object { $_ })

    foreach ($entry in $entries) {
        $tool = $entry.Split('@')[0]
        if ($miseHave -contains $tool) {
            Add-Result -Group 'mise' -Id $entry -Action 'current' -Detail (& mise current $tool 2>$null)
        } elseif (-not $PSCmdlet.ShouldProcess($entry, 'mise use -g')) {
            Add-Result -Group 'mise' -Id $entry -Action 'would-install' -Detail ('mise use -g {0}' -f $entry)
        } else {
            & mise use -g $entry *> $null
            if ($LASTEXITCODE -eq 0) {
                Add-Result -Group 'mise' -Id $entry -Action 'installed' -Detail (& mise current $tool 2>$null)
            } else {
                Add-Result -Group 'mise' -Id $entry -Action 'failed' -Detail ('run by hand: mise use -g {0}' -f $entry)
            }
        }
    }

    # Shims on the user PATH, for everything that does not run through the
    # PowerShell profile.
    $shims = Join-Path $env:LOCALAPPDATA 'mise\shims'
    $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
    if (($userPath -split ';') -contains $shims) {
        Add-Result -Group 'mise' -Id 'shims on PATH' -Action 'current' -Detail $shims
    } elseif (-not $PSCmdlet.ShouldProcess($shims, 'add to user PATH')) {
        Add-Result -Group 'mise' -Id 'shims on PATH' -Action 'would-install' -Detail $shims
    } else {
        [Environment]::SetEnvironmentVariable('Path', ($shims + ';' + $userPath), 'User')
        $env:Path = $shims + ';' + $env:Path
        Add-Result -Group 'mise' -Id 'shims on PATH' -Action 'installed' -Detail $shims
    }

    # GOPATH/bin, where `go install` and the VS Code Go extension put gopls,
    # dlv and staticcheck. Same reasoning as the shims: VS Code and the IDEs
    # read the user PATH, not the PowerShell profile.
    $goBin = Join-Path $env:USERPROFILE 'go\bin'
    $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
    if (($userPath -split ';') -contains $goBin) {
        Add-Result -Group 'mise' -Id 'GOPATH/bin on PATH' -Action 'current' -Detail $goBin
    } elseif (-not $PSCmdlet.ShouldProcess($goBin, 'add to user PATH')) {
        Add-Result -Group 'mise' -Id 'GOPATH/bin on PATH' -Action 'would-install' -Detail $goBin
    } else {
        [Environment]::SetEnvironmentVariable('Path', ($userPath + ';' + $goBin), 'User')
        $env:Path = $env:Path + ';' + $goBin
        Add-Result -Group 'mise' -Id 'GOPATH/bin on PATH' -Action 'installed' -Detail $goBin
    }

    # JAVA_HOME, for Gradle, Maven and the IDEs that read it rather than PATH.
    $javaEntry = $entries | Where-Object { $_ -like 'java@*' } | Select-Object -First 1
    if ($javaEntry) {
        $javaHome = (& mise where $javaEntry 2>$null)
        if (-not $javaHome) {
            Add-Result -Group 'mise' -Id 'JAVA_HOME' -Action 'missing' -Detail ('mise where {0} returned nothing' -f $javaEntry)
        } elseif ([Environment]::GetEnvironmentVariable('JAVA_HOME', 'User') -eq $javaHome) {
            Add-Result -Group 'mise' -Id 'JAVA_HOME' -Action 'current' -Detail $javaHome
        } elseif (-not $PSCmdlet.ShouldProcess('JAVA_HOME', 'set for the user')) {
            Add-Result -Group 'mise' -Id 'JAVA_HOME' -Action 'would-install' -Detail $javaHome
        } else {
            [Environment]::SetEnvironmentVariable('JAVA_HOME', $javaHome, 'User')
            $env:JAVA_HOME = $javaHome
            Add-Result -Group 'mise' -Id 'JAVA_HOME' -Action 'installed' -Detail $javaHome
        }
    }
}

# What moved. A second winget export, compared with the one phase 1 started
# from: the versions that actually changed, rather than the ones that scrolled
# past. Skipped under -WhatIf, where by definition nothing moved.
if (-not $WhatIfPreference -and $script:PackagesBefore) {
    $script:RunChanged = Get-PackageDelta -Before $script:PackagesBefore -After (Get-InstalledPackages)
    if ($script:RunChanged) {
        Add-Result -Group 'packages' -Id 'versions moved' -Action 'present' -Detail $script:RunChanged
    }
}

# Phase 2 - housekeeping
#
# winget upgrades in place, so unlike Homebrew there is no superseded version
# to remove - what accumulates is the installer it downloaded to run, and those
# are never cleaned up. On a machine the scheduled task upgrades nightly that
# is every installer of every package, in a temp directory nobody opens.
#
# Only the download cache. Nothing here uninstalls anything.

$housekeeping = $manifest.Housekeeping

if ($SkipCleanup) {
    Write-Phase 'Housekeeping - skipped (-SkipCleanup)'
} elseif (-not $housekeeping.Enabled) {
    Write-Phase 'Housekeeping - disabled in the manifest'
    Add-Result -Group 'housekeeping' -Id 'winget cache' -Action 'skipped' -Detail 'Enabled is false'
} else {
    Write-Phase 'Housekeeping - installers winget downloaded and left behind'

    $pruneCutoff = (Get-Date).AddDays(-$housekeeping.PruneDays)
    $cacheDirs = @(@(
            (Join-Path $env:TEMP 'WinGet')
            (Join-Path $script:StateRoot 'Temp\WinGet')
        ) | Where-Object { $_ -and (Test-Path -LiteralPath $_) } | Sort-Object -Unique)

    $staleFiles = @(
        foreach ($cacheDir in $cacheDirs) {
            Get-ChildItem -LiteralPath $cacheDir -Recurse -File -ErrorAction SilentlyContinue |
                Where-Object { $_.LastWriteTime -lt $pruneCutoff }
        }
    )
    $staleMb = Format-Size $staleFiles

    if ($cacheDirs.Count -eq 0) {
        Add-Result -Group 'housekeeping' -Id 'winget cache' -Action 'current' -Detail 'no download cache on this machine'
    } elseif ($staleFiles.Count -eq 0) {
        Add-Result -Group 'housekeeping' -Id 'winget cache' -Action 'current' `
            -Detail ('nothing older than {0} days' -f $housekeeping.PruneDays)
    } elseif (-not $PSCmdlet.ShouldProcess(('{0} file(s)' -f $staleFiles.Count), 'prune winget download cache')) {
        Add-Result -Group 'housekeeping' -Id 'winget cache' -Action 'would-upgrade' `
            -Detail ('{0} file(s), {1} to reclaim' -f $staleFiles.Count, $staleMb)
    } else {
        $removed = 0
        foreach ($staleFile in $staleFiles) {
            try {
                Remove-Item -LiteralPath $staleFile.FullName -Force -ErrorAction Stop -WhatIf:$false
                $removed++
            } catch {
                # A file the running installer still holds open comes back to
                # the next run, which is the whole point of pruning by age.
                Write-Verbose ('{0} is in use' -f $staleFile.FullName)
            }
        }
        if ($removed -eq $staleFiles.Count) {
            Add-Result -Group 'housekeeping' -Id 'winget cache' -Action 'upgraded' `
                -Detail ('{0} file(s) removed, {1} reclaimed' -f $removed, $staleMb)
        } else {
            Add-Result -Group 'housekeeping' -Id 'winget cache' -Action 'upgraded' `
                -Detail ('{0} of {1} file(s) removed, the rest were in use' -f $removed, $staleFiles.Count)
        }
    }

    # Reported, never touched: this one is winget's own state, not a download
    # it can fetch again.
    $appInstaller = Join-Path $script:StateRoot 'Packages\Microsoft.DesktopAppInstaller_8wekyb3d8bbwe\LocalState'
    if (Test-Path -LiteralPath $appInstaller) {
        $appInstallerMb = Format-Size @(Get-ChildItem -LiteralPath $appInstaller -Recurse -File -ErrorAction SilentlyContinue)
        Add-Result -Group 'housekeeping' -Id 'winget state' -Action 'present' `
            -Detail ('{0} in {1}' -f $appInstallerMb, $appInstaller)
    }
}

# Phase 3 - externally managed software

Write-Phase 'Externally managed - reported only'

$uninstallRoots = @(
    'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall'
    'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall'
    'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall'
)
$uninstallKeys = foreach ($uninstallRoot in $uninstallRoots) {
    Get-ChildItem $uninstallRoot -ErrorAction SilentlyContinue
}

foreach ($m in $manifest.Managed) {
    $hits = @($uninstallKeys |
            Where-Object { $_.PSChildName -like $m.Detect } |
            ForEach-Object { Get-ItemProperty $_.PSPath -ErrorAction SilentlyContinue } |
            Where-Object { Get-RegValue -Props $_ -Name 'DisplayName' })
    if ($hits.Count -gt 0) {
        $versions = @($hits |
                ForEach-Object { Get-RegValue -Props $_ -Name 'DisplayVersion' } |
                Where-Object { $_ } | Sort-Object -Unique) -join ', '
        if (-not $versions) { $versions = 'version not recorded' }
        Add-Result -Group 'managed' -Id $m.Id -Action 'present' -Detail ('{0} (via {1})' -f $versions, $m.By)
    } else {
        Add-Result -Group 'managed' -Id $m.Id -Action 'missing' -Detail ('install it from {0}' -f $m.By)
    }
}

# Phase 4 - shell

if ($SkipShell) {
    Write-Phase 'Shell - skipped (-SkipShell)'
} else {
    Write-Phase 'Shell - font, modules, profile, terminal'
    $shell = $manifest.Shell

    Install-NerdFont -Name $shell.NerdFont -Repo 'ryanoasis/nerd-fonts' -Match 'MesloLGMNerdFont'

    Deploy-ManagedFile -Source $script:StarshipTomlSource `
        -Target (Join-Path $env:USERPROFILE '.config\starship.toml') `
        -Group 'shell' -Label 'starship.toml'

    # atuin writes its own config.toml on first run, so the first deploy here
    # replaces a generated file rather than a hand-written one; Deploy-ManagedFile
    # still backs it up to .bak because it carries no marker of ours.
    Deploy-ManagedFile -Source (Join-Path $script:AtuinSource 'config.toml') `
        -Target (Join-Path $env:USERPROFILE '.config\atuin\config.toml') `
        -Group 'shell' -Label 'atuin config.toml'

    Deploy-ManagedFile -Source (Join-Path $script:AtuinSource 'themes\catppuccin-mocha.toml') `
        -Target (Join-Path $env:USERPROFILE '.config\atuin\themes\catppuccin-mocha.toml') `
        -Group 'shell' -Label 'atuin theme'

    # tealdeer config: turns on auto_update, so the tldr pages download on first
    # use and refresh themselves every 30 days. tldr itself is never run here -
    # with that key set, even `tldr --show-paths` can reach the network, so the
    # path is tealdeer's own rule: %APPDATA%\tealdeer\config.
    if (Get-Command tldr -ErrorAction SilentlyContinue) {
        Deploy-ManagedFile -Source (Join-Path $script:TealdeerSource 'config.toml') `
            -Target (Join-Path $env:APPDATA 'tealdeer\config\config.toml') `
            -Group 'shell' -Label 'tealdeer config'
    } else {
        Add-Result -Group 'shell' -Id 'tealdeer config' -Action 'missing' -Detail 'tldr is not installed'
    }

    # bat config: the theme bat, and through it delta, renders with. bat reads
    # %APPDATA%\bat on Windows, which is what `bat --config-dir` reports.
    if (Get-Command bat -ErrorAction SilentlyContinue) {
        $batConfig = (& bat --config-dir 2>$null)
        if (-not $batConfig) { $batConfig = Join-Path $env:APPDATA 'bat' }

        Deploy-ManagedFile -Source (Join-Path $script:BatSource 'config') `
            -Target (Join-Path $batConfig 'config') `
            -Group 'shell' -Label 'bat config'

        Deploy-ManagedFile -Source (Join-Path $script:BatSource 'themes\Catppuccin Mocha.tmTheme') `
            -Target (Join-Path $batConfig 'themes\Catppuccin Mocha.tmTheme') `
            -Group 'shell' -Label 'bat theme'

        # bat since 0.24 reads the themes directory at startup, so this is a
        # no-op on anything current - kept for an older bat, which only sees a
        # theme once it is in the cache.
        $themes = @(& bat --list-themes 2>$null)
        if ($themes -contains 'Catppuccin Mocha') {
            Add-Result -Group 'shell' -Id 'bat cache' -Action 'current' -Detail 'Catppuccin Mocha is in the theme list'
        } elseif ($WhatIfPreference) {
            Add-Result -Group 'shell' -Id 'bat cache' -Action 'would-install' -Detail 'bat cache --build'
        } else {
            & bat cache --build *> $null
            if ($LASTEXITCODE -eq 0) {
                Add-Result -Group 'shell' -Id 'bat cache' -Action 'installed' -Detail 'bat cache --build'
            } else {
                Add-Result -Group 'shell' -Id 'bat cache' -Action 'failed' -Detail 'run by hand: bat cache --build'
            }
        }
    } else {
        Add-Result -Group 'shell' -Id 'bat config' -Action 'missing' -Detail 'bat is not installed'
    }

    # carapace specs: completion for CLIs carapace has no completer of its own
    # for. carapace reads them from XDG_CONFIG_HOME when that is an absolute
    # path, and from %APPDATA% otherwise.
    if (Get-Command carapace -ErrorAction SilentlyContinue) {
        $carapaceConfig = $env:APPDATA
        if ($env:XDG_CONFIG_HOME -and [System.IO.Path]::IsPathRooted($env:XDG_CONFIG_HOME)) {
            $carapaceConfig = $env:XDG_CONFIG_HOME
        }
        foreach ($spec in Get-ChildItem (Join-Path $script:CarapaceSource 'specs') -Filter '*.yaml') {
            Deploy-ManagedFile -Source $spec.FullName `
                -Target (Join-Path $carapaceConfig "carapace\specs\$($spec.Name)") `
                -Group 'shell' -Label "carapace spec: $($spec.BaseName)" -Marker 'managed by the bootstrap'
        }
    } else {
        Add-Result -Group 'shell' -Id 'carapace specs' -Action 'missing' -Detail 'carapace is not installed'
    }

    $editions = @(
        @{ Name = '5.1'; Exe = 'powershell.exe'; Modules = $shell.Modules51 }
        @{ Name = '7'; Exe = 'pwsh.exe'; Modules = $shell.Modules7 }
    )
    foreach ($edition in $editions) {
        $label = 'modules (PS{0})' -f $edition.Name
        $exe = Get-Command $edition.Exe -ErrorAction SilentlyContinue
        if (-not $exe) {
            Add-Result -Group 'shell' -Id $label -Action 'skipped' -Detail "$($edition.Exe) not found"
            continue
        }
        $moduleList = @($edition.Modules | ForEach-Object { "'$_'" }) -join ', '
        $inner = @"
`$ErrorActionPreference = 'Stop'
`$want = @($moduleList)
`$floor = [version]'$($shell.PSReadLineMinimum)'
`$skipUpgrade = `$$($SkipUpgrade.IsPresent)
foreach (`$name in `$want) {
    try {
        `$have = Get-Module -ListAvailable -Name `$name |
            Sort-Object Version -Descending | Select-Object -First 1
        `$min = if (`$name -eq 'PSReadLine') { `$floor } else { `$null }
        `$meetsFloor = `$have -and (-not `$min -or `$have.Version -ge `$min)
        if (`$meetsFloor -and `$skipUpgrade) {
            "CURRENT|`$name|`$(`$have.Version)"
            continue
        }
        try {
            `$latest = (Find-Module -Name `$name -ErrorAction Stop).Version
        } catch {
            if (`$meetsFloor) { "CURRENT|`$name|`$(`$have.Version) (gallery unreachable)"; continue }
            throw
        }
        if (`$meetsFloor -and `$have.Version -ge `$latest) {
            "CURRENT|`$name|`$(`$have.Version)"
            continue
        }
        `$splat = @{ Name = `$name; Scope = 'CurrentUser'; Force = `$true; SkipPublisherCheck = `$true }
        if (`$min) { `$splat['MinimumVersion'] = `$min }
        Install-Module @splat
        if (`$have) { "UPGRADED|`$name|`$(`$have.Version) -> `$latest" }
        else { "INSTALLED|`$name|`$latest" }
    } catch {
        "FAILED|`$name|`$(`$_.Exception.Message)"
    }
}
"@
        if (-not $PSCmdlet.ShouldProcess(('PS{0}: {1}' -f $edition.Name, ($edition.Modules -join ', ')), 'check and install modules')) {
            Add-Result -Group 'shell' -Id $label -Action 'would-install' -Detail ($edition.Modules -join ', ')
            continue
        }
        $innerFile = Join-Path ([IO.Path]::GetTempPath()) ('bootstrap-modules-{0}.ps1' -f [guid]::NewGuid())
        Set-Content -LiteralPath $innerFile -Value $inner -Encoding UTF8
        try {
            $out = & {
                $ErrorActionPreference = 'Continue'
                & $exe.Source -NoProfile -ExecutionPolicy Bypass -File $innerFile 2>&1
            } | Out-String
        } finally {
            Remove-Item $innerFile -ErrorAction SilentlyContinue -WhatIf:$false
        }
        $lines = @($out -split "`r?`n" | Where-Object { $_ -match '^(CURRENT|INSTALLED|UPGRADED|FAILED)\|' })
        $describe = {
            param($Rows)
            @($Rows | ForEach-Object { $f = $_ -split '\|', 3; '{0} {1}' -f $f[1], $f[2] }) -join ', '
        }
        $failed = @($lines | Where-Object { $_ -like 'FAILED|*' })
        $changed = @($lines | Where-Object { $_ -like 'INSTALLED|*' -or $_ -like 'UPGRADED|*' })
        if ($lines.Count -eq 0) {
            Add-Result -Group 'shell' -Id $label -Action 'failed' -Detail (Get-LastLine $out)
        } elseif ($failed.Count -gt 0) {
            Add-Result -Group 'shell' -Id $label -Action 'failed' -Detail (& $describe $failed)
        } elseif ($changed.Count -gt 0) {
            $action = if (@($changed | Where-Object { $_ -like 'INSTALLED|*' }).Count -gt 0) { 'installed' } else { 'upgraded' }
            Add-Result -Group 'shell' -Id $label -Action $action -Detail (& $describe $changed)
        } else {
            Add-Result -Group 'shell' -Id $label -Action 'current' -Detail (& $describe $lines)
        }
    }

    $profileTargets = @(
        Join-Path $env:USERPROFILE 'Documents\WindowsPowerShell\Microsoft.PowerShell_profile.ps1'
        Join-Path $env:USERPROFILE 'Documents\PowerShell\Microsoft.PowerShell_profile.ps1'
    )
    foreach ($target in $profileTargets) {
        Deploy-ManagedFile -Source $script:ProfileSource -Target $target -Group 'shell' `
            -Label ('profile: ' + (Split-Path (Split-Path $target -Parent) -Leaf))
        Deploy-ToolsList -Target (Join-Path (Split-Path $target -Parent) 'tools-list.ps1')
    }

    $policy = [string](Get-ExecutionPolicy -Scope CurrentUser)
    if ($policy -in @('RemoteSigned', 'Unrestricted', 'Bypass')) {
        Add-Result -Group 'shell' -Id 'execution policy' -Action 'current' -Detail $policy
    } elseif ($PSCmdlet.ShouldProcess('CurrentUser', 'Set-ExecutionPolicy RemoteSigned')) {
        try {
            Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser -Force -ErrorAction Stop
        } catch {
            Write-Verbose "Set-ExecutionPolicy reported: $($_.Exception.Message)"
        }
        $now = [string](Get-ExecutionPolicy -Scope CurrentUser)
        if ($now -in @('RemoteSigned', 'Unrestricted', 'Bypass')) {
            $detail = "$policy -> $now"
            $effective = [string](Get-ExecutionPolicy)
            if ($effective -ne $now) { $detail += " (session stays $effective)" }
            Add-Result -Group 'shell' -Id 'execution policy' -Action 'installed' -Detail $detail
        } else {
            Add-Result -Group 'shell' -Id 'execution policy' -Action 'failed' -Detail "still $now"
        }
    } else {
        Add-Result -Group 'shell' -Id 'execution policy' -Action 'would-install' -Detail "$policy -> RemoteSigned"
    }

    if ($PSCmdlet.ShouldProcess('Windows Terminal settings.json', 'merge font, size, scheme, padding, copyOnSelect, scrollback, PowerShell 7 profile, default profile')) {
        $mergeArgs = @{
            FontFace        = $shell.TerminalFontFace
            FontSize        = $shell.TerminalFontSize
            ColorScheme     = $shell.TerminalColorScheme
            ColorSchemeDef  = $shell.TerminalColorSchemeDef
            CopyOnSelect    = $shell.TerminalCopyOnSelect
            Padding         = $shell.TerminalPadding
            HistorySize     = $shell.TerminalHistorySize
            Pwsh7Guid       = $shell.TerminalPwshGuid
            SetAsDefault    = $shell.TerminalSetPwshDefault
        }
        $out = (& $script:MergeScript @mergeArgs | Out-String).Trim()
        $action = if ($out -match 'CHANGED') { 'installed' } elseif ($out -match 'SKIPPED') { 'skipped' } else { 'current' }
        Add-Result -Group 'shell' -Id 'windows terminal' -Action $action -Detail $out
    } else {
        Add-Result -Group 'shell' -Id 'windows terminal' -Action 'would-install'
    }
}

# Phase 5 - mpv

$mpvExe = if ($SkipMpv) { $null } else { Resolve-MpvExe }

if ($SkipMpv) {
    Write-Phase 'mpv - skipped (-SkipMpv)'
} elseif (-not $mpvExe) {
    Write-Phase 'mpv - not installed, skipping config'
    Add-Result -Group 'mpv' -Id 'mpv' -Action 'missing' -Detail 'shinchiro.mpv not found on PATH, in the uninstall registry, or under Program Files'
} else {
    Write-Phase 'mpv - config, UI and scripts'
    Add-Result -Group 'mpv' -Id 'mpv' -Action 'present' -Detail $mpvExe
    $mpv = $manifest.Mpv
    $mpvDir = Join-Path $env:APPDATA 'mpv'

    if ($mpv.Contains('AddToPath') -and $mpv.AddToPath) {
        Add-UserPathEntry -Directory (Split-Path $mpvExe -Parent) -Group 'mpv' -Label 'mpv on PATH'
    }

    foreach ($name in @('mpv.conf', 'input.conf', 'script-opts\autoload.conf')) {
        Deploy-ManagedFile -Source (Join-Path $script:MpvSource $name) `
            -Target (Join-Path $mpvDir $name) -Label $name -Group 'mpv'
    }

    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

    foreach ($addon in $mpv.Addons) {
        Install-MpvAddon -Addon $addon -MpvDir $mpvDir
    }
}

# Phase 6 - schedule

$schedule = $manifest.Schedule

if ($SkipSchedule) {
    Write-Phase 'Schedule - skipped (-SkipSchedule)'
} elseif (-not $schedule.Enabled) {
    Write-Phase 'Schedule - disabled in the manifest'
    Add-Result -Group 'schedule' -Id $schedule.TaskName -Action 'skipped' -Detail 'Enabled is false'
} else {
    Write-Phase 'Schedule - daily unattended run'

    $logDir = Join-Path $env:LOCALAPPDATA $schedule.LogDir

    if (Test-Path $logDir) {
        $cutoff = (Get-Date).AddDays(-$schedule.KeepLogDays)
        $stale = @(Get-ChildItem $logDir -Filter 'bootstrap-*.log' -ErrorAction SilentlyContinue |
                Where-Object { $_.LastWriteTime -lt $cutoff })
        if ($stale.Count -gt 0 -and $PSCmdlet.ShouldProcess("$($stale.Count) log file(s)", 'prune')) {
            $stale | Remove-Item -Force -ErrorAction SilentlyContinue -WhatIf:$false
            Add-Result -Group 'schedule' -Id 'log pruning' -Action 'installed' `
                -Detail ('removed {0} older than {1} days' -f $stale.Count, $schedule.KeepLogDays)
        }
    }

    if (-not (Test-Elevated)) {
        Add-Result -Group 'schedule' -Id $schedule.TaskName -Action 'skipped' `
            -Detail 'needs an elevated run to register a task that installs software'
    } elseif (-not $script:PwshForTask) {
        Add-Result -Group 'schedule' -Id $schedule.TaskName -Action 'failed' `
            -Detail 'no pwsh or powershell.exe on PATH to point the task at'
    } else {
        $logExpr = "(Join-Path '$logDir' ('bootstrap-{0:yyyy-MM-dd}.log' -f (Get-Date)))"
        $inner = "& '$script:ScriptSelf' -Silent *>&1 | Tee-Object -FilePath $logExpr -Append"
        $taskArgs = '-NoProfile -ExecutionPolicy Bypass -Command "' + $inner + '"'

        $action = New-ScheduledTaskAction -Execute $script:PwshForTask -Argument $taskArgs `
            -WorkingDirectory $script:ToolRoot
        $trigger = New-ScheduledTaskTrigger -Daily -At $schedule.Time
        $settings = New-ScheduledTaskSettingsSet -StartWhenAvailable `
            -DontStopIfGoingOnBatteries -AllowStartIfOnBatteries `
            -ExecutionTimeLimit (New-TimeSpan -Hours 2)
        $principal = New-ScheduledTaskPrincipal `
            -UserId ([Security.Principal.WindowsIdentity]::GetCurrent().Name) `
            -LogonType Interactive -RunLevel Highest

        $existing = Get-ScheduledTask -TaskName $schedule.TaskName -ErrorAction SilentlyContinue

        $isCurrent = $false
        if ($existing) {
            $sameCmd = (@($existing.Actions).Execute -eq $script:PwshForTask -and
                @($existing.Actions).Arguments -eq $taskArgs)
            $sameTime = @($existing.Triggers | Where-Object {
                    $_.StartBoundary -and
                    ([datetime]$_.StartBoundary).ToString('HH:mm') -eq $schedule.Time
                }).Count -gt 0
            $isCurrent = $sameCmd -and $sameTime
        }

        if ($isCurrent) {
            Add-Result -Group 'schedule' -Id $schedule.TaskName -Action 'current' `
                -Detail ('daily at {0}, logs in {1}' -f $schedule.Time, $logDir)
        } elseif (-not $PSCmdlet.ShouldProcess($schedule.TaskName, 'register daily task')) {
            $act = if ($existing) { 'would-upgrade' } else { 'would-install' }
            Add-Result -Group 'schedule' -Id $schedule.TaskName -Action $act `
                -Detail ('daily at {0}' -f $schedule.Time)
        } else {
            try {
                New-Item -ItemType Directory -Path $logDir -Force | Out-Null
                $null = Register-ScheduledTask -TaskName $schedule.TaskName -Action $action `
                    -Trigger $trigger -Settings $settings -Principal $principal -Force `
                    -Description 'Runs the Windows bootstrap unattended, taking package and script updates.'
                $act = if ($existing) { 'upgraded' } else { 'installed' }
                Add-Result -Group 'schedule' -Id $schedule.TaskName -Action $act `
                    -Detail ('daily at {0}, logs in {1}' -f $schedule.Time, $logDir)
            } catch {
                Add-Result -Group 'schedule' -Id $schedule.TaskName -Action 'failed' -Detail $_.Exception.Message
            }
        }
    }
}

# Phase 7 - VS Code extensions

if ($SkipVsCode) {
    Write-Phase 'VS Code extensions - skipped (-SkipVsCode)'
} else {
    $codeExe = Get-Command code -ErrorAction SilentlyContinue
    if (-not $codeExe) {
        Write-Phase 'VS Code extensions - code CLI not on PATH, skipping'
        Add-Result -Group 'vscode' -Id 'vscode extensions' -Action 'missing' `
            -Detail 'code CLI not found - install VS Code, then "Shell Command: Install code command in PATH"'
    } else {
        Write-Phase 'VS Code extensions - install what is missing, never remove'
        $installed = @(& code --list-extensions 2>$null)
        foreach ($extId in $manifest.VsCodeExtensions) {
            if ($installed -contains $extId) {
                Add-Result -Group 'vscode' -Id $extId -Action 'present'
            } elseif (-not $PSCmdlet.ShouldProcess($extId, 'code --install-extension')) {
                Add-Result -Group 'vscode' -Id $extId -Action 'would-install'
            } else {
                & code --install-extension $extId *> $null
                if ($LASTEXITCODE -eq 0) {
                    Add-Result -Group 'vscode' -Id $extId -Action 'installed'
                } else {
                    Add-Result -Group 'vscode' -Id $extId -Action 'failed' -Detail 'code --install-extension failed'
                }
            }
        }
    }
}

# Git - LFS and Unity's merge tool

# Windows PowerShell 5.1, and 7.0-7.2, hand a native program the double quotes
# inside an argument unescaped, so its parser eats them: git stored
# `difft "$LOCAL" "$REMOTE"` as `difft $LOCAL $REMOTE`. 7.3+ escapes them itself,
# unless $PSNativeCommandArgumentPassing is set back to Legacy.
function ConvertTo-NativeArgument {
    param([string]$Value)
    $v = $PSVersionTable.PSVersion
    $mode = Get-Variable -Name PSNativeCommandArgumentPassing -ValueOnly -ErrorAction SilentlyContinue
    if ($v.Major -lt 7 -or ($v.Major -eq 7 -and $v.Minor -lt 3) -or $mode -eq 'Legacy') {
        return $Value.Replace('"', '\"')
    }
    return $Value
}

$git = $manifest.Git

if ($SkipShell) {
    Write-Phase 'Git - skipped (-SkipShell)'
} else {
    Write-Phase 'Git - LFS and Unity merge tool'

    $gitExe = Get-Command git -ErrorAction SilentlyContinue
    if (-not $gitExe) {
        Add-Result -Group 'git' -Id 'git' -Action 'missing' -Detail 'install the dev group first'
    } else {

        if (-not $git.LfsEnabled) {
            Add-Result -Group 'git' -Id 'git-lfs' -Action 'skipped' -Detail 'LfsEnabled is false'
        } else {
            $lfsVersion = (& git lfs version 2>&1 | Out-String).Trim()
            if ($LASTEXITCODE -ne 0) {
                Add-Result -Group 'git' -Id 'git-lfs' -Action 'missing' -Detail 'not bundled with this Git install; re-run the Git installer'
            } else {
                $filter = (& git config --global --get filter.lfs.process 2>$null)
                if ($filter) {
                    Add-Result -Group 'git' -Id 'git-lfs' -Action 'current' -Detail (($lfsVersion -split '\s+')[0])
                } elseif (-not $PSCmdlet.ShouldProcess('git lfs install', 'configure')) {
                    Add-Result -Group 'git' -Id 'git-lfs' -Action 'would-install' -Detail 'git lfs install'
                } else {
                    & git lfs install --skip-repo *> $null
                    if ($LASTEXITCODE -eq 0) {
                        Add-Result -Group 'git' -Id 'git-lfs' -Action 'installed' -Detail 'global filters configured'
                    } else {
                        Add-Result -Group 'git' -Id 'git-lfs' -Action 'failed' -Detail 'git lfs install failed'
                    }
                }
            }
        }

        if (-not $git.UnityMergeEnabled) {
            Add-Result -Group 'git' -Id 'UnityYAMLMerge' -Action 'skipped' -Detail 'UnityMergeEnabled is false'
        } else {
            $tool = $null
            if (Test-Path $git.UnityEditorRoot) {
                $tool = Get-ChildItem $git.UnityEditorRoot -Directory -ErrorAction SilentlyContinue |
                    Sort-Object -Descending {
                        $n = ($_.Name -replace '[a-zA-Z].*$', '')
                        try { [version]$n } catch { [version]'0.0' }
                    } |
                    ForEach-Object { Join-Path $_.FullName $git.UnityMergeRelPath } |
                    Where-Object { Test-Path $_ } |
                    Select-Object -First 1
            }

            if (-not $tool) {
                Add-Result -Group 'git' -Id 'UnityYAMLMerge' -Action 'missing' -Detail "no editor with the tool under $($git.UnityEditorRoot)"
            } else {
                $want = '''{0}'' merge -p "$BASE" "$REMOTE" "$LOCAL" "$MERGED"' -f $tool
                $have = (& git config --global --get 'mergetool.unityyamlmerge.cmd' 2>$null)

                if ($have -eq $want) {
                    Add-Result -Group 'git' -Id 'UnityYAMLMerge' -Action 'current' -Detail $tool
                } elseif (-not $PSCmdlet.ShouldProcess('mergetool.unityyamlmerge', 'git config --global')) {
                    $action = if ($have) { 'would-upgrade' } else { 'would-install' }
                    Add-Result -Group 'git' -Id 'UnityYAMLMerge' -Action $action -Detail $tool
                } else {
                    & git config --global 'mergetool.unityyamlmerge.cmd' (ConvertTo-NativeArgument $want)
                    & git config --global 'mergetool.unityyamlmerge.trustExitCode' 'false'
                    if ($LASTEXITCODE -eq 0) {
                        $action = if ($have) { 'upgraded' } else { 'installed' }
                        Add-Result -Group 'git' -Id 'UnityYAMLMerge' -Action $action -Detail $tool
                    } else {
                        Add-Result -Group 'git' -Id 'UnityYAMLMerge' -Action 'failed' -Detail 'git config --global failed'
                    }
                }
            }
        }

        # Set only when unset: an existing value is somebody's choice, not drift.
        $gitWant = [System.Collections.Generic.List[hashtable]]::new()

        # Defaults that have nothing to do with the tools below - each one only
        # takes effect where the key is unset, so an existing choice is never
        # overwritten.
        # push.autoSetupRemote: `git push` on a new branch sets the upstream
        #   itself instead of failing with a command to paste. git >= 2.37.
        # fetch.prune: drops remote-tracking refs for branches deleted
        #   upstream, so completion stops offering dead origin/* names.
        # diff.algorithm: histogram reads better than myers on moved and
        #   reindented code; delta and difftastic render what it produces.
        # rebase.autoStash: rebase stashes dirty work itself, rather than
        #   refusing to start.
        # column.ui: branch and status lists print in columns.
        # merge.conflictStyle: zdiff3 adds the common ancestor to a conflict,
        #   showing what each side changed. git >= 2.35.
        # tag.sort: v1.10.0 above v1.9.0. The field is version:refname - plain
        #   '-version' is rejected with "unknown field name: version".
        $gitWant.Add(@{ Key = 'push.autoSetupRemote';  Value = 'true' })
        $gitWant.Add(@{ Key = 'fetch.prune';           Value = 'true' })
        $gitWant.Add(@{ Key = 'diff.algorithm';        Value = 'histogram' })
        $gitWant.Add(@{ Key = 'rebase.autoStash';      Value = 'true' })
        $gitWant.Add(@{ Key = 'column.ui';             Value = 'auto' })
        $gitWant.Add(@{ Key = 'merge.conflictStyle';   Value = 'zdiff3' })
        $gitWant.Add(@{ Key = 'tag.sort';              Value = '-version:refname' })

        # delta is the pager for diff, show, log and add -p; `git sdiff` is the
        # same view side by side.
        if (-not $git.DeltaEnabled) {
            Add-Result -Group 'git' -Id 'delta' -Action 'skipped' -Detail 'DeltaEnabled is false'
        } elseif (-not (Get-Command delta -ErrorAction SilentlyContinue)) {
            Add-Result -Group 'git' -Id 'delta' -Action 'missing' -Detail 'delta is not installed'
        } else {
            $gitWant.Add(@{ Key = 'core.pager';             Value = 'delta' })
            $gitWant.Add(@{ Key = 'interactive.diffFilter'; Value = 'delta --color-only' })
            $gitWant.Add(@{ Key = 'alias.sdiff';            Value = "-c core.pager='delta --side-by-side' diff" })
            # delta highlights through bat's theme store - the same Catppuccin
            # Mocha the shell phase installs, so a diff and a `bat` of the same
            # file match.
            if (Get-Command bat -ErrorAction SilentlyContinue) {
                $gitWant.Add(@{ Key = 'delta.syntax-theme'; Value = 'Catppuccin Mocha' })
            }
        }

        # difftastic compares syntax, not lines, and is asked for per command -
        # never diff.external globally, whose output is not a patch `git apply`
        # can read. delta passes its output through untouched, so the pager
        # needs no exception.
        if (-not $git.DifftasticEnabled) {
            Add-Result -Group 'git' -Id 'difftastic' -Action 'skipped' -Detail 'DifftasticEnabled is false'
        } elseif (-not (Get-Command difft -ErrorAction SilentlyContinue)) {
            Add-Result -Group 'git' -Id 'difftastic' -Action 'missing' -Detail 'difft is not installed'
        } else {
            $gitWant.Add(@{ Key = 'diff.tool';               Value = 'difftastic' })
            $gitWant.Add(@{ Key = 'difftool.prompt';         Value = 'false' })
            $gitWant.Add(@{ Key = 'difftool.difftastic.cmd'; Value = 'difft "$LOCAL" "$REMOTE"' })
            $gitWant.Add(@{ Key = 'pager.difftool';          Value = 'true' })
            $gitWant.Add(@{ Key = 'alias.dft';               Value = 'difftool' })
            $gitWant.Add(@{ Key = 'alias.ddiff';             Value = '-c diff.external=difft diff' })
            $gitWant.Add(@{ Key = 'alias.dshow';             Value = '-c diff.external=difft show --ext-diff' })
            $gitWant.Add(@{ Key = 'alias.dlog';              Value = '-c diff.external=difft log -p --ext-diff' })
        }

        foreach ($pair in $gitWant) {
            $have = (& git config --global --get $pair.Key 2>$null)
            if ($have -eq $pair.Value) {
                Add-Result -Group 'git' -Id $pair.Key -Action 'current' -Detail $pair.Value
            } elseif ($have) {
                Add-Result -Group 'git' -Id $pair.Key -Action 'present' -Detail "$have - left alone"
            } elseif (-not $PSCmdlet.ShouldProcess($pair.Key, 'git config --global')) {
                Add-Result -Group 'git' -Id $pair.Key -Action 'would-install' -Detail $pair.Value
            } else {
                & git config --global $pair.Key (ConvertTo-NativeArgument $pair.Value)
                if ($LASTEXITCODE -eq 0) {
                    Add-Result -Group 'git' -Id $pair.Key -Action 'installed' -Detail $pair.Value
                } else {
                    Add-Result -Group 'git' -Id $pair.Key -Action 'failed' -Detail 'git config --global failed'
                }
            }
        }
    }
}

# Summary

Write-Phase 'Summary'

$order = @('installed', 'upgraded', 'would-install', 'would-upgrade', 'failed',
    'missing', 'held', 'skipped', 'current', 'present')
$script:Results | Group-Object Action | Sort-Object { $order.IndexOf($_.Name) } | ForEach-Object {
    Write-Host ('  {0,-16}{1}' -f $_.Name, $_.Count)
}

$failed = @($script:Results | Where-Object { $_.Action -eq 'failed' })
if ($failed.Count -gt 0) {
    Write-Host ''
    Write-Host '  Failures:' -ForegroundColor Red
    $failed | ForEach-Object { Write-Host ('    {0,-44}{1}' -f $_.Id, $_.Detail) -ForegroundColor Red }
}

$changed = @($script:Results | Where-Object { $_.Action -in @('installed', 'upgraded') })
if ($changed.Count -gt 0) {
    Write-Host ''
    Write-Host '  Open a new terminal to pick up PATH and profile changes.' -ForegroundColor Yellow
}

Write-Host ''

$exitCode = if ($failed.Count -gt 0) { 1 } else { 0 }
Write-RunRecord -ExitCode $exitCode
Send-FailureNotification -ExitCode $exitCode
if ($exitCode -ne 0) { exit $exitCode }
