#Requires -Version 5.1
<#
.SYNOPSIS
    Installs and updates this Windows machine's software from packages.psd1.

.DESCRIPTION
    Run it on a fresh machine to build the machine out; run it again any time
    to take updates. Both are the same command - the script works out per
    package which one it is doing.

    Everything it acts on comes from packages.psd1, which sorts software by
    who owns it: winget packages it installs and upgrades, pinned packages it
    leaves alone in both directions, and software owned by another installer
    (Unity Hub, JetBrains Toolbox) that it only detects and reports.

    See README.md.

.PARAMETER Groups
    Limit to named groups from the manifest, e.g. -Groups shell,cli.
    Default is every group. -ListGroups prints what is available.

.PARAMETER SkipUpgrade
    Install what is missing, but leave installed versions alone.

.PARAMETER SkipShell
    Skip the shell phase (Nerd Font, PowerShell modules, profile, Windows
    Terminal settings) and do packages only.

.PARAMETER SkipMpv
    Skip the mpv phase - its config, the uosc UI and thumbfast - and leave
    whatever is in %APPDATA%mpv alone.

.PARAMETER IncludeUnknown
    Pass --include-unknown to winget upgrade, which makes it act on packages
    whose installed version it cannot parse - typically things installed by
    hand outside winget. Off by default: that flag is how an "update" run
    starts reinstalling software over the top of a working manual install.

.PARAMETER Silent
    Pass --silent to winget, suppressing installer UI. Off by default because
    a handful of installers behave differently unattended, and a silent
    failure is worse than a visible one.

.EXAMPLE
    .\bootstrap.ps1 -WhatIf
    Show everything that would change, touch nothing.

.EXAMPLE
    .\bootstrap.ps1
    Install what is missing and take every available upgrade except pins.

.EXAMPLE
    .\bootstrap.ps1 -Groups cli,dev -SkipShell
    Just the command-line and development packages.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string[]]$Groups,
    [switch]$SkipUpgrade,
    [switch]$SkipShell,
    [switch]$SkipMpv,
    [switch]$IncludeUnknown,
    [switch]$Silent,
    [switch]$ListGroups,
    [switch]$ShowVersion,
    [string]$ManifestPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# $PSScriptRoot is EMPTY while parameter defaults are evaluated, when an
# ADVANCED script - one carrying [CmdletBinding()] - is launched with
# `powershell.exe -File`. Measured in both 5.1 and 7: remove the attribute and
# it is populated, keep it and the default quietly becomes Join-Path '' '...',
# which throws before a single line of the body runs.
#
# That is the exact invocation README.md recommends for a downloaded copy, so
# it broke the one path a new machine actually takes while every form used
# during development - `.\bootstrap.ps1` from a prompt, and -Command - worked
# fine. Hence resolving every path here in the body, where $PSScriptRoot is
# populated normally, and never in the param block.
$script:ToolRoot = $PSScriptRoot
if (-not $script:ToolRoot) { $script:ToolRoot = Split-Path -Parent $MyInvocation.MyCommand.Path }

# Every sibling file this script needs is resolved HERE, once, before anything
# else runs - and never again deeper in the file. That is not tidiness, it is
# the fix for a real bug.
#
# 1.0.2 kept the directory in $script:Root, and the externally-managed phase
# later ran `foreach ($root in $uninstallRoots)`. A bare $root at script scope
# IS $script:Root: PowerShell variable names are case-insensitive, and an
# unscoped assignment writes to the enclosing scope. So an unrelated loop over
# registry hives silently repointed the tool's own directory at
# HKLM:\SOFTWARE\WOW6432Node\...\Uninstall.
#
# What made it hard to read is where it surfaced. The profile path became
# HKLM:\...\Uninstall\profile.ps1, so Get-Content dispatched to the REGISTRY
# provider, which has no -Raw parameter - that one is FileSystem-specific. The
# run therefore died on "A parameter cannot be found that matches parameter
# name 'Raw'", a message that points at the wrong line, the wrong parameter,
# and says nothing whatsoever about a clobbered variable.
$script:ProfileSource = Join-Path $script:ToolRoot 'profile.ps1'
$script:MergeScript = Join-Path $script:ToolRoot 'merge-terminal-settings.ps1'
$script:MpvSource = Join-Path $script:ToolRoot 'mpv'
if (-not $ManifestPath) { $ManifestPath = Join-Path $script:ToolRoot 'packages.psd1' }

# The single source of truth for this tool's version, and the ONLY place it is
# written down. .github/workflows/release.yml parses this exact line and
# refuses to publish when it disagrees with the git tag being released, so a
# downloaded copy can never report a different number than the release it came
# from. Keep the line shape - `$script:BootstrapVersion = '<semver>'` - or that
# check silently stops finding it.
#
# Bump it in the same commit as the change it describes, and add a
# windows/CHANGELOG.md entry; the release notes are read from that file.
$script:BootstrapVersion = '1.3.0'

