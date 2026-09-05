# Changelog

Versions of `windows/bootstrap.ps1` and the manifest it reads.

The version lives in one place, `$script:BootstrapVersion` in `bootstrap.ps1`.
The release workflow refuses to publish a tag whose version disagrees with it,
and reads the release notes from the matching section below — so an entry here
is not optional.

Tags are `windows-vX.Y.Z`. The prefix is deliberate: this repository is meant to
hold more than one platform, and a bare `vX.Y.Z` would imply all of it had been
released together.

Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/);
versioning is [SemVer](https://semver.org/spec/v2.0.0.html), read as:

- **major** — a flag or manifest key changed shape, so an existing invocation or
  a hand-edited `packages.psd1` could stop working.
- **minor** — packages added or removed, new flags, new behaviour.
- **patch** — fixes that change nothing about how you call it.

## [1.6.0]

### Added

- Packages, all of them chosen to keep the two platforms in step now that a
  Linux bootstrap exists alongside this one: `MikeFarah.yq` next to `jq`,
  `GoLang.Go`, and `Microsoft.OpenJDK.21` — Microsoft's build rather than
  Oracle's, since it is the same OpenJDK sources with no click-through licence
  and matches what the Linux side gets from `default-jdk`.

### Changed

- **Python moves from 3.12 to 3.14**, the newest stable line rather than the
  one the machine happened to have. `Python.Launcher`, already in the manifest,
  is what makes that safe: `py` picks between whatever is installed, and a
  project pinned to an older minor keeps working through `py -3.12`. Note that
  changing the id does not remove the old version — nothing here ever
  uninstalls — so 3.12 stays on disk and simply stops being upgraded.
- The release workflow is now `release-windows.yml`, alongside a
  `release-linux.yml`, since this repository releases each platform separately.

## [1.5.0]

### Added

- **A daily unattended run**, registered as a Windows scheduled task by a new
  schedule phase. This is what the rest of the tool was built for: every phase
  reports `current` when it changed nothing, so a daily run costs almost
  nothing and its log is only worth reading on the days it is *not* all
  `current`. Configured under `Schedule` in the manifest — time, task name, log
  directory, retention — and disabled either with `Enabled = $false` or, for a
  single run, `-SkipSchedule`.

  Logs go to `%LOCALAPPDATA%\windows-bootstrap\logs`, one file per day, pruned
  past `KeepLogDays`. Pruning happens on every run rather than only when the
  task changes, or a machine whose task is already correct would never clean up
  — which is every machine after the first run.

  The task runs as you, interactively, elevated, so nothing needs a stored
  credential; registering it therefore needs one elevated run, and an
  unelevated run reports the step as `skipped` with the reason rather than
  failing. `StartWhenAvailable` means a machine that was asleep at the trigger
  time catches up instead of silently missing the day, and the battery settings
  are deliberate: "only when plugged in" is how a laptop goes months without
  ever running this.

  The path to PowerShell is chosen carefully, and `(Get-Command pwsh).Source`
  is specifically *not* it. Where PowerShell came from the Store that resolves
  to `C:\Program Files\WindowsApps\Microsoft.PowerShell_7.6.5.0_x64__…`, a path
  with the version in it — the folder is renamed on the next update and the
  task then fails silently at 04:20 with nobody watching. It is the same shape
  as the versioned Oh My Posh MSIX directory the shell phase already works
  around. The task points at the WindowsApps execution alias, the Program Files
  install, or System32's `powershell.exe`, in that order — all of which stay
  put.
- `-SkipSchedule`, for symmetry with `-SkipShell` and `-SkipMpv`.
- `Schedule` joins the manifest sections checked at load and in CI.

## [1.4.0]

### Added

- **`Hashicorp.Terraform`** joins the `dev` group. The plain id, not `.Alpha`,
  `.Beta` or `.RC` — winget publishes all four and they share the `terraform`
  moniker, so it is worth being explicit that a routine update run should never
  pull a prerelease.
- **Two more mpv scripts**, chosen by looking at what the popular mpv config
  packs actually ship rather than from memory:
  - **chapterskip** — press `Ctrl+s` during an opening and it fast-forwards to
    the next silence, which is where an OP almost always ends. Deliberately not
    automatic: nothing is skipped unless you ask, which is the right default
    for a script that guesses. Taken from `dyphire/mpv-scripts` rather than the
    original `po5/chapterskip` — same lineage, but that one has not been
    touched since 2022 while this collection is actively maintained.
  - **auto-save-state** — `mpv.conf` already sets `save-position-on-quit`, but
    that only writes on a *clean* quit, so a crash or a killed process loses
    the position entirely. This re-saves periodically; the worst case becomes a
    minute of rewatching rather than starting the episode again.

  Note for anyone binding chapterskip themselves: it registers through
  `mp.register_script_message`, so `input.conf` needs `script-message
  skip-to-silence`. The script's own header comment says `script-binding`,
  which silently does nothing.

### Changed

- uosc stays as the on-screen UI, and that is a deliberate re-check rather than
  inertia. Measured against the alternatives: uosc 3.4k stars and last pushed
  days ago, ModernZ 1.2k and three months, ModernX 761 and seven. They all
  replace the OSC, so it is one or the other — and uosc is both the most
  capable and the most actively maintained. The `#!` menu entries in
  `input.conf` are a uosc convention, so switching would mean rewriting those
  too.

## [1.3.1]

### Fixed

- **1.3.0 shipped with the `Shell` section missing from `packages.psd1`
  entirely.** The whole shell phase — Nerd Font, Oh My Posh themes, PowerShell
  modules, the profile, execution policy, Windows Terminal — died on
  `The property 'Shell' cannot be found on this object`. An edit to the
  neighbouring `Mpv` block had taken the section that followed it along too.
  The section is restored unchanged.

  Two things let it through, and both are now closed. `Import-PowerShellDataFile`
  succeeds on a manifest that is short an entire section, so nothing objected
  until a phase 400 lines later tried to read it — and every verification run
  after that edit happened to pass `-SkipShell`, so the one phase that reads it
  was never exercised.

### Added

- **The manifest is checked for its required sections at load**, right after
  the import, instead of failing later with a StrictMode property error that
  names the consuming line and says nothing about the manifest. A missing
  section now stops the run immediately with the sections it wanted, the ones
  it found, and the path it read.
- The release workflow performs the same check, so a manifest short a section
  cannot be published.

## [1.3.0]

### Added

- **mpv is put on your `PATH`.** Its installer writes `mpv.exe` under Program
  Files and adds nothing to `PATH`, so `mpv file.mkv` from a prompt did not
  work even after a successful install. The mpv phase now appends the directory
  it actually resolved the player in to the **user** `PATH` — never the machine
  one, which would need elevation and is not this tool's to edit. Set
  `AddToPath = $false` in the manifest's `Mpv` section to opt out.

  The registry write is deliberately not the one-liner. Reading `PATH` through
  `[Environment]::GetEnvironmentVariable` *expands* it, so `%USERPROFILE%\bin`
  comes back as a literal path; writing that back both freezes every such entry
  to what it meant at that moment and downgrades the value from
  `REG_EXPAND_SZ` to `REG_SZ` for everything afterwards. The damage is silent
  and only surfaces later, on a machine whose profile directory moved. So the
  raw value is read with `DoNotExpandEnvironmentNames`, appended to, and
  written back with its original value kind. Verified on a real `PATH`
  containing `%USERPROFILE%\.dotnet\tools`, which survived unexpanded.

  Comparison ignores a trailing separator, so a re-run reports `current`
  instead of growing a duplicate entry. A `WM_SETTINGCHANGE` broadcast tells
  already-running shells to re-read the environment — without it a terminal
  opened *after* the change still inherits Explorer's stale copy and the entry
  looks like it did not take. The broadcast is best-effort: if it fails, the
  registry write, which is the part that persists, has already happened.

## [1.2.0]

### Added

- **Two mpv scripts.** `autoload` builds a playlist from the rest of the
  directory when a file is opened — without it the uosc playlist menu bound in
  `input.conf` is always empty, because nothing else ever puts anything in a
  playlist. `memo` is a recently-played menu that detects uosc and renders
  inside it. Both are single Lua files on the existing stamped download path.
- **`mpv/script-opts/autoload.conf`**, deployed to `%APPDATA%\mpv\script-opts\`,
  which is the only place mpv looks for a script's configuration. It restricts
  playlists to one media type, keeps images out, and ignores sample clips and
  in-progress downloads.
- PowerToys **Command Not Found** is imported from `profile.ps1`. PowerToys
  normally writes that import into the profile itself, fenced between two
  GUID-carrying comment lines — which cannot survive a managed profile, since
  the redeployed file replaces it and the replacement carries the "managed by"
  marker, so there is no `.bak` either. Declaring it here makes it survive.
- Packages: `Anthropic.Claude`, `Rufus.Rufus`, `OBSProject.OBSStudio`,
  `qBittorrent.qBittorrent`, `Ubisoft.Connect`.

### Changed

- **The four mpv add-ons are no longer pinned.** They now resolve the newest
  release tag (uosc) or commit (thumbfast, autoload and memo, none of which
  publishes releases or tags) on every run. This is desktop config on an
  interactive machine, where staying current beats reproducibility.

  Unpinned is not unversioned: the resolved value is still written to a stamp
  file, so a run that finds nothing new downloads nothing and the summary
  reports a real `0f711de -> a3c91b2`. An unreachable GitHub reports `current`
  with `(could not reach GitHub to check for newer)` rather than failing.
  `-SkipUpgrade` skips the lookup for anything already installed. The `autoload`
  lookup is narrowed to `TOOLS/lua/autoload.lua`, since tracking every commit to
  mpv itself would re-download a byte-identical script several times a week.

  Four near-identical install blocks collapsed into one loop over manifest data,
  which is what made the pinning question answerable in the manifest rather than
  in code.
- **Node moves from `OpenJS.NodeJS` to `OpenJS.NodeJS.LTS`, and `Pins` is now
  empty.** The pin existed because a hand-installed 24.x lived outside winget,
  where "install if missing" would have added 26.x alongside it. When that copy
  was later uninstalled the pin outlived what it protected: it went on refusing
  to install Node *and* on reporting a version that described nothing on disk.
  A pin is hands-off in both directions by design, so it cannot notice that the
  world moved. The LTS channel enforces the same rule upstream and needs no
  maintenance. Prefer a channel that encodes the rule; pin only when no id does.

### Removed

- `RaspberryPiFoundation.RaspberryPiImager`, superseded by Rufus for writing
  bootable media. Note what removal does and does not do: the manifest is the
  list of what this script *manages*, so a copy already installed stays exactly
  where it is and simply stops being upgraded. Nothing here ever uninstalls.

### Fixed

- **The whole mpv phase was skipped on machines where mpv was installed.** The
  probe was `Get-Command mpv`, which answers "can I type mpv at a prompt" — a
  different question. `shinchiro.mpv` is a plain installer, not one of winget's
  shimmed portable packages: it writes its exe under Program Files and adds
  nothing to `PATH`, nor a shim under `%LOCALAPPDATA%\Microsoft\WinGet\Links`.
  So a run reported `missing` while `winget list` reported a version, and the
  config, uosc and thumbfast were never deployed. `Update-SessionPath` could not
  help — there was nothing in the registry `PATH` to pick up. A new
  `Resolve-MpvExe` asks the installer instead: `PATH`, then `InstallLocation` on
  the uninstall keys, then the well-known directories.
- **PowerShell modules were re-downloaded on every run.** `Install-Module -Force`
  does not mean "make sure it is there", it means "fetch and write it again
  regardless". The check now runs inside the target edition — PS7 and 5.1 have
  different module paths, so one session's view says nothing about the other's —
  and installs only what is missing or behind. An unreachable gallery no longer
  counts as a failure when the module is present and past its floor.
- **A script passed to a child PowerShell lost every double quote.** Windows
  PowerShell 5.1 wraps a native-command argument in quotes without re-escaping
  the double quotes inside it, so `-Command` with a script string silently
  corrupts it and the child then fails to parse. It fires only when 5.1 is the
  *parent* — the invocation the README recommends — and not from a PowerShell 7
  parent, which makes it easy to miss. The child script is handed over as a file
  now; `-File` has no quoting rules to get wrong.
- **Anything a child process wrote to stderr ended the whole run.** Redirecting
  stderr into the output stream turns it into `NativeCommandError` records, and
  this script runs under a `Stop` error preference, so one stderr line from
  winget or a module install terminated the run instead of being reported as a
  failed step. Both call sites now drop to `Continue` for the duration of the
  native call only; output is still captured and the exit code still decides.
- **One versionless registry key would end the whole run.** The
  externally-managed scan read `DisplayVersion` straight off every matching
  uninstall key, and under `Set-StrictMode -Version Latest` a missing property is
  a *terminating* error, not a blank string. It stayed invisible because every
  entry then present happened to carry a version. The scan now requires a
  `DisplayName` before counting a key as real, reads values through a
  StrictMode-safe helper, and reports `version not recorded` instead of an empty
  gap.
- **Oh My Posh themes were reported as changed on every run.** The sync ran
  `Copy-Item -Force` unconditionally and then declared `installed`, so every
  theme file was claimed as a change by a run that changed nothing — which makes
  the summary useless for spotting the run that *did* change something. Source
  and destination are now compared on name, length and modification time, and
  only stale files are copied.
- **The release archive never contained `windows/mpv/`.** 1.1.0 shipped the mpv
  phase but staged only the top-level files, so a downloaded release on a machine
  with mpv installed reported the package as installed and then died copying a
  source file that was not there. Nothing caught it because every test run was
  from a git checkout, where the directory is always present.

## [1.1.0]

### Added

- **mpv, set up properly rather than just installed.** `shinchiro.mpv` joins the
  `apps` group, and a new phase deploys `%APPDATA%\mpv\`: `mpv.conf`
  (`gpu-next` on `d3d11`, `profile=high-quality`, `hwdec=auto-safe`, and a large
  cache tuned for network playback), `input.conf` (sane bindings plus the uosc
  menu on right-click), **uosc** (a real UI in place of the minimal built-in
  controller) and **thumbfast** (hover-preview thumbnails on the seek bar, which
  uosc picks up automatically).

  Both downloads are recorded in a stamp file, so a re-run that finds the wanted
  versions in place does nothing rather than re-fetching. The configs follow the
  profile's rule: replaced freely if this script wrote them, copied to `.bak`
  first if you did.
- `-SkipMpv`, for symmetry with `-SkipShell`.

### Fixed

- **`Set-ExecutionPolicy` could kill the entire run after doing its work.** It
  writes a *non-terminating* error when it succeeds but a more specific scope
  still wins. Under a `Stop` error preference that promotes to terminating — and
  it fires whenever the session was started with `-ExecutionPolicy Bypass`, which
  is what the README tells you to do with a freshly downloaded copy. The step now
  judges by re-reading the resulting policy rather than by the absence of a
  message.
- **`Update-SessionPath` discarded the caller's `PATH`.** It rebuilt the whole
  variable from the registry, silently dropping anything the calling session had
  added to its own process `PATH`. It merges now.

### Changed

- Profile and mpv config deployment share one `Deploy-ManagedFile`, so every
  managed file follows the same rule about backing up hand-written copies.

## [1.0.3]

### Fixed

- **A loop variable silently overwrote the tool's own directory.** The script
  kept its own path in a script-scoped variable, and an unrelated `foreach` over
  registry hives 300 lines later wrote to that same name — PowerShell variable
  names are case-insensitive, and an unscoped assignment writes to the enclosing
  scope. The profile path became a registry path, `Get-Content` dispatched to the
  registry provider, and the run died complaining about a `-Raw` parameter on an
  unrelated line. Every sibling path is now resolved once, up front.

### Added

- Every line shows what a package moves *to*, not just where it is, so a preview
  says what you are agreeing to.
- The release workflow walks the AST of every shipped script and fails if a loop
  variable shadows a script-scoped one. Nothing catches that by reading: it
  parses, and both halves look correct in isolation.

## [1.0.2]

### Fixed

- **`$PSScriptRoot` is empty while parameter defaults are evaluated** when an
  advanced script — one carrying `[CmdletBinding()]` — is launched with `-File`.
  The script threw before its first line, and only under `-File`, which is the
  invocation the README recommends for a downloaded copy. Paths are resolved in
  the body now, never in the param block.

### Added

- The release workflow launches the script with `pwsh -File` and checks that it
  can actually start, not merely parse.

## [1.0.1]

### Fixed

- **The Mark of the Web broke the download path outright.** Windows marks every
  file extracted from a downloaded archive as internet content, and the default
  `RemoteSigned` policy refuses to run a marked script. The script now unblocks
  its own directory during preflight and reports how many files it cleared. It
  cannot clear the mark from the file you are trying to *start*, so the README
  leads with `Unblock-File`.
- The deployed profile is unblocked after the copy, since `Copy-Item` carries the
  mark across.

### Changed

- Documentation is standalone: the README, the comment-based help and this
  changelog no longer assume you can see the rest of the repository.

## [1.0.0]

### Added

- `bootstrap.ps1` — one command that both builds a fresh machine and updates an
  existing one, working out per package which it is doing.
- `packages.psd1` — the manifest, sorted by who owns each piece of software:
  winget packages it installs and upgrades, pinned packages it leaves alone in
  both directions, and software owned by another installer that it only detects
  and reports.
- `-WhatIf` and `-Confirm` throughout, via `SupportsShouldProcess`.
- `-Groups`, `-SkipUpgrade`, `-SkipShell`, `-Silent`, `-IncludeUnknown`,
  `-ListGroups`, `-ShowVersion`.
- Shell setup: Nerd Font, Oh My Posh themes, PowerShell modules for both
  editions, the profile, execution policy, and a Windows Terminal settings merge
  that patches two keys instead of overwriting the file.

### Fixed

- The Nerd Font check looked only in `%WINDIR%\Fonts`, so it reinstalled the font
  on every run — `oh-my-posh font install` writes to the per-user store when not
  elevated.
- `PATH` is refreshed from the registry after the install phase, so a package
  installed at the top of a run is visible to a check at the bottom of it.
- winget reports "nothing to do" as a *failure* exit code with the reason only in
  the text, which turned clean runs into walls of red.
