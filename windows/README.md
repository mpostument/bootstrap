# bootstrap.ps1

Installs and updates a Windows machine's software from a manifest. One command
does both.

```powershell
.\bootstrap.ps1 -WhatIf     # show what would change, touch nothing
.\bootstrap.ps1             # do it
```

Run it from an **admin** PowerShell — machine-scope installers raise a UAC
prompt otherwise, and any dismissed prompt is reported as a failure.

## First run from a download

```powershell
Expand-Archive .\bootstrap-windows-v*.zip -DestinationPath .
cd .\bootstrap-windows-v*
Get-ChildItem -Recurse | Unblock-File     # required
.\bootstrap.ps1 -WhatIf
.\bootstrap.ps1
```

Without `Unblock-File`, `RemoteSigned` refuses the downloaded script with "is
not digitally signed". `powershell.exe -ExecutionPolicy Bypass -File
.\bootstrap.ps1` also works. The script clears the mark from its own directory
once running, but cannot clear it from the file you are starting.

## What it does

1. **Packages** — installs or upgrades everything in `packages.psd1` via winget.
2. **Externally managed software** — detects and reports, changes nothing.
3. **Shell** — Nerd Font from GitHub, `starship.toml` from the repo root,
   PowerShell modules for 5.1 and 7, the profile, execution policy, and a
   Windows Terminal settings merge that patches keys instead of overwriting.
4. **mpv** — config, UI and scripts. Skip with `-SkipMpv`.
5. **Schedule** — a daily unattended run. Skip with `-SkipSchedule`.

## mpv

Deployed into `%APPDATA%\mpv\`:

| | |
|---|---|
| `mpv.conf` | `gpu-next` on `d3d11`, `profile=high-quality`, `hwdec=auto-safe`, large cache for network shares. |
| `input.conf` | Bindings, plus the uosc menu on right-click. |
| `script-opts/autoload.conf` | Which file types join a playlist. |
| **uosc** | A real UI: menus, timeline, window controls. |
| **thumbfast** | Hover-preview thumbnails on the seek bar. |
| **autoload** | Opening one file queues the rest of the directory. |
| **memo** | Recently-played menu, on `h`. |
| **chapterskip** | `Ctrl+s` skips to the next silence. |
| **auto-save-state** | Periodically re-saves the resume position. |

The add-ons are unpinned but versioned: every run asks GitHub for the newest
release tag or commit, compares it to a stamp file, and downloads only on a
difference. If GitHub is unreachable, an installed add-on reports `current`
rather than failing the run.

mpv's installer adds nothing to `PATH`, so this phase appends the player's
directory to your **user** `PATH`. Set `AddToPath = $false` in the manifest's
`Mpv` section to leave it alone. If mpv is not installed, the phase reports
`missing` and skips.

## The manifest

`packages.psd1` sorts software by who owns it:

| | installed if missing | upgraded on re-run |
|---|---|---|
| `Groups` | yes | yes |
| `Pins` | no | no |
| `Managed` | no | no |

**`Groups`** — ordinary winget software: `shell`, `cli`, `dev`, `cloud`,
`creative`, `apps`.

**`Pins`** — hands-off in both directions. Prefer a release channel that
encodes the rule (`OpenJS.NodeJS.LTS`) over a pin. Every pin carries a written
reason.

**`Managed`** — software another installer owns (Unity editors, Rider, Android
Studio). Found through their registry uninstall keys and only reported.

## Adding a package

```powershell
winget search "<name>"      # find the exact id
```

Put the id in a group in `packages.psd1` and re-run.

## Options

```powershell
.\bootstrap.ps1 -ListGroups              # what groups exist
.\bootstrap.ps1 -ListPackages            # every package id, by group
.\bootstrap.ps1 -Groups cli,dev          # only those groups
.\bootstrap.ps1 -SkipUpgrade             # install missing, freeze versions
.\bootstrap.ps1 -SkipShell               # packages only
.\bootstrap.ps1 -SkipMpv                 # leave %APPDATA%\mpv alone
.\bootstrap.ps1 -Silent                  # suppress installer UI
.\bootstrap.ps1 -ShowVersion
```

`-WhatIf` and `-Confirm` work throughout. `tools` is a function the shell phase
writes next to your profile: the `cli` group as of the last run.

## What it deliberately does not do

- **Enable Windows optional features.** WSL needs a reboot; run `wsl --install`
  once yourself, and the manifest keeps it updated after that.
- **Install Unity editors, Rider or Android Studio.** Their own installers own them.
- **Pass `--include-unknown` to winget** by default — available as `-IncludeUnknown`.
- **Overwrite a profile it did not write.** One without the
  `managed by windows/bootstrap.ps1` marker is copied to `.bak` first.

## Files

| File | Purpose |
|---|---|
| `bootstrap.ps1` | Entry point; holds the version. |
| `packages.psd1` | The manifest. |
| `profile.ps1` | PowerShell profile, deployed to both the 5.1 and 7 paths. |
| `merge-terminal-settings.ps1` | Patches Windows Terminal's `settings.json`. |
| `mpv/` | mpv configuration, deployed to `%APPDATA%\mpv\`. |
| `CHANGELOG.md` | Per-version history. |

## Releasing

All three platforms ship in one GitHub release; the tag names the bundle and
each platform keeps its own number. This one's version is
`$script:BootstrapVersion` in `bootstrap.ps1`.

```sh
# 1. bump the version in whichever platform(s) changed
# 2. add the matching section to that platform's CHANGELOG.md
# 3. commit, then:
git tag v2026.02 && git push origin v2026.02
```

`.github/workflows/release.yml` refuses to publish if any platform's current
version has no changelog section, if any `.ps1` fails to parse or trips the
shadowed-variable check, or if either shell script fails `bash -n` or
shellcheck.