# Deliberately -ShowVersion and not -Version: PowerShell reserves -Version on
# some hosts, and a parameter that silently binds to something else is a bad
# way to find out.
if ($ShowVersion) {
    Write-Output $script:BootstrapVersion
    return
}

# ============================================================
# Output helpers
# ============================================================

$script:Results = New-Object System.Collections.ArrayList

function Write-Phase {
    param([string]$Text)
    Write-Host ''
    Write-Host "== $Text " -ForegroundColor Cyan -NoNewline
    Write-Host ('=' * [Math]::Max(0, 60 - $Text.Length)) -ForegroundColor DarkCyan
}

# One line per package, colour-coded by what happened, plus a row for the
# summary. Every code path that decides something about a package ends here,
# so the summary can never disagree with the live output.
function Add-Result {
    param(
        [string]$Group,
        [string]$Id,
        [ValidateSet('installed', 'upgraded', 'current', 'held', 'present',
                     'missing', 'failed', 'would-install', 'would-upgrade', 'skipped')]
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
        default         { 'DarkGray' }
    }
    Write-Host ('  {0,-14}' -f $Action) -ForegroundColor $colour -NoNewline
    Write-Host ('{0,-44}' -f $Id) -NoNewline
    Write-Host $Detail -ForegroundColor DarkGray
    [void]$script:Results.Add([pscustomobject]@{
            Group = $Group; Id = $Id; Action = $Action; Detail = $Detail
        })
}

# ============================================================
# Environment
# ============================================================

function Test-Elevated {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    return (New-Object Security.Principal.WindowsPrincipal $id).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
}

# A winget install writes the new tool's directory into the registry PATH, but
# nothing rewrites the PATH of a process that is already running - so without
# this, a package installed at the top of the run is still invisible to a
# Get-Command check at the bottom of it. A tool that runs each step as its own
# fresh process gets the new PATH for free; one long-lived script does not.
function Update-SessionPath {
    $registry = @(
        [Environment]::GetEnvironmentVariable('Path', 'Machine')
        [Environment]::GetEnvironmentVariable('Path', 'User')
    ) | Where-Object { $_ }
    $fromRegistry = @(($registry -join ';') -split ';' | Where-Object { $_ })

    # Merged, not replaced. A plain assignment picks up what was just installed
    # but silently discards whatever the CALLING session had added to its own
    # process PATH - a directory put there by hand, a tool on a temporary path.
    # This script has no business editing its caller's environment beyond
    # adding what it installed.
    $extra = @($env:Path -split ';' | Where-Object { $_ -and $fromRegistry -notcontains $_ })
    $env:Path = (@($fromRegistry) + $extra | Select-Object -Unique) -join ';'
}

# ============================================================
# winget
# ============================================================

# winget reports "nothing to do" as a FAILURE exit code, with the reason only
# in the text. Matching on the text is unpleasant, but it is the only signal
# that separates "already up to date" from "the download 404'd", and getting
# that wrong turns a clean run into a wall of red.
$script:WingetNoop = 'No applicable upgrade|No available upgrade|No newer package|No applicable update|already installed|No installed package found'

function Invoke-Winget {
    param([string[]]$WingetArgs)
    # Same guard as the module step, for the same reason: `2>&1` turns anything
    # winget writes to stderr into NativeCommandError records, and this file
    # runs under $ErrorActionPreference = 'Stop', so one stderr line would end
    # the run here instead of being reported as a failed package. Dropped to
    # Continue for the call only - the text is still captured and the exit code
    # is still what decides the result.
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

# Preferred: one `winget export` for the whole machine, which is real JSON and
# avoids the column-width guessing that parsing `winget list` output requires.
# Falls back to probing each id individually if export fails - slower, but
# never wrong.
function Get-InstalledPackages {
    $file = Join-Path $env:TEMP ('winget-export-{0}.json' -f [guid]::NewGuid())
    try {
        $null = Invoke-Winget @('export', '-o', $file, '--include-versions',
            '--accept-source-agreements', '--disable-interactivity')
        if (-not (Test-Path $file)) { return $null }
        $json = Get-Content $file -Raw | ConvertFrom-Json
        if (-not $json.PSObject.Properties['Sources']) { return $null }
        # PowerShell hashtables are case-insensitive for string keys by
        # default, which matters here: winget ids are not consistently cased
        # between `search` output and `export` output.
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
        # -WhatIf:$false because this is our own scratch file, not a change to
        # the machine. Without it a -WhatIf run prints a "Remove File" line and
        # then leaves the temp JSON behind on every invocation.
        Remove-Item $file -ErrorAction SilentlyContinue -WhatIf:$false
    }
}

# One `winget upgrade` listing for the whole machine. Used ONLY to make a
# -WhatIf preview honest: without it every installed package previews as
# "would-upgrade", which is true in the sense that the command would run and
# useless in the sense that most of them have nothing waiting.
#
# Deliberately not used to skip work in a real run, tempting though that is.
# winget truncates long ids to fit the column ("SomePublisher.SomeLongPro...")
# so a package missing from this text has NOT been proven up to date - and
# silently skipping an upgrade is a worse failure than spending a second
# per package to ask properly.
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

# The version a package would move TO, pulled out of the same listing.
# `winget upgrade` prints Name / Id / Version / Available / Source, and ids
# never contain spaces, so the two tokens after the id are the current and
# available versions.
#
# Returns '' rather than guessing when the row cannot be read - winget wraps
# and truncates to fit the console, so a row is not always parseable. Every
# caller falls back to showing just the installed version, which is the honest
# outcome: a missing arrow means "could not read it", never "no upgrade".
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

# "10.4.2 -> 10.5.0" when both are known, otherwise whatever is known.
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
    } else {
        Add-Result -Group $Group -Id $Id -Action 'failed' -Detail ('exit {0}: {1}' -f $r.ExitCode, (Get-LastLine $r.Output))
    }
}

