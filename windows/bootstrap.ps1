#Requires -Version 5.1
<#
.SYNOPSIS
    Installs and updates this Windows machine's software from packages.psd1.
.PARAMETER Groups
    Limit to named groups, e.g. -Groups shell,cli. Default is every group.
.PARAMETER SkipUpgrade
    Install what is missing, leave installed versions alone.
.PARAMETER SkipShell
    Skip the shell phase: Nerd Font, modules, profile, Windows Terminal.
.PARAMETER SkipMpv
    Skip the mpv phase.
.PARAMETER SkipSchedule
    Skip the schedule phase and leave Task Scheduler alone.
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
    [switch]$SkipShell,
    [switch]$SkipMpv,
    [switch]$SkipSchedule,
    [switch]$IncludeUnknown,
    [switch]$Silent,
    [switch]$ListGroups,
    [switch]$ListPackages,
    [switch]$ShowVersion,
    [string]$ManifestPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:BootstrapVersion = '1.28.0'

if ($ShowVersion) {
    Write-Output $script:BootstrapVersion
    return
}

$script:ToolRoot = $PSScriptRoot
if (-not $script:ToolRoot) { $script:ToolRoot = Split-Path -Parent $MyInvocation.MyCommand.Path }

$script:ProfileSource = Join-Path $script:ToolRoot 'profile.ps1'
$script:StarshipTomlSource = Join-Path (Split-Path $script:ToolRoot -Parent) 'starship.toml'
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

# Environment

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
    $lines.Add('function tools {')
    $lines.Add('    Write-Host ""')
    if ($cliGroup) {
        foreach ($p in $cliGroup.Packages) {
            $text = $p
            if ($cliIndex.ContainsKey($p)) {
                $info = $cliIndex[$p]
                $text = '{0,-26} {1,-42} {2}' -f $p, $info.Cmd, $info.Desc
            }
            $lines.Add("    Write-Host '  $($text.Replace("'", "''"))' -ForegroundColor DarkGray")
        }
    }
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

# Manifest

if (-not (Test-Path $ManifestPath)) { throw "Manifest not found: $ManifestPath" }
$manifest = Import-PowerShellDataFile -Path $ManifestPath

$required = @('Groups', 'Pins', 'Managed', 'Shell', 'Mpv', 'Schedule', 'Git')
$missing = @($required | Where-Object { -not $manifest.Contains($_) })
if ($missing.Count -gt 0) {
    throw ("Manifest is missing required section(s): {0}. Found: {1}. See {2}." -f
        ($missing -join ', '), (@($manifest.Keys) -join ', '), $ManifestPath)
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
if ($null -ne $installed) {
    Write-Host ('  installed       {0} winget-managed packages' -f $installed.Count) -ForegroundColor DarkGray
}

Write-Host '  reading available upgrades...' -ForegroundColor DarkGray
$upgradeListing = Get-UpgradeListing

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

# Phase 2 - externally managed software

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

# Phase 3 - shell

if ($SkipShell) {
    Write-Phase 'Shell - skipped (-SkipShell)'
} else {
    Write-Phase 'Shell - font, modules, profile, terminal'
    $shell = $manifest.Shell

    Install-NerdFont -Name $shell.NerdFont -Repo 'ryanoasis/nerd-fonts' -Match 'MesloLGMNerdFont'

    Deploy-ManagedFile -Source $script:StarshipTomlSource `
        -Target (Join-Path $env:USERPROFILE '.config\starship.toml') `
        -Group 'shell' -Label 'starship.toml'

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

    if ($PSCmdlet.ShouldProcess('Windows Terminal settings.json', 'merge font, size, scheme, padding, copyOnSelect, scrollback, PowerShell 7 profile')) {
        $mergeArgs = @{
            FontFace        = $shell.TerminalFontFace
            FontSize        = $shell.TerminalFontSize
            ColorScheme     = $shell.TerminalColorScheme
            ColorSchemeDef  = $shell.TerminalColorSchemeDef
            CopyOnSelect    = $shell.TerminalCopyOnSelect
            Padding         = $shell.TerminalPadding
            HistorySize     = $shell.TerminalHistorySize
            Pwsh7Guid       = $shell.TerminalPwshGuid
        }
        $out = (& $script:MergeScript @mergeArgs | Out-String).Trim()
        $action = if ($out -match 'CHANGED') { 'installed' } elseif ($out -match 'SKIPPED') { 'skipped' } else { 'current' }
        Add-Result -Group 'shell' -Id 'windows terminal' -Action $action -Detail $out
    } else {
        Add-Result -Group 'shell' -Id 'windows terminal' -Action 'would-install'
    }
}

# Phase 4 - mpv

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

# Phase 5 - schedule

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
# Git - LFS and Unity's merge tool

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
                    & git config --global 'mergetool.unityyamlmerge.cmd' $want
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
if ($failed.Count -gt 0) { exit 1 }
