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
2. **Python tools** — each group's `UvTools` entries, through `uv tool`: one
   environment per tool, for the CLIs winget has no package for.
3. **Housekeeping** — prunes the installers winget downloaded and left in the
   temp cache. Skip with `-SkipCleanup`.
4. **Externally managed software** — detects and reports, changes nothing.
5. **Shell** — Nerd Font from GitHub, `starship.toml` and the bat config and
   Catppuccin Mocha theme from the repo root,
   PowerShell modules for 5.1 and 7, the profile, execution policy, and a
   Windows Terminal settings merge that patches keys instead of overwriting.
6. **mpv** — config, UI and scripts. Skip with `-SkipMpv`.
7. **Schedule** — a daily unattended run. Skip with `-SkipSchedule`.
8. **VS Code extensions** — installs what's missing from `packages.psd1`,
   never removes one that isn't listed. Skip with `-SkipVsCode`.

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
| `Groups[].UvTools` | yes, `uv tool install` | yes, `uv tool upgrade` |
| `Pins` | no | no |
| `Managed` | no | no |

**`Groups`** — ordinary winget software: `shell`, `cli`, `dev`, `infra`,
`cloud`, `network`, `creative`, `apps`.

**`Groups[].UvTools`** — Python CLIs with no usable winget package, each in its
own environment through `uv tool`, the same shape as `GROUP_*_UV` in
`linux/packages.conf`. An entry is `name` or `name|extra arguments`.

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
.\bootstrap.ps1 -Status                  # what did the last run do
.\bootstrap.ps1 -History                 # the last runs, and what each moved
.\bootstrap.ps1 -Doctor                  # is any of it actually in effect
.\bootstrap.ps1 -SkipUpgrade             # install missing, freeze versions
.\bootstrap.ps1 -SkipCleanup             # leave winget's download cache alone
.\bootstrap.ps1 -SkipShell               # packages only
.\bootstrap.ps1 -SkipMpv                 # leave %APPDATA%\mpv alone
.\bootstrap.ps1 -Silent                  # suppress installer UI
.\bootstrap.ps1 -SkipUpdateCheck         # don't check GitHub for a newer release
.\bootstrap.ps1 -ShowVersion
```

`-WhatIf` and `-Confirm` work throughout. `tools` is a function the shell phase
writes next to your profile: the `cli` group as of the last run.

## Did last night's run work?

The task runs at 04:20 and tees into `%LOCALAPPDATA%\windows-bootstrap\logs`,
which is to say nobody reads it. Every real run now leaves a record in
`%LOCALAPPDATA%\windows-bootstrap\last-run` — when, how long, the exit code,
the counts, the id of every step that failed, and the message it died with if
it threw. `-Status` reads it back and exits 1 if that run failed, so it works
as a check:

```powershell
.\bootstrap.ps1 -Status

== Last run ====================================================
  when            2026-09-17 04:21:12  (7h 30m ago)
  trigger         unattended - the scheduled task, or output redirected
  version         v1.40.0
  duration        3m 07s
  result          exit 1
  failed          Microsoft.DotNet.SDK.10, log pruning
  counts          installed=1 upgraded=9 current=54 present=6
  log             C:\Users\you\AppData\Local\windows-bootstrap\logs\bootstrap-2026-09-17.log
  record          C:\Users\you\AppData\Local\windows-bootstrap\last-run
```

The record is written from the Summary *and* from a script-level `trap`, so a
run that throws in phase 1 records that rather than leaving yesterday's success
looking current. `-WhatIf` never writes it.

`Schedule.NotifyOnFailure` sends one notification when an unattended run fails.
There is no channel that exists on every Windows, so three are tried in order:
a BurntToast toast if that module happens to be installed, the Application
event log otherwise, and `msg.exe` last — Home editions have none of the first
two. An interactive run is never notified; it printed the failures in red.

Interactive is decided by whether stdout is redirected, the same test the Linux
and macOS scripts make with `[ -t 1 ]`. The scheduled task pipes through
`Tee-Object`, so it always reads as unattended.

## Is it actually in effect?

Every phase here asserts that a package is *installed*. `-Doctor` asserts that
it is in **effect**, which is not the same thing and is where this changelog's
bugs live: `%USERPROFILE%\go\bin` missing from `PATH`, the mise shims missing
from `PATH`, `JAVA_HOME` unset, a profile deployed but never loaded.

The questions are asked of a shell with **your profile loaded** — one probe,
no `-NoProfile`, because the profile is the thing under test. It reports what
each tool resolves to and whether more than one copy is on `PATH`, whether the
prompt function came from starship, what `node`, `go` and `java` resolve to,
whether the deployed config still matches the repo, and whether the scheduled
task exists and is enabled.

PSReadLine is the exception: it only loads in an interactive console host, so a
probe shell cannot see it. That check is that the module is installed and that
the profile configures it — stated as such rather than pretended.

```powershell
.\bootstrap.ps1 -Doctor

== Doctor - the cli group on PATH ==============================
  ok            rg                      C:\Users\you\AppData\Local\Microsoft\WinGet\Links\rg.exe
  present       fd                      C:\...\fd.exe - and 2 copies on PATH
== Doctor - shell integration ==================================
  ok            starship prompt         the prompt function comes from starship
  broken        profile: PowerShell     not deployed at C:\Users\you\Documents\PowerShell\...
```

`ok` is in effect, `broken` is not, and `present` is a judgement call left to
you — two copies of a command on `PATH` is how a stale one wins for months, but
which one you want is not this script's decision. It changes nothing and exits
1 if anything is broken.

7-Zip is deliberately not checked: winget's package does not put `7z` on `PATH`
at all, which `tools/cli-parity.conf` has said in its note for as long as it
has listed it.

## What moved

`-Status` answers "did last night's run work". `-History` answers "and what did
it change":

```powershell
.\bootstrap.ps1 -History -HistoryLines 3

== History =====================================================
  when              took     result   i/u/f   what moved
  2026-09-15 04:20* 3m 07s   ok       1/9/0   Microsoft.PowerShell 7.4.6>7.5.0, +JesseDuffield.lazygit 0.44
  2026-09-16 04:20* 4m 12s   exit 1   0/3/2   Starship.Starship 1.25.1>1.26.0
  2026-09-17 09:11  41s      ok       0/0/0
  3 run(s), * = unattended
```

The versions come from the `winget export` phase 1 already takes, compared with
a second one after it — what actually moved, rather than what scrolled past.
One line per run, oldest first, capped at 200 lines.

## Housekeeping

winget upgrades in place, so unlike Homebrew there is no superseded version to
remove. What accumulates is the installer it downloaded in order to run the
upgrade: those stay in `%TEMP%\WinGet` indefinitely, and on a machine the task
upgrades nightly that is every installer of every package. `Housekeeping.PruneDays`
sets the age past which one goes; `Housekeeping.Enabled = $false` turns the
phase off and `-SkipCleanup` skips it for a run.

Nothing is uninstalled, and winget's own state under
`Microsoft.DesktopAppInstaller` is reported with its size and left alone — that
is state, not a download it can fetch again. A file the installer still holds
open is skipped and picked up by the next run.

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

Preflight checks this checkout's own GitHub origin for a newer release tag and
prints one line if it's behind - separate from `$script:BootstrapVersion`
above, which is this script's own number. Silent on a release zip, a fork, or
no network. `-SkipUpdateCheck` opts out.

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