# ============================================================
# Managed files
# ============================================================

# Our file, in a directory the user also owns. That is true of the PowerShell
# profile and of both mpv configs, and all three want the same care: replace
# our own copy freely, but never silently destroy something hand-written.
# Anything already there without the marker is copied to .bak first.
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
    # Copy-Item carries Zone.Identifier across, so a marked source would deploy
    # a file PowerShell refuses to load - silently, in the profile's case.
    Unblock-File $Target -ErrorAction SilentlyContinue
    Add-Result -Group $Group -Id $Label -Action 'installed' -Detail $detail
}

# ============================================================
# mpv add-ons
# ============================================================

# StrictMode 'Latest' turns a missing property into a terminating error, and
# uninstall keys are exactly where that bites: most of the ~2000 keys under
# those hives carry no DisplayName at all. Indexing PSObject.Properties is a
# collection lookup rather than a property access, so an absent value comes
# back as $null instead of throwing.
function Get-RegValue {
    param($Props, [string]$Name)
    if ($null -eq $Props) { return $null }
    $prop = $Props.PSObject.Properties[$Name]
    if ($null -eq $prop) { return $null }
    return $prop.Value
}

# `Get-Command mpv` answers "can I type mpv at a prompt", which is NOT the
# question this script is asking. shinchiro.mpv is a plain installer, not one
# of winget's shimmed portable packages: it drops mpv.exe in
# "C:\Program Files\MPV Player\" and adds nothing to PATH, nor a shim to
# %LOCALAPPDATA%\Microsoft\WinGet\Links. So the PATH probe reported "missing"
# on a machine where `winget list shinchiro.mpv` reported v0.41.0, and the
# entire mpv phase - config, uosc, thumbfast - was skipped on every run.
# Update-SessionPath cannot rescue it either: there is nothing in the registry
# PATH to pick up.
#
# Ask the installer where it put things instead. Registry before the
# well-known directories on purpose: a machine can also carry an older,
# unregistered C:\Program Files\mpv, and InstallLocation is the only source
# that names the copy winget is actually managing.
# Adding a directory to the user's PATH permanently, done the careful way.
#
# The one-line version of this is
# [Environment]::SetEnvironmentVariable('Path', "$old;$new", 'User'), and it is
# the line that eats people's PATHs. GetEnvironmentVariable EXPANDS the value
# it reads, so %USERPROFILE%\bin comes back as C:\Users\someone\bin; writing
# that back stores the expanded text and, worse, stores it as a plain REG_SZ.
# Every %VAR% entry the user had is then frozen to whatever it meant at that
# moment, and the variable stops being REG_EXPAND_SZ for everything afterwards.
# The damage is silent and shows up much later on a machine whose profile
# directory moved.
#
# So the raw value is read with DoNotExpandEnvironmentNames, appended to, and
# written back with the ORIGINAL value kind.
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

    # TrimEnd('\') on both sides so "C:\Program Files\mpv" and the same path
    # with a trailing separator are not both added, which is how a PATH grows a
    # duplicate on every run.
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
        # This process too, so anything later in the run can find it.
        $env:Path = $env:Path.TrimEnd(';') + ';' + $Directory
        # Already-running processes read their environment once, at start, and
        # Explorer is one of them - so without this a terminal opened AFTER the
        # change still inherits Explorer's stale copy, and the entry looks like
        # it did not take. WM_SETTINGCHANGE is what tells the shell to re-read.
        # Best-effort: a machine that refuses the P/Invoke still got the
        # registry write, which is the part that persists.
        try {
            if (-not ('NativeMethods.WinApi' -as [type])) {
                Add-Type -Namespace 'NativeMethods' -Name 'WinApi' -MemberDefinition @'
[DllImport("user32.dll", SetLastError = true, CharSet = CharSet.Auto)]
public static extern IntPtr SendMessageTimeout(IntPtr hWnd, uint Msg, UIntPtr wParam,
    string lParam, uint fuFlags, uint uTimeout, out UIntPtr lpdwResult);
'@
            }
            $result = [UIntPtr]::Zero
            # HWND_BROADCAST 0xffff, WM_SETTINGCHANGE 0x1A, SMTO_ABORTIFHUNG 0x2
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

# uosc and thumbfast are downloaded rather than packaged, so "is it already
# there" needs an answer the filesystem cannot give: a stamp file recording
# which version was written. Without it every run re-downloads 8MB to end up
# where it started.
# A commit sha is 40 characters and turns the summary into a wall of hex. Seven
# is what git itself abbreviates to, and the stamp file keeps the full value, so
# nothing is lost by shortening the DISPLAY only.
function Format-AddonVersion {
    param([string]$Version)
    if ($Version -match '^[0-9a-f]{40}$') { return $Version.Substring(0, 7) }
    return $Version
}

# Ask GitHub what the newest version is. Returns $null on any failure rather
# than throwing - the caller decides what an unanswerable question means, and
# the answer is different depending on whether anything is already installed.
function Resolve-MpvAddonVersion {
    param($Addon)
    # GitHub rejects requests without a User-Agent. PowerShell sends one by
    # default, but it differs between 5.1 and 7, so set it here rather than
    # depend on the host.
    $headers = @{ 'User-Agent' = 'windows-bootstrap' }
    try {
        if ($Addon.Source -eq 'release') {
            $uri = 'https://api.github.com/repos/{0}/releases/latest' -f $Addon.Repo
            $r = Invoke-RestMethod -Uri $uri -Headers $headers -UseBasicParsing
            if ($r.PSObject.Properties['tag_name']) { return [string]$r.tag_name }
            return $null
        }
        $uri = 'https://api.github.com/repos/{0}/commits?per_page=1' -f $Addon.Repo
        # Path narrows the query to commits touching one file. mpv-player/mpv
        # takes dozens of commits a week, almost none of them to autoload.lua;
        # without this the sha would change constantly and re-download a
        # byte-identical script every time.
        if ($Addon.Contains('Path')) { $uri += '&path={0}' -f [uri]::EscapeDataString($Addon.Path) }
        # Assigned to a variable and THEN flattened. Invoke-RestMethod writes
        # a JSON array to the pipeline as ONE un-enumerated Object[], so two
        # otherwise reasonable spellings both fail:
        #   @(Invoke-RestMethod ...)          -> 1-element array holding the array
        #   Invoke-RestMethod ... | Select -First 1 -> the array itself
        # Only `@($variable)` enumerates it into the commits it contains.
        #
        # Worth spelling out because the broken version LOOKS correct:
        # `$r[0].sha` still yields the right string, since property access on
        # an array auto-unrolls via member enumeration. It is the existence
        # check, `.PSObject.Properties['sha']`, that does not unroll - so the
        # guard said "no sha here" about an object whose sha reads back fine.
        $response = Invoke-RestMethod -Uri $uri -Headers $headers -UseBasicParsing
        $commits = @($response)
        if ($commits.Count -gt 0 -and $commits[0].PSObject.Properties['sha']) {
            return [string]$commits[0].sha
        }
        return $null
    } catch {
        # Rate limiting lands here too: unauthenticated GitHub allows 60 calls
        # an hour and answers 403 after that, which is a failure to ANSWER, not
        # a failure of the run.
        Write-Verbose "Could not resolve $($Addon.Name): $($_.Exception.Message)"
        return $null
    }
}

# uosc and the three Lua scripts are downloaded rather than packaged, so "is it
# already there" needs an answer the filesystem cannot give: a stamp file
# recording which version was written. Without it every run re-downloads 8MB to
# end up where it started.
function Install-MpvAddon {
    param($Addon, [string]$MpvDir)

    $stamp = Join-Path $MpvDir ('.{0}-version' -f $Addon.Name)
    $have = ''
    if (Test-Path $stamp) { $have = (Get-Content $stamp -Raw).Trim() }

    # -SkipUpgrade means "install what is missing, leave versions alone", so
    # something already present is not even asked about - no API call, no
    # network.
    if ($have -and $SkipUpgrade) {
        Add-Result -Group 'mpv' -Id $Addon.Name -Action 'skipped' -Detail (Format-AddonVersion $have)
        return
    }

    $want = Resolve-MpvAddonVersion -Addon $Addon
    if (-not $want) {
        # Unreachable GitHub is only a failure when there is nothing on disk.
        # With a copy already installed it means "cannot check for newer",
        # which is a current run, not a broken one - the same rule the
        # PowerShell module step uses for an unreachable gallery.
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
                # -Force so an upgrade overwrites the previous version's files
                # rather than erroring on each one.
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
        # The FULL value, not the shortened one - this is what the next run
        # compares against.
        Set-Content -Path $stamp -Value $want -NoNewline
        $action = if ($have) { 'upgraded' } else { 'installed' }
        Add-Result -Group 'mpv' -Id $Addon.Name -Action $action -Detail $change
    } catch {
        Add-Result -Group 'mpv' -Id $Addon.Name -Action 'failed' -Detail $_.Exception.Message
    }
}


# ============================================================
# Manifest
# ============================================================

if (-not (Test-Path $ManifestPath)) { throw "Manifest not found: $ManifestPath" }
$manifest = Import-PowerShellDataFile -Path $ManifestPath

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

$selected = $manifest.Groups
if ($Groups) {
    $known = @($manifest.Groups | ForEach-Object { $_.Name })
    $unknown = @($Groups | Where-Object { $known -notcontains $_ })
    if ($unknown.Count -gt 0) { throw "Unknown group(s): $($unknown -join ', '). Try -ListGroups." }
    $selected = @($manifest.Groups | Where-Object { $Groups -contains $_.Name })
}

# ============================================================
# Preflight
# ============================================================

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

if (-not $elevated) {
    Write-Warning @'
Not running elevated. Machine-scope packages (Steam, Chrome, 7-Zip and
others) will raise a UAC prompt each, and any you dismiss are reported as
failures. For an unattended run, start an admin PowerShell first.
'@
}

# Windows tags every file extracted from a downloaded archive with
# Zone.Identifier=3, and the default LocalMachine policy is RemoteSigned,
# which refuses to run a downloaded script unless it is signed. That breaks the
# release path - the one a fresh machine actually uses - and it breaks it three
# separate times, only the first of which is obvious:
#
#   1. `.\bootstrap.ps1` itself refuses to start, with "is not digitally
#      signed" rather than anything mentioning downloads.
#   2. merge-terminal-settings.ps1, invoked as a second script further down,
#      is still marked even when this file has been unblocked by hand.
#   3. Copy-Item PRESERVES the stream - measured, it does - so a marked
#      profile.ps1 is copied into Documents\PowerShell still marked, and every
#      future session then silently declines to load the profile. Nothing
#      reports that; the shell just opens without it.
#
# Unblocking the whole directory once, here, is cheaper than expecting anyone
# to know all three. Files that carry no mark are left alone.
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
if ($null -ne $installed) {
    Write-Host ('  installed       {0} winget-managed packages' -f $installed.Count) -ForegroundColor DarkGray
}

# Fetched on every run, not only under -WhatIf: it is one call, and it is what
# lets every line say what a package would move TO rather than only where it
# is now. "would-upgrade sharkdp.fd 10.4.2" tells you nothing you did not
# already know; "10.4.2 -> 10.5.0" tells you what you are agreeing to.
Write-Host '  reading available upgrades...' -ForegroundColor DarkGray
$upgradeListing = Get-UpgradeListing

# ============================================================
# Phase 1 - packages
# ============================================================

foreach ($group in $selected) {
    Write-Phase ('{0} - {1}' -f $group.Name, $group.Description)

    foreach ($id in $group.Packages) {
        $version = ''
        if ($null -ne $installed -and $installed.ContainsKey($id)) { $version = $installed[$id] }

        # Pins are checked FIRST, before asking whether the package is even
        # installed, and a pinned package is then left alone entirely.
        #
        # The tempting alternative - "install if missing, never upgrade" - is
        # wrong, and OpenJS.NodeJS is the case that proves it. Node is
        # installed here at 24.14.1 by its own .msi, so winget does not list
        # it as installed at all; under that rule the script would helpfully
        # install 26.x alongside, which is the exact jump the pin exists to
        # prevent. A pin means the version is a decision made by hand, and
        # "install the latest because none is here" is that same decision
        # made by a script.
        $available = Get-AvailableVersion -Id $id -Listing $upgradeListing

        if ($manifest.Pins.ContainsKey($id)) {
            $seen = if ($version) { $version } else { 'not winget-managed' }
            # Show what is being declined, not just that something is. A pin
            # nobody can see the cost of is a pin nobody revisits.
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
        # Preview only - see Get-UpgradeListing for why a real run still asks
        # winget about every package individually.
        if ($WhatIfPreference -and -not (Test-UpgradeListed -Id $id -Listing $upgradeListing)) {
            Add-Result -Group $group.Name -Id $id -Action 'current' -Detail $version
            continue
        }
        Update-Package -Group $group.Name -Id $id -Version $version -Available $available
    }
}

Update-SessionPath

# ============================================================
# Phase 2 - externally managed software
# ============================================================
# Reported, never touched. These are installed and updated by Unity Hub and
# JetBrains Toolbox; winget also publishes ids for some of them, and letting
# it act on those is how two installers end up disagreeing about which
# version is on disk.

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
    # A key whose NAME matches is not proof the software is there. Some
    # installers leave an entirely empty key of the same name in the 64-bit
    # hive while the real entry - DisplayName, DisplayVersion, InstallLocation
    # - lives in WOW6432Node, so a bare name match returns two keys of which
    # one means nothing. The shape is what matters here, not any one program.
    # Requiring a DisplayName is what separates a real registration from a
    # leftover shell.
    $hits = @($uninstallKeys |
            Where-Object { $_.PSChildName -like $m.Detect } |
            ForEach-Object { Get-ItemProperty $_.PSPath -ErrorAction SilentlyContinue } |
            Where-Object { Get-RegValue -Props $_ -Name 'DisplayName' })
    if ($hits.Count -gt 0) {
        # Get-RegValue rather than reading .DisplayVersion straight off the
        # object: StrictMode 'Latest' makes a missing property a TERMINATING
        # error, so the empty key above did not merely produce a blank version,
        # it ended the run. That went unnoticed for as long as Unity and
        # JetBrains were the only entries here - both always carry a
        # DisplayVersion - and surfaced the first time a third kind of
        # software was tried here.
        $versions = @($hits |
                ForEach-Object { Get-RegValue -Props $_ -Name 'DisplayVersion' } |
                Where-Object { $_ } | Sort-Object -Unique) -join ', '
        # Registered but versionless is a real state, and saying so beats
        # printing " (via Unity Hub)" with an empty space where a number
        # should be.
        if (-not $versions) { $versions = 'version not recorded' }
        Add-Result -Group 'managed' -Id $m.Id -Action 'present' -Detail ('{0} (via {1})' -f $versions, $m.By)
    } else {
        Add-Result -Group 'managed' -Id $m.Id -Action 'missing' -Detail ('install it from {0}' -f $m.By)
    }
}

# ============================================================
# Phase 3 - shell
# ============================================================

if ($SkipShell) {
    Write-Phase 'Shell - skipped (-SkipShell)'
} else {
    Write-Phase 'Shell - font, modules, profile, terminal'
    $shell = $manifest.Shell

    # --- Nerd Font ---
    # BOTH font directories, not just the machine one. `oh-my-posh font
    # install` writes to the per-user store when it is not running elevated,
    # and that is usually where the Meslo faces actually live.
    # Checking only %WINDIR%\Fonts reinstalls the font on every single run.
    $fontDirs = @(
        Join-Path $env:WINDIR 'Fonts'
        Join-Path $env:LOCALAPPDATA 'Microsoft\Windows\Fonts'
    )
    $fontPresent = @(
        $fontDirs | Where-Object { Test-Path $_ } | ForEach-Object {
            Get-ChildItem $_ -Filter 'MesloLGM*NerdFont*' -ErrorAction SilentlyContinue
        }
    ).Count -gt 0
    $fontLabel = 'font: {0}' -f $shell.NerdFont
    if ($fontPresent) {
        Add-Result -Group 'shell' -Id $fontLabel -Action 'current'
    } elseif (-not $PSCmdlet.ShouldProcess($shell.NerdFont, 'oh-my-posh font install')) {
        Add-Result -Group 'shell' -Id $fontLabel -Action 'would-install'
    } elseif (Get-Command oh-my-posh -ErrorAction SilentlyContinue) {
        & oh-my-posh font install $shell.NerdFont
        Add-Result -Group 'shell' -Id $fontLabel -Action 'installed'
    } else {
        Add-Result -Group 'shell' -Id $fontLabel -Action 'failed' -Detail 'oh-my-posh not on PATH'
    }

    # --- Oh My Posh themes, copied out of the versioned MSIX directory ---
    # The package folder is renamed on every Oh My Posh update
    # (ohmyposh.cli_<version>_x64__...), so a profile pointing straight at it
    # would break on each upgrade. The profile reads this stable copy instead.
    #
    # Compared before copying, not copied and then declared done. The old code
    # ran Copy-Item -Force unconditionally and reported 'installed' every time,
    # so a run that changed nothing still claimed ~90 theme files as a change -
    # which makes the summary useless for spotting the run that DID change
    # something. Copy-Item carries the source LastWriteTime onto the copy, so
    # name + length + mtime is a faithful "same file" test and costs no hashing.
    $themesDir = Join-Path $env:LOCALAPPDATA $shell.OmpThemesDir
    $pkg = Get-AppxPackage -Name 'ohmyposh.cli' -ErrorAction SilentlyContinue
    if (-not $pkg) {
        Add-Result -Group 'shell' -Id 'oh-my-posh themes' -Action 'failed' -Detail 'ohmyposh.cli appx not found'
    } else {
        $themeSource = @(Get-ChildItem (Join-Path $pkg.InstallLocation 'themes') -File -ErrorAction SilentlyContinue)
        $stale = @($themeSource | Where-Object {
                $dest = Join-Path $themesDir $_.Name
                if (-not (Test-Path $dest)) { return $true }
                $have = Get-Item $dest
                $have.Length -ne $_.Length -or $have.LastWriteTimeUtc -ne $_.LastWriteTimeUtc
            })
        if ($themeSource.Count -eq 0) {
            Add-Result -Group 'shell' -Id 'oh-my-posh themes' -Action 'failed' -Detail 'appx carries no themes directory'
        } elseif ($stale.Count -eq 0) {
            Add-Result -Group 'shell' -Id 'oh-my-posh themes' -Action 'current' -Detail ('{0} themes in {1}' -f $themeSource.Count, $themesDir)
        } elseif (-not $PSCmdlet.ShouldProcess($themesDir, 'sync Oh My Posh themes')) {
            Add-Result -Group 'shell' -Id 'oh-my-posh themes' -Action 'would-install' -Detail ('{0} of {1} themes' -f $stale.Count, $themeSource.Count)
        } else {
            New-Item -ItemType Directory -Path $themesDir -Force | Out-Null
            $stale | Copy-Item -Destination $themesDir -Force
            Add-Result -Group 'shell' -Id 'oh-my-posh themes' -Action 'installed' -Detail ('{0} of {1} themes -> {2}' -f $stale.Count, $themeSource.Count, $themesDir)
        }
    }

    # --- PowerShell modules, once per edition ---
    # PS7 and Windows PowerShell 5.1 do not share a module folder unless PS7 is
    # launched as a child of a 5.1 session. A standalone PS7 tab - which is how
    # Windows Terminal opens one - never sees Documents\WindowsPowerShell\
    # Modules, because only 5.1's own startup adds it to PSModulePath. Each
    # edition needs its own copy.
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
        # Checked per module before anything is installed. `Install-Module
        # -Force` does not mean "make sure it is there", it means "download and
        # write it again regardless" - so the old unconditional pair of calls
        # re-fetched all four modules from the gallery on every single run and
        # then reported 'installed', on a machine where all four were already
        # at the wanted version. Slow, and it drowned the summary in changes
        # that were not changes.
        #
        # The check runs INSIDE the target edition, not here: PS7 and 5.1 have
        # different module paths, so this session's view of what is installed
        # says nothing about the other edition's.
        #
        # PSReadLine carries a floor rather than just "latest wins": 5.1
        # preloads an inbox 2.0.0 before any profile runs, and
        # -SkipPublisherCheck is needed because that inbox copy is signed by a
        # different certificate - without the flag the upgrade is refused
        # rather than merely warned about.
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
        # An unreachable gallery is not a failure when the module is already
        # present and past its floor - it just means "cannot check for newer".
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
        # Handed over as a FILE, never as `-Command <string>`. Windows
        # PowerShell 5.1 wraps a native-command argument in quotes but does not
        # re-escape the double quotes inside it, so every `"` in this script is
        # silently deleted on its way to the child. The child then parses
        # `CURRENT|$name|$($have.Version)` as a pipeline and dies with
        # "Expressions are only allowed as the first element of a pipeline" -
        # ten parse errors describing a script nobody wrote.
        #
        # It only fires when 5.1 is the PARENT, which is the invocation README
        # recommends (`powershell.exe -ExecutionPolicy Bypass -File`); from a
        # PS7 parent the same string arrives intact. The version of this block
        # that shipped before survived by accident, having contained no double
        # quotes at all. -File has no quoting rules to get wrong.
        #
        # -ExecutionPolicy Bypass because the temp file is unsigned; it is
        # created locally so it carries no Mark of the Web, but AllSigned would
        # still refuse it.
        $innerFile = Join-Path ([IO.Path]::GetTempPath()) ('bootstrap-modules-{0}.ps1' -f [guid]::NewGuid())
        Set-Content -LiteralPath $innerFile -Value $inner -Encoding UTF8
        try {
            # $ErrorActionPreference is dropped to Continue for the call
            # itself. `2>&1` turns whatever the child writes to stderr into
            # NativeCommandError records, and at script scope this file runs
            # under 'Stop' - so a child that printed ANYTHING to stderr killed
            # the entire run at this line rather than being reported as a
            # failed step. Nothing is masked: the text is still captured below
            # and still judged.
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
            # No parseable line at all means the child died before the loop -
            # a broken gallery registration, a missing PowerShellGet. Show its
            # own last words rather than inventing a status.
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

    # --- Profile, to both editions' paths ---
    # Anything already there that this script did not write is backed up rather
    # than overwritten. A hand-edited profile is somebody's work. That rule now
    # lives in Deploy-ManagedFile, which the mpv configs use too.
    $profileTargets = @(
        Join-Path $env:USERPROFILE 'Documents\WindowsPowerShell\Microsoft.PowerShell_profile.ps1'
        Join-Path $env:USERPROFILE 'Documents\PowerShell\Microsoft.PowerShell_profile.ps1'
    )
    foreach ($target in $profileTargets) {
        Deploy-ManagedFile -Source $script:ProfileSource -Target $target -Group 'shell' `
            -Label ('profile: ' + (Split-Path (Split-Path $target -Parent) -Leaf))
    }

    # --- Execution policy: without this the profile silently does not load ---
    $policy = [string](Get-ExecutionPolicy -Scope CurrentUser)
    if ($policy -in @('RemoteSigned', 'Unrestricted', 'Bypass')) {
        Add-Result -Group 'shell' -Id 'execution policy' -Action 'current' -Detail $policy
    } elseif ($PSCmdlet.ShouldProcess('CurrentUser', 'Set-ExecutionPolicy RemoteSigned')) {
        # Set-ExecutionPolicy writes a NON-TERMINATING error when it succeeds
        # but a more specific scope still wins - "updated your execution policy
        # successfully, but the setting is overridden by a policy defined at a
        # more specific scope". With $ErrorActionPreference = 'Stop' that
        # promotes to terminating and kills the whole run.
        #
        # Which is not a corner case: it fires whenever the session was started
        # with -ExecutionPolicy Bypass, i.e. exactly what README.md tells you to
        # do with a freshly downloaded copy. 1.0.3 died right here, after doing
        # the work, and never printed a summary.
        #
        # So swallow the message and judge by the result instead - re-read the
        # CurrentUser scope, which is the only thing this step is trying to
        # change. A Process-scope override is expected and harmless: it lasts
        # as long as the window.
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

    # --- Windows Terminal settings ---
    # A copy would overwrite the whole settings.json and destroy every
    # customisation in it; the merge script touches only the font default and
    # one profile entry. See merge-terminal-settings.ps1.
    if ($PSCmdlet.ShouldProcess('Windows Terminal settings.json', 'merge font + PowerShell 7 profile')) {
        $out = (& $script:MergeScript -FontFace $shell.TerminalFontFace -Pwsh7Guid $shell.TerminalPwshGuid | Out-String).Trim()
        $action = if ($out -match 'CHANGED') { 'installed' } elseif ($out -match 'SKIPPED') { 'skipped' } else { 'current' }
        Add-Result -Group 'shell' -Id 'windows terminal' -Action $action -Detail $out
    } else {
        Add-Result -Group 'shell' -Id 'windows terminal' -Action 'would-install'
    }
}

# ============================================================
# Phase 4 - mpv
# ============================================================
# The package is installed with everything else in the apps group; this is the
# part that makes it worth having - a real UI instead of mpv's minimal default
# controller, seek-bar thumbnails, and a config tuned for playing files that
# arrive over the network rather than off local disk.

$mpvExe = if ($SkipMpv) { $null } else { Resolve-MpvExe }

if ($SkipMpv) {
    Write-Phase 'mpv - skipped (-SkipMpv)'
} elseif (-not $mpvExe) {
    # Reported rather than assumed: if the package failed to install above,
    # writing a config and 8MB of scripts for a player that is not there is
    # noise, not progress.
    Write-Phase 'mpv - not installed, skipping config'
    Add-Result -Group 'mpv' -Id 'mpv' -Action 'missing' -Detail 'shinchiro.mpv not found on PATH, in the uninstall registry, or under Program Files'
} else {
    Write-Phase 'mpv - config, UI and scripts'
    # Where it was found, every run. The phase used to be skipped silently on
    # some machines, and a line naming the exe is how that stays visible.
    Add-Result -Group 'mpv' -Id 'mpv' -Action 'present' -Detail $mpvExe
    $mpv = $manifest.Mpv
    $mpvDir = Join-Path $env:APPDATA 'mpv'

    # mpv's installer adds nothing to PATH - that is the whole reason
    # Resolve-MpvExe exists - so `mpv file.mkv` from a prompt does not work
    # until something puts it there. Opt out with AddToPath = $false.
    if ($mpv.Contains('AddToPath') -and $mpv.AddToPath) {
        Add-UserPathEntry -Directory (Split-Path $mpvExe -Parent) -Group 'mpv' -Label 'mpv on PATH'
    }

    # script-opts\autoload.conf is a nested path on purpose - mpv looks for
    # script configuration in %APPDATA%\mpv\script-opts\<script>.conf and
    # nowhere else. Deploy-ManagedFile creates the parent directory, so the
    # subdirectory needs no special handling here.
    foreach ($name in @('mpv.conf', 'input.conf', 'script-opts\autoload.conf')) {
        Deploy-ManagedFile -Source (Join-Path $script:MpvSource $name) `
            -Target (Join-Path $mpvDir $name) -Label $name -Group 'mpv'
    }

    # Windows PowerShell 5.1 still defaults to TLS 1.0/1.1 for
    # Invoke-WebRequest, and GitHub refuses both - the download fails with a
    # connection error that says nothing about TLS. Harmless to set in 7.
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

    # One loop, four add-ons, no per-add-on code. Everything that differs
    # between them - where to ask for a version, what to download, where it
    # goes - is data in packages.psd1 now, which is what let the pinning
    # question be answered in the manifest rather than in four near-identical
    # blocks here.
    foreach ($addon in $mpv.Addons) {
        Install-MpvAddon -Addon $addon -MpvDir $mpvDir
    }
}


# ============================================================
# Summary
# ============================================================

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
if ($failed.Count -gt 0) { exit 1 }
