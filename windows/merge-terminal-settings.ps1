<#
.SYNOPSIS
    Patches Windows Terminal settings.json with the keys the manifest
    owns, leaving everything else in the file alone.
#>
param(
    [string]$FontFace = "MesloLGM Nerd Font Mono",
    [int]$FontSize = 16,
    [string]$ColorScheme = "Catppuccin Mocha",
    [hashtable]$ColorSchemeDef,
    [bool]$CopyOnSelect = $true,
    [string]$Padding = "10, 10",
    [int]$HistorySize = 100000,
    [string]$Pwsh7Guid = "{574e775e-4f2a-5b96-ac1e-a2962a402336}"
)

$settingsFile = Get-ChildItem "$env:LOCALAPPDATA\Packages\Microsoft.WindowsTerminal_*\LocalState\settings.json" -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $settingsFile) {
    Write-Output "SKIPPED: Windows Terminal not installed"
    exit 0
}

$json = Get-Content $settingsFile.FullName -Raw | ConvertFrom-Json
$changed = $false

function Set-JsonProperty {
    param($Object, [string]$Name, $Value)
    $existing = $Object.PSObject.Properties[$Name]
    if ($null -eq $existing) {
        $Object | Add-Member -NotePropertyName $Name -NotePropertyValue $Value
        return $true
    }
    if ($Value -is [PSCustomObject] -or $Value -is [hashtable]) {
        $before = ($existing.Value | ConvertTo-Json -Depth 10 -Compress)
        $after  = ($Value | ConvertTo-Json -Depth 10 -Compress)
        if ($before -ne $after) { $existing.Value = $Value; return $true }
    } elseif ($existing.Value -ne $Value) {
        $existing.Value = $Value
        return $true
    }
    return $false
}

if (-not (Get-Member -InputObject $json.profiles -Name "defaults")) {
    $json.profiles | Add-Member -NotePropertyName defaults -NotePropertyValue ([PSCustomObject]@{})
}
$defaults = $json.profiles.defaults

if (-not (Get-Member -InputObject $defaults -Name "font")) {
    $defaults | Add-Member -NotePropertyName font -NotePropertyValue ([PSCustomObject]@{})
}
if (Set-JsonProperty $defaults.font 'face' $FontFace) { $changed = $true }
if (Set-JsonProperty $defaults.font 'size' $FontSize) { $changed = $true }

if (Set-JsonProperty $defaults 'colorScheme' $ColorScheme) { $changed = $true }
if (Set-JsonProperty $defaults 'padding'     $Padding)     { $changed = $true }
if (Set-JsonProperty $defaults 'historySize' $HistorySize) { $changed = $true }

if (Set-JsonProperty $json 'copyOnSelect' $CopyOnSelect) { $changed = $true }

if ($ColorSchemeDef -and $ColorSchemeDef.name) {
    if (-not (Get-Member -InputObject $json -Name 'schemes')) {
        $json | Add-Member -NotePropertyName schemes -NotePropertyValue @()
    }
    $existing = $json.schemes | Where-Object { $_.name -eq $ColorSchemeDef.name }
    if (-not $existing) {
        $schemeObj = [PSCustomObject]$ColorSchemeDef
        $json.schemes = @($json.schemes) + $schemeObj
        $changed = $true
    }
}

if (-not ($json.profiles.list | Where-Object { $_.guid -eq $Pwsh7Guid })) {
    $json.profiles.list = @($json.profiles.list) + [PSCustomObject]@{
        commandline = "pwsh.exe"
        guid        = $Pwsh7Guid
        hidden      = $false
        name        = "PowerShell 7"
    }
    $changed = $true
}

if ($changed) {
    ($json | ConvertTo-Json -Depth 10) | Set-Content $settingsFile.FullName -Encoding utf8
    Write-Output "CHANGED"
} else {
    Write-Output "OK"
}
