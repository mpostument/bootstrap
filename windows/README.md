# bootstrap.ps1

Installs and updates a Windows machine's software from a manifest.

One command does both jobs. On a fresh machine it installs everything; on a
machine that already has it, it takes the updates. The script works out per
package which one it is doing.

```powershell
.\bootstrap.ps1 -WhatIf     # show what would change, touch nothing
.\bootstrap.ps1             # do it
```

Run it from an **admin** PowerShell. Machine-scope installers (Steam, Chrome,
7-Zip) each raise a UAC prompt otherwise, and any you dismiss are reported as
failures.

## First run from a download

```powershell
Expand-Archive .\bootstrap-windows-v*.zip -DestinationPath .
cd .\bootstrap-windows-v*

# Required. See below.
Get-ChildItem -Recurse | Unblock-File

.\bootstrap.ps1 -WhatIf
.\bootstrap.ps1
```

Windows marks every file extracted from a downloaded archive as internet
content, and the default `RemoteSigned` policy refuses to run a marked script
unless it is signed. Skip the `Unblock-File` and you get this, which never
mentions downloading and so sends most people to the wrong fix:

```text
.\bootstrap.ps1 cannot be loaded. The file ... is not digitally signed.
```

`powershell.exe -ExecutionPolicy Bypass -File .\bootstrap.ps1` also gets past
it. From 1.0.1 the script clears the mark from everything in its own directory
once it is running — but it cannot clear the mark from the file you are trying
to start, so the first command still needs one of those two.

## What it does

1. **Packages** — installs or upgrades everything in `packages.psd1` via winget.
2. **Externally managed software** — detects it and reports, changes nothing.
3. **Shell** — Nerd Font, Oh My Posh themes, PowerShell modules for both 5.1
   and 7, the profile, execution policy, and a Windows Terminal settings merge
   that patches two keys instead of overwriting the file.
4. **mpv** — the player's config, UI and scripts. Skip with `-SkipMpv`.
5. **Schedule** — a daily unattended run, so updates arrive without anyone
   remembering to ask. Skip with `-SkipSchedule`.

## mpv

