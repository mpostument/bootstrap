<#
.SYNOPSIS
    Idempotently patches Windows Terminal's settings.json with the knobs the
    manifest exposes, without clobbering anything else the user has
    configured.

    A plain copy would overwrite the whole file; this only touches keys the
    merge script owns:

      profiles.defaults.font.face
      profiles.defaults.font.size
      profiles.defaults.colorScheme
      profiles.defaults.padding
      profiles.defaults.historySize
      profiles.list[]      (adds the PowerShell 7 entry if the fixed GUID is
                            not already present)
      schemes[]            (adds a named scheme if that name is not already
                            defined - NEVER overwrites one somebody has
                            hand-edited under the same name)
      copyOnSelect         (top-level)

    Prints CHANGED, OK or SKIPPED on the last line so bootstrap.ps1 can
    report which of the three it was.
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

# Helper: set a property on a PSCustomObject to a target value, creating it
# if missing. Returns $true when the property was added or changed. Written
# out here because Add-Member -Force silently rebuilds the property even when
# the value is identical, which would report CHANGED on every run.
function Set-JsonProperty {
    param($Object, [string]$Name, $Value)
    $existing = $Object.PSObject.Properties[$Name]
    if ($null -eq $existing) {
        $Object | Add-Member -NotePropertyName $Name -NotePropertyValue $Value
        return $true
    }
    # -ne on PSCustomObjects compares by reference, so hashtable-like values
    # go through ConvertTo-Json for a structural compare. Scalar values fall
    # through to the plain -ne, which is what we want.
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

# --- profiles.defaults ------------------------------------------------------
if (-not (Get-Member -InputObject $json.profiles -Name "defaults")) {
    $json.profiles | Add-Member -NotePropertyName defaults -NotePropertyValue ([PSCustomObject]@{})
}
$defaults = $json.profiles.defaults

# font is a nested object, so it gets its own create-and-set path.
if (-not (Get-Member -InputObject $defaults -Name "font")) {
    $defaults | Add-Member -NotePropertyName font -NotePropertyValue ([PSCustomObject]@{})
}
if (Set-JsonProperty $defaults.font 'face' $FontFace) { $changed = $true }
if (Set-JsonProperty $defaults.font 'size' $FontSize) { $changed = $true }

if (Set-JsonProperty $defaults 'colorScheme' $ColorScheme) { $changed = $true }
if (Set-JsonProperty $defaults 'padding'     $Padding)     { $changed = $true }
if (Set-JsonProperty $defaults 'historySize' $HistorySize) { $changed = $true }

# --- copyOnSelect (top-level) -----------------------------------------------
if (Set-JsonProperty $json 'copyOnSelect' $CopyOnSelect) { $changed = $true }

# --- schemes[] --------------------------------------------------------------
# Add the named scheme if it is not already defined. NEVER overwrite one that
# is: somebody may have hand-tuned Catppuccin Mocha, and stomping on that on
# every run is exactly the kind of thing the "merge, do not replace" split
# exists to avoid. The merge is name-keyed on ADD.
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

# --- profiles.list[] --------------------------------------------------------
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
