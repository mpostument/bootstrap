# Changelog

Versions of `windows/bootstrap.ps1` and the manifest it reads.

The version lives in one place, `$script:BootstrapVersion` in `bootstrap.ps1`,
and its notes live here. The release workflow reads both, and refuses to
publish a release in which this version has no section below — so an entry
here is not optional.

All three platforms ship in one GitHub release, tagged `vX`. That tag names the
bundle, not a version: the platforms version independently, because a fix on
one is not a reason to renumber the other two, and the release states which
version of each is inside.

Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/);
versioning is [SemVer](https://semver.org/spec/v2.0.0.html), read as:

- **major** — a flag or manifest key changed shape, so an existing invocation or
  a hand-edited `packages.psd1` could stop working.
- **minor** — packages added or removed, new flags, new behaviour.
- **patch** — fixes that change nothing about how you call it.

## [1.23.0]

Oh My Posh replaced with Starship, matching the same move on the Linux and
macOS sides. The reason: powerlevel10k, the theme the other two platforms
used, is "basically unmaintained" as of 2026 by its own maintainer's words -
and Starship reads the exact same `starship.toml` on all three platforms
instead of a separate theme per shell, so this closes a real gap rather
than trading one prompt for another for its own sake.

### Changed

- **`Starship.Starship` replaces `JanDeDobbeleer.OhMyPosh` in the `shell`
  group.** `starship.toml` at the repo root - not a per-platform file - is
  deployed to `%USERPROFILE%\.config\starship.toml` and pointed at
  explicitly via `$env:STARSHIP_CONFIG` in `profile.ps1`, rather than
  trusted to Starship's own Windows default
  (`{FOLDERID_RoamingAppData}\starship\config.toml`, a different path than
  the `~/.config` one Linux/macOS use). Transient prompt - the old
  `prompt-theme.omp.json` fork's whole reason to exist - is now
  `Enable-TransientPrompt`, a real Starship feature; that fork is deleted
  from the repo.
- **Nerd Font install no longer depends on Oh My Posh.** `oh-my-posh font
  install` was the only thing that ever put Meslo on a Windows machine,
  which is what made Oh My Posh un-removable even after Starship took over
  the prompt. `Install-NerdFont` fetches the release archive from
  `ryanoasis/nerd-fonts` directly (the same source the Linux/macOS sides
  already used independently of any prompt tool), installs the `.ttf`
  files into the per-user font store, registers each one under
  `HKCU:\...\Fonts` by its own face-table name, and broadcasts
  `WM_FONTCHANGE` so already-running windows - this console host included -
  see it without a logoff.
- **The Oh My Posh theme-sync phase is gone.** It existed to copy themes
  out of the versioned `ohmyposh.cli` MSIX folder on every update; nothing
  replaces it because nothing needs to - `starship.toml` is one file, not a
  themes directory to keep in sync.

### Removed

- **`prompt-theme.omp.json`**, the forked Oh My Posh theme. If you had
  further customised it by hand, port those changes into `starship.toml`
  (TOML, not JSON, and Starship's own module names rather than Oh My
  Posh's segment types) - this file is not read by anything any more.

## [1.22.0]

### Changed

- **`tools` now prints only the `cli` group**, not every group in the
  manifest. Requested directly: the other groups have no cmd/desc data and
  were just noise next to the enriched cli listing - `-ListPackages` is
  still the full, every-group reference. Same change in
  linux/CHANGELOG.md and macos/CHANGELOG.md.

## [1.21.0]

### Added

- **`tools` now shows what to actually type and what it does, for the `cli`
  group.** Requested directly: a package ID like `sharkdp.bat` is not the
  command you run, and Windows is the platform where that gap is worst -
  every winget id in the group is `Publisher.Name`, never the binary name.
  Sourced from `tools/cli-parity.conf`'s new `cmd`/`desc` columns, matched
  by the exact winget id, so there is no guessing which row a package
  belongs to. Everything outside `cli` is unaffected - `Google.Chrome`
  opens from the Start Menu, not a prompt, and has no row there anyway.
  Same change in linux/CHANGELOG.md and macos/CHANGELOG.md.

## [1.20.0]

### Added

- **`tools`, a shell function always available at a prompt, no repo needed.**
  Same muscle-memory idea as `cat`/`ls`/`find`/`grep` above: the shell phase
  writes `tools-list.ps1` next to the profile on every run, from
  `packages.psd1` as of that run, and `profile.ps1` dot-sources it if
  present. Stale exactly the way the other aliases are if the manifest
  changes and this script does not run again - `-ListPackages` is the live
  version for when that matters. Same command in linux/CHANGELOG.md and
  macos/CHANGELOG.md.

## [1.19.0]

### Added

- **`-ListPackages`, printing every package id in every group and exiting
  without touching anything.** Requested directly: the manifest has grown
  past the point of remembering what is in it. `-ListGroups` still gives
  the short, count-only version. Same flag added in linux/CHANGELOG.md
  and macos/CHANGELOG.md.

## [1.18.0]

### Added

- **`du`/`df` functions in `profile.ps1`, routing to `dust`/`duf`.** Same
  muscle-memory idea as cat/ls/find/grep above, requested explicitly rather
  than assumed - dust prints a tree with bars and duf a table with
  different columns, so neither is a drop-in for a script parsing
  traditional du/df output; that script should keep calling the real
  binary. Same pair added in linux/CHANGELOG.md and macos/CHANGELOG.md.

### Fixed

- **The DBeaver Community comment overstated what it covers.** It has no
  driver at all for MongoDB, Cassandra, Redis or InfluxDB - those need the
  paid Lite/Enterprise/Ultimate editions - rather than a limited one.
  Comment corrected; same fix in linux/CHANGELOG.md and
  macos/CHANGELOG.md.

## [1.17.0]

### Added

- **`tstack.lnav` in the `cli` group.** Log file navigator - auto-detects
  format and timestamps, highlights ERROR/WARN levels. Same addition in
  linux/CHANGELOG.md and macos/CHANGELOG.md; `tools/cli-parity.conf`
  updated to match.

## [1.16.0]

### Removed

- **`chmln.sd`, `sharkdp.hyperfine`, `Fastfetch-cli.Fastfetch` and
  `direnv.direnv`, all reverting 1.15.0.** Added without asking first;
  taken back out at the user's request rather than kept because they
  happened to already be there. The direnv hook in `profile.ps1` is
  removed with it. Same reversion in linux/CHANGELOG.md and
  macos/CHANGELOG.md.

## [1.15.0]

### Added

- **`sd`, `hyperfine` and `fastfetch` in the `cli` group.** A sed
  alternative, a benchmarking tool, and a fast neofetch replacement -
  neofetch itself has been unmaintained since 2024.
- **`direnv.direnv` in the `cli` group, hooked in `profile.ps1`** next to
  zoxide (`direnv hook pwsh`), not just installed - per-directory
  environment variables need the shell hook to do anything.

Same additions land in linux/CHANGELOG.md and macos/CHANGELOG.md;
`tools/cli-parity.conf` updated to match.

## [1.14.0]

### Added

- **`procs`, `dust`, `duf` and `glow` in the `cli` group.** Modern
  replacements for `ps`, `du`, `df`, and a markdown reader for the
  terminal - same "modern CLI bundle" bundle as bat/eza/fd. Same four land
  in linux/CHANGELOG.md and macos/CHANGELOG.md; `tools/cli-parity.conf`
  updated to match.

## [1.13.0]

### Added

- **`DBeaver.DBeaver.Community` in the `apps` group.** A DB client, fully
  open source rather than a free tier of a paid app like TablePlus. Added
  to all three manifests - see linux/CHANGELOG.md and macos/CHANGELOG.md.

## [1.12.0]

### Added

- **`Bruno.Bruno` in the `apps` group.** An API client, chosen over Postman:
  collections are plain-text files that diff in git, not a vendor account.
  Added to all three manifests - see linux/CHANGELOG.md and
  macos/CHANGELOG.md.

### Changed

- **`OpenTofu.Tofu` in the `dev` group, replacing `Hashicorp.Terraform`.**
  HashiCorp's 2023 BSL relicensing and its 2025 acquisition by IBM; OpenTofu
  is the actively maintained open fork. `tofu` on PATH instead of
  `terraform`. Same swap in linux/CHANGELOG.md and macos/CHANGELOG.md.

## [1.11.0]

### Added

- **`prompt-theme.omp.json`, our own fork of Oh My Posh's stock
  `jandedobbeleer.omp.json`, deployed alongside it and now what `profile.ps1`
  actually points at.** The stock theme rendered the full multi-segment bar
  (user, path, git, duration, shell, time...) for every past command, and
  left every one of those renders sitting in the scrollback - so copying a
  few lines out of the terminal dragged one full bar per line along with
  them. The fork adds a `transient_prompt` block, which Oh My Posh picks up
  automatically (no `Enable-*` call needed, confirmed against the installed
  v31.2.0): once a command is submitted, that now-historical prompt
  collapses to a single arrow, and only the live prompt at the bottom keeps
  the full bar. Deployed under its own filename so the existing stock-theme
  sync (which walks names out of the `ohmyposh.cli` appx package) never
  overwrites it.

## [1.10.1]

### Fixed

- **The whole script failed to parse under Windows PowerShell 5.1 - not just
  a feature, the entire file.** Two spots in the Git/UnityYAMLMerge step used
  the `?:` ternary operator, which is PowerShell 7.0+ only. PowerShell parses
  a script file in full before running a single line of it, so this wasn't a
  runtime error somebody could hit by using that feature - `.\bootstrap.ps1`
  under 5.1 (`powershell.exe`, not `pwsh`) failed at parse time before
  anything ran, including `-ShowVersion`. That is the exact invocation
  README.md documents (`powershell.exe -ExecutionPolicy Bypass -File
  .\bootstrap.ps1`) for a script that Windows has marked as downloaded, so it
  broke a path the docs call out as supported, for anyone not already on
  PS7. Introduced in the commit that added the Unity merge-tool step; shipped
  in v2026.09 through v2026.09.3 before anyone using 5.1 noticed, because the
  release workflow's parse check only runs under `pwsh` (7), which accepts
  the ternary fine. Replaced both with the `$(if(){}else{})` form already
  used elsewhere in this file for the same 5.1-compat reason - see the
  comment at the first site.

## [1.10.0]

Two additions to the `shell` phase: a real `sudo` for Windows, and git
tab-completion in the profile.

### Added

- **`gsudo` (`gerardog.gsudo`), added to the `shell` group.** Elevates one
  command without spawning a whole separate admin window/profile the way
  `Start-Process -Verb RunAs` does. Not added to the `cli` group: it is a
  shell-elevation tool, not part of the modern-CLI bundle, and Linux/macOS
  need no equivalent package - `sudo` already ships there. See
  `tools/cli-parity.conf` for how a platform-specific tool like this gets
  written down deliberately rather than just added quietly.
- **`posh-git`, added to `Modules51` and `Modules7`.** Tab-completion for git
  subcommands, branches and remotes in PSReadLine's menu - a different
  feature from Oh My Posh's git segment, which shows status *in* the prompt
  rather than completing anything. Imported in `profile.ps1` **before**
  Oh My Posh's `init`, deliberately: posh-git also defines its own `prompt`
  function, and whichever import runs last wins that fight. Oh My Posh
  already owns the prompt line, so it has to load second.

### Changed

- **`TerminalFontSize` is `14`, not `16`.** Deliberately not matching the 16
  ghostty/iTerm2 use on the other two platforms - 14 is the size actually
  used on Windows. `merge-terminal-settings.ps1`'s own `-FontSize` default
  stays at 16: it exists only as a standalone-invocation fallback (nothing
  in the real call path from `bootstrap.ps1` ever reads it, since every
  value is always passed explicitly from `packages.psd1`), so it mirrors the
  general 16pt intent rather than this platform's specific override.

## [1.9.0]

Windows Terminal `settings.json` gets the same treatment ghostty already has
on the Unix side: knobs declared in the manifest, merged into the live file,
never a wholesale overwrite. Also brings the PowerShell history size up to
match the Unix side, which had drifted apart quietly.

### Added

- **Windows Terminal is more than a font default now.** The merge script had
  been rewriting exactly two things - `profiles.defaults.font.face` and one
  `profiles.list[]` entry - and everything else was WT's default. Ghostty
  gets 14 knobs on the Unix side, so five of the ones that carry across land
  here too, each in `Shell = @{ ... }` in `packages.psd1` and each written
  into `settings.json` by an idempotent merge that never overwrites a value
  the user has hand-set to something different:

  - `TerminalFontSize = 16`. WT's default is 12; matches the ghostty side,
    which matches the iTerm2 profile before that.
  - `TerminalColorScheme = 'Catppuccin Mocha'` + the full palette under
    `TerminalColorSchemeDef`. The name is written into
    `profiles.defaults.colorScheme`; the palette is added to `schemes[]` on
    first run if no scheme by that name is already defined. **NEVER**
    overwritten - somebody's hand-tuned Catppuccin Mocha survives every
    subsequent run. Matches ghostty's `theme = Catppuccin Mocha`.
  - `TerminalCopyOnSelect = $true`. Selecting text copies to the clipboard
    Ctrl-V pastes from. WT has no separate primary-selection buffer the way
    ghostty does, so there is only one thing this means and no
    `clipboard`-vs-`true` trap of the kind the ghostty side had.
  - `TerminalPadding = '10, 10'`. WT's default is 8; matches ghostty's 10/10.
  - `TerminalHistorySize = 100000` (lines, WT's unit). WT's default is 9001,
    which is small on a machine that runs long log tails. Rough intent-match
    for ghostty's 256MB per surface without asking for `-1 = unlimited` and
    the memory it never gives back.

  The merge script never rewrites an existing value to itself, so a run that
  changes nothing reports `current` rather than claiming an install - same
  shape as the ghostty phase on Unix.

### Fixed

- **`Set-PSReadLineOption -MaximumHistoryCount 10000` was a tenth of what the
  Unix side keeps.** The profile said the number matched Linux, and it did
  at the time it was written, but the Unix side moved to 1000000 -
  `HISTORY_SIZE` and `HISTORY_FILE_SIZE` on both platforms - and this line
  never followed. So a busy user hit the ceiling on Windows weeks before
  they hit it on Linux, and the ListView / Up-arrow search silently forgot
  the older half. Comment rewritten to name the Unix variables it is
  tracking now.

## [1.8.1]

### Fixed

- **`-ShowVersion` could not run anywhere but Windows**, which is a problem
  because the release workflow runs it on a Linux runner to prove the script
  can start at all. The check found this on its first real release, which is
  the entire reason it exists.

  The version block sat *after* the path resolution, and three lines of that
  resolution read `$env:LOCALAPPDATA`, `$env:ProgramFiles` and `$env:WINDIR`.
  All three are null off Windows, so `Join-Path` threw "Cannot bind argument
  to parameter 'Path' because it is null" long before the version was printed.

  The early return is now the first thing the script does after
  `Set-StrictMode`, so nothing about the host has been assumed by the time it
  answers. Same shape as the `$PSScriptRoot` bug the file already documents:
  it parses, every line is right on its own, and only one invocation shows it.

## [1.8.0]

### Added

- **A `cloud` group** — kubectl, Helm, k9s, the AWS CLI v2, the Azure CLI and
  the Google Cloud CLI. Kept in step with the Linux and macOS manifests so the
  same commands exist wherever you land, which is the same reason the `cli`
  group is identical across the three.

  `stern` is deliberately absent: winget has no package for it, and an id that
  does not resolve fails on every single run rather than once.

- **A `git` phase, for two things a Unity checkout needs that installing
  software does not give you.**

  **Git LFS** is bundled with Git for Windows, so there is no package here —
  adding `GitHub.GitLFS` would put a second copy on the machine for winget to
  fight `Git.Git` over. What the phase does instead is check the part that
  actually matters: `git lfs install` writes the clean/smudge/process filters
  into the global config, and having the binary without the filters means
  checkouts silently produce pointer stubs instead of files. A Unity project
  full of those will not open.

  **UnityYAMLMerge** is registered as a mergetool. It is the difference between
  a merge conflict in a `.unity` scene or `.prefab` being resolvable and not:
  those files are enormous auto-generated YAML with unstable ordering, git's
  line-based merge cannot do anything sensible with them, and without this the
  practical answer to a scene conflict is to pick a side and redo the other
  person's work.

  Registered as a mergetool rather than a merge driver, on purpose. A driver
  runs automatically on every merge in every repository, and one that cannot
  find its executable breaks the merge; a mergetool is invoked deliberately
  with `git mergetool` and is inert until asked.

  Unity Hub installs editors side by side, so the newest one carrying the tool
  wins — sorted as versions rather than strings, because a string sort puts
  `2022.3.9f1` after `6000.0.58f1`.

### Fixed

- **A package winget cannot read the version of was reported as `failed`.**
  `Google.CloudSDK` is one — `winget list` shows it without a version number,
  so winget declines to upgrade it and says `--include-unknown` would force it.
  Nothing has gone wrong there: the SDK updates itself through `gcloud
  components update`, and overriding that would put two installers on one
  package. It reports `skipped` with a reason now, instead of a red line on
  every run for something behaving exactly as intended. `Ubisoft.Connect` is in
  the same category and gets the same treatment.

## [1.7.0]

### Added

- **`Zoom.Zoom.EXE`** joins the `apps` group. Note the id: winget publishes
  both `Zoom.Zoom` and `Zoom.Zoom.EXE`, the same product in two installer
  flavours. The copy already on this machine came from the EXE manifest, so
  naming the other one would have installed a second Zoom beside it instead of
  upgrading the one that is there — confirmed by the dry run reporting
  `would-upgrade 7.0.6` rather than `would-install`.

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