The winget package is just the player. This deploys the part that makes it
worth using, into `%APPDATA%\mpv\`:

| | |
|---|---|
| `mpv.conf` | `gpu-next` on `d3d11`, `profile=high-quality`, `hwdec=auto-safe`, and a deliberately large cache, tuned for playing over a network share where a stall is a network problem and reading further ahead is the only defence. |
| `input.conf` | Sane bindings, plus the uosc menu on right-click. |
| `script-opts/autoload.conf` | Tunes autoload — which file types join a playlist, and what to leave out. |
| **uosc** | Replaces mpv's minimal built-in controller with a real UI — menus, a proper timeline, window controls. |
| **thumbfast** | Hover-preview thumbnails on the seek bar. uosc uses it automatically when present. |
| **autoload** | Opening one file queues the rest of the directory. Without it the uosc playlist menu is always empty, because nothing else ever builds a playlist. |
| **memo** | A recently-played menu, on `h` and in the uosc menu under Navigation. |
| **chapterskip** | `Ctrl+s` fast-forwards to the next silence — where an opening usually ends. Never automatic. |
| **auto-save-state** | Re-saves the resume position periodically, so a crash does not lose it. |

mpv's own installer puts `mpv.exe` under Program Files and adds nothing to
`PATH`, so `mpv file.mkv` from a prompt does not work out of the box. The mpv
phase appends the directory it actually found the player in to your **user**
`PATH` — never the machine one, which would need elevation and is not this
tool's to edit. Set `AddToPath = $false` in the manifest's `Mpv` section to
leave `PATH` alone.

All four are downloaded from GitHub and **deliberately unpinned**, the same call
worth stating: this is desktop config on a machine you use interactively, not
infrastructure where a surprise version means an outage. Staying current wins
over reproducibility.

Unpinned is not unversioned. Every run asks GitHub what the newest version is —
the latest release tag for uosc, the latest commit for the three that publish
neither releases nor tags — writes that exact value to a stamp file in
`%APPDATA%\mpv\`, and downloads only when it differs. So a run that finds
nothing new transfers nothing, and the summary reports a real
`0f711de -> a3c91b2` instead of a shrug. `autoload`'s commit lookup is narrowed
to `TOOLS/lua/autoload.lua`, or it would track every commit to mpv itself.

If GitHub cannot be reached, an add-on that is already installed reports
`current` with `(could not reach GitHub to check for newer)` rather than
failing the run — the same rule the module step uses for an unreachable
gallery. `-SkipUpgrade` skips the lookup entirely for anything already present.

The configs follow the same rule as the PowerShell profile: replaced freely if
this script wrote them, copied to `.bak` first if you did. A re-run that finds
the pinned versions already in place does nothing and says `current`.

mpv's installer needs elevation, so on an unelevated run the package install
raises a UAC prompt. If it is not installed, this phase reports `missing` and
skips rather than writing config for a player that is not there.

## The manifest

`packages.psd1` sorts software by **who owns it**, which is the distinction
that matters when an update goes wrong.

| | installed if missing | upgraded on re-run |
|---|---|---|
| `Groups` | yes | yes |
| `Pins` | no | no |
| `Managed` | no | no |

**`Groups`** is ordinary winget software, in five groups: `shell`, `cli`,
`dev`, `creative`, `apps`.

**`Pins`** are hands-off in both directions — not upgraded, and not installed
either. A pin means the version is a decision you make by hand, and installing
the latest because none is present is that same decision made by a script.

`Pins` is currently empty, and Node is why. It was pinned because a
hand-installed 24.x lived outside winget; when that copy was later
uninstalled, the pin went on refusing to install Node **and** went on
reporting a 24.x that no longer existed. A pin cannot notice the world moved.
So Node is now `OpenJS.NodeJS.LTS` instead, where the release channel enforces
the same rule upstream: LTS never ships a major bump mid-line, but patch and
minor releases still arrive on a normal run. Reach for a channel first, and pin
only when no id encodes the rule you want.

**`Managed`** is software another installer owns — Unity editors belong to
Unity Hub, Rider and Android Studio to JetBrains Toolbox. winget publishes ids
for some of them, and letting it act on those is how two installers end up
disagreeing about what is on disk. These are found through their registry
uninstall keys and only reported.

Report-only means both directions: nothing here is ever installed or upgraded.
That is the point for software with a real owner, and it is also why software
that is merely absent from winget does not belong here — an entry that can only
print a version it will never change is inventory, not configuration.

Every pin carries a written reason. A pin nobody can explain later is a pin
nobody dares remove.

## Adding a package

```powershell
winget search "<name>"      # find the exact id
```

Put the id in a group in `packages.psd1` and re-run. The script needs no
changes to pick it up. To stop a package moving, add it to `Pins` with a
reason.

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

`-WhatIf` and `-Confirm` work throughout.

For a quick check from any prompt without touching the repo, type `tools` -
a function the shell phase writes next to your PowerShell profile on every
run, listing every package as of the last run. `-ListPackages` above is the
live version, read straight from `packages.psd1`.

## What it deliberately does not do

- **Enable Windows optional features.** `Microsoft.WSL` and `Canonical.Ubuntu`
  put WSL and a distro on disk, but Virtual Machine Platform and the distro's
  first-launch user creation are not automated — that path needs a reboot, and
  a script that reboots your machine as a side effect of "check for updates" is
  a bad script. Run `wsl --install` once and launch Ubuntu; the manifest keeps
  both updated after that.
- **Install Unity editors, Rider or Android Studio.** Their own installers own
  them.
- **Pass `--include-unknown` to winget.** That flag makes it act on packages
  whose installed version it cannot parse, which is how an update run starts
  reinstalling over the top of working hand-installed software. Available as
  `-IncludeUnknown` when you actually want it.
- **Overwrite a profile it did not write.** One without the
  `managed by windows/bootstrap.ps1` marker is copied to `.bak` first.

## Files

| File | Purpose |
|---|---|
| `bootstrap.ps1` | The entry point. Everything runs from here, and it holds the version. |
| `packages.psd1` | The manifest — what to install, what to hold, what to leave alone. |
| `profile.ps1` | PowerShell profile, deployed to both the 5.1 and 7 paths. |
| `merge-terminal-settings.ps1` | Patches two keys in Windows Terminal's `settings.json`. |
| `mpv/` | mpv configuration — `mpv.conf`, `input.conf` and `script-opts/autoload.conf` — deployed to `%APPDATA%\mpv\`. |
| `CHANGELOG.md` | Per-version history. |

## Releasing

All three platforms ship in **one** GitHub release. The tag names the bundle,
not a version — `git tag v2026.02` — and each platform keeps its own number, so
a release states which version of each is inside.

This one's version lives in `$script:BootstrapVersion` in `bootstrap.ps1`.

```sh
# 1. bump $script:BootstrapVersion in whichever platform(s) changed
# 2. add the matching section to that platform's CHANGELOG.md
# 3. commit, then:
git tag v2026.02 && git push origin v2026.02
```

`.github/workflows/release.yml` publishes from there, and refuses to if any
platform's current version has no changelog section, if any shipped `.ps1`
fails to parse or trips the shadowed-variable check, or if either shell script
fails `bash -n` or shellcheck. Release notes are the three changelog sections,
one after another; assets are a zip for Windows, a `.tar.gz` for each of Linux
and macOS, and a `.sha256` for all three.
