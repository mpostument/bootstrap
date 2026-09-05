<#
.SYNOPSIS
    Idempotently patches Windows Terminal's settings.json with the Nerd Font
    default and a PowerShell 7 profile entry, without clobbering anything
    else the user has configured.

    A plain copy would overwrite the whole file; this only touches the two
    keys bootstrap.ps1 cares about. Prints CHANGED, OK or SKIPPED on the last
    line so bootstrap.ps1 can report which of the three it was.
#>
param(
    [string]$FontFace = "MesloLGM Nerd Font Mono",
    [string]$Pwsh7Guid = "{574e775e-4f2a-5b96-ac1e-a2962a402336}"
)

$settingsFile = Get-ChildItem "$env:LOCALAPPDATA\Packages\Microsoft.WindowsTerminal_*\LocalState\settings.json" -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $settingsFile) {
    Write-Output "SKIPPED: Windows Terminal not installed"
    exit 0
}

$json = Get-Content $settingsFile.FullName -Raw | ConvertFrom-Json
$changed = $false

if (-not (Get-Member -InputObject $json.profiles -Name "defaults")) {
    $json.profiles | Add-Member -NotePropertyName defaults -NotePropertyValue ([PSCustomObject]@{})
}
if (-not (Get-Member -InputObject $json.profiles.defaults -Name "font") -or $json.profiles.defaults.font.face -ne $FontFace) {
    $json.profiles.defaults | Add-Member -NotePropertyName font -NotePropertyValue ([PSCustomObject]@{ face = $FontFace }) -Force
    $changed = $true
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
