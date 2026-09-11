# Changelog

Versions of `linux/bootstrap.sh` and the manifest it reads.

The version lives in one place, `BOOTSTRAP_VERSION` in `bootstrap.sh`,
and its notes live here. The release workflow reads both, and refuses to
publish a release in which this version has no section below — so an entry
here is not optional.

All three platforms ship in one GitHub release, tagged `vX`. That tag names the
bundle, not a version: the platforms version independently, because a fix on
one is not a reason to renumber the other two, and the release states which
version of each is inside.

Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/);
versioning is [SemVer](https://semver.org/spec/v2.0.0.html).

## [1.16.0]

### Added

- **`tools`, a shell function always available at a prompt, no repo needed.**
  Same muscle-memory idea as `cat`/`ls`/`find`/`grep` above: baked directly
  into the managed `.zshrc` fragment on every run, from `packages.conf` as
  of that run - groups, TOOLS, RELEASES and REPOS packages. Stale exactly
  the way the other aliases are if the manifest changes and this script
  does not run again - `--list-packages` is the live version for when that
  matters. Same command in windows/CHANGELOG.md and macos/CHANGELOG.md.

## [1.15.0]

### Added

- **`--list-packages`, printing every package/tool name this script
  manages and exiting without touching anything.** Requested directly:
  the manifest has grown past the point of remembering what is in it.
  Covers groups, TOOLS, RELEASES and REPOS packages - the four things
  this script actually installs. `--list-groups` still gives the short,
  count-only version. Same flag added in windows/CHANGELOG.md and
  macos/CHANGELOG.md.

## [1.14.0]

### Added

- **`du`/`df` aliases in the zsh fragment, to `dust`/`duf`.** Same
  muscle-memory idea as cat/ls/find/grep above, requested explicitly rather
  than assumed - dust prints a tree with bars and duf a table with
  different columns, so neither is a drop-in for a script parsing
  traditional du/df output; that script should keep calling the real
  binary. Same pair added in windows/CHANGELOG.md and macos/CHANGELOG.md.

### Fixed

- **The DBeaver Community comment overstated what it covers.** It has no
  driver at all for MongoDB, Cassandra, Redis or InfluxDB - those need the
  paid Lite/Enterprise/Ultimate editions - rather than a limited one.
  Comment corrected; same fix in windows/CHANGELOG.md and
  macos/CHANGELOG.md.

## [1.13.0]

### Added

- **`lnav` in the `cli` group.** Log file navigator - auto-detects format
  and timestamps, highlights ERROR/WARN levels; in the official Debian
  archive. Same addition in windows/CHANGELOG.md and macos/CHANGELOG.md;
  `tools/cli-parity.conf` updated to match.

## [1.12.0]

### Removed

- **`sd`, `hyperfine`, `fastfetch` and `direnv`, all reverting 1.11.0.**
  Added without asking first; taken back out at the user's request rather
  than kept because they happened to already be there. The direnv hook in
  the zsh fragment is removed with it, and the four rows in
  `tools/cli-parity.conf` too. Same reversion in windows/CHANGELOG.md and
  macos/CHANGELOG.md.

## [1.11.0]

### Added

- **`sd`, `hyperfine` and `fastfetch` in the `cli` group.** A sed
  alternative, a benchmarking tool, and a fast neofetch replacement -
  neofetch itself has been unmaintained since 2024. All three are in the
  official Debian archive.
- **`direnv` in the `cli` group, hooked in the zsh fragment** next to
  zoxide (`eval "$(direnv hook zsh)"`), not just installed - per-directory
  environment variables need the shell hook to do anything.

Same additions land in windows/CHANGELOG.md and macos/CHANGELOG.md;
`tools/cli-parity.conf` updated to match.

## [1.10.0]

### Added

- **`procs`, `du-dust`, `duf` and `glow` in the `cli` group.** Modern
  replacements for `ps`, `du`, `df`, and a markdown reader for the
  terminal - same "modern CLI bundle" as bat/eza/fd. All four are in the
  official Debian archive, no third-party repository needed. Same four land
  in windows/CHANGELOG.md and macos/CHANGELOG.md; `tools/cli-parity.conf`
  updated to match.

## [1.9.0]

### Added

- **`io.dbeaver.DBeaverCommunity` in the `apps` group's Flathub list.** A DB
  client, fully open source rather than a free tier of a paid app like
  TablePlus. Its Flathub listing is community-maintained, not published by
  DBeaver Corp. Added to all three manifests - see windows/CHANGELOG.md and
  macos/CHANGELOG.md.

## [1.8.0]

### Added

- **`com.usebruno.Bruno` in the `apps` group's Flathub list.** An API client,
  chosen over Postman: collections are plain-text files that diff in git,
  not a vendor account. Added to all three manifests - see
  windows/CHANGELOG.md and macos/CHANGELOG.md.

### Changed

- **`7zip` in the `cli` group, replacing `p7zip-full`.** p7zip is unmaintained
  upstream and was dropped from Debian unstable in 2025; `7zip` is trixie's
  own successor, same `/usr/bin/7z`. `tools/cli-parity.conf` updated to
  match.
- **`tofuenv` in `TOOLS`, replacing `tfenv`.** Manages OpenTofu instead of
  Terraform - HashiCorp's 2023 BSL relicensing and its 2025 acquisition by
  IBM pushed this manifest to the open fork. `tofu` on PATH instead of
  `terraform`. Same swap in windows/CHANGELOG.md and macos/CHANGELOG.md.

## [1.7.0]

One zsh option, so the right prompt stops following commands into the
scrollback.

### Added

- **`setopt TRANSIENT_RPROMPT` in the zsh fragment.** The right prompt carries
  what is worth a glance while you type - nvm's `system`, the kube context,
  the clock - and then stays on that line forever. Those columns are real
  characters, so copying a command out of the scrollback drags
  `system ⎈ prod-blue 17:17:25` along with it. With this option zsh erases
  the right prompt the moment the line is accepted, leaving it only on the
  prompt being typed at. The left half of the same idea,
  `POWERLEVEL9K_TRANSIENT_PROMPT`, is powerlevel10k's own and lives in
  `~/.p10k.zsh` - that file is the user's, not managed here.

## [1.6.0]

The Linux side of the Windows manifest's Schedule phase: a daily unattended
run, so a machine takes updates without anyone remembering to ask for them.

### Added

- **Schedule phase**, registering a `systemd` system timer + service
  (`bootstrap-linux.timer`/`.service` by default). Driven by three new
  manifest keys: `SCHEDULE_ENABLED`, `SCHEDULE_UNIT_NAME`, `SCHEDULE_TIME`.
  New `--skip-schedule` flag mirrors `-SkipSchedule` on Windows.

  A timer rather than cron, for the one thing cron cannot do: `Persistent=true`
  catches up a run the machine was asleep for, the same job Task Scheduler's
  `StartWhenAvailable` does on Windows. Skipped (not failed) when `systemd` is
  not PID 1 — stock WSL is the real case this guards, since the rest of this
  script runs fine there.

  Logging is not reinvented the way the Windows phase has to reinvent it:
  Task Scheduler captures nothing on its own, so that phase pipes output into
  hand-rolled dated files and prunes them itself. A systemd service's
  stdout/stderr goes to the journal by default — `journalctl -u
  bootstrap-linux` is the log, and there is no file for this script to manage.

## [1.5.0]

Same expansion of the ghostty config the macOS side got, minus three knobs
that ghostty documents as macOS-only (`macos-option-as-alt`, `window-save-state`,
`quit-after-last-window-closed`). Also fixes one macOS-ism that got copied
across from the macOS script.

### Added

- **The ghostty config is more than one line now.** `scrollback-limit` was all
  it had, which meant every other decision - font, palette - was ghostty's
  default rather than this manifest's. Five new knobs, each in the manifest
  with a paragraph of why, rendered into `~/.config/ghostty/config` the same
  way scrollback already was.

  - `theme = Catppuccin Mocha`. A name that matches a row from
    `ghostty +list-themes`; ghostty ships 463 of them, so changing palette is
    a one-line edit to the manifest and nothing else. Catppuccin Mocha is the
    widely used dark across dev tooling in 2026.
  - `font-family = MesloLGM Nerd Font Mono`. The Meslo Nerd Font this manifest
    has installed since the first release, matched by its face-table name
    (spaces) rather than the ttf filename. Ghostty's default is empty which
    falls back to the bundled font, so p10k's glyphs were rendering from a
    different font than the one the manifest ships.
  - `font-size = 16`. Ghostty's default is 13; 16 matches the macOS manifest
    so a fleet running both feels the same on either side.
  - `copy-on-select = clipboard`. Selecting text puts it on the clipboard
    Ctrl-V and the GUI paste both reach. **Not `true`**, which Ghostty
    documents as valid and is not the same thing - `true` copies to the X11
    primary selection, a separate buffer only reachable via middle-click or
    Ctrl-Shift-V. `clipboard` is the intuitive one on both X11 and Wayland.
  - `shell-integration-features = cursor,sudo,title,ssh-env,ssh-terminfo`.
    Ghostty auto-installs the shell hooks; this opts INTO the extras.
    `cursor` follows zsh vi-mode with a bar/block change, `sudo` preserves
    the prompt state through sudo, `title` keeps the terminal title tracking
    cwd. `ssh-env` carries `TERM=xterm-ghostty` and `COLORTERM=truecolor`
    through ssh, and `ssh-terminfo` pipes `infocmp -x xterm-ghostty` through
    `tic -x -` on the remote on first connect - installing the entry under
    the remote user's `~/.terminfo`, cached locally afterwards. The two
    features go together - adding `ssh-env` alone actually makes the
    problem worse on hosts without the entry, because the remote now
    thinks it can drive an xterm-ghostty it does not understand.
  - `keybind = global:ctrl+\`=toggle_quick_terminal`. Quake-style drop-down
    terminal summoned from any app with one hotkey. `global:` scopes the
    binding to the desktop; on Wayland this needs the GlobalShortcuts XDG
    portal (KDE and GNOME ship it, most tiling WMs do not). Blank disables.
  - `window-padding-x = 10`, `window-padding-y = 10`. Ghostty's default 2/2
    is visually cramped at 16pt - the prompt sits right against the frame.

### Fixed

- **The script silently exited before the Terminal config phase on some
  `.zshrc` shapes.** The zshrc-hook-order check has two pipelines inside
  `$(...)` command substitutions: one finds the source-line's line number,
  the other counts non-comment lines above it. Both can legitimately end in
  a grep with zero matches - a `.zshrc` that names the file only in a
  comment, or one whose header above the hook is entirely comments and
  blanks. `grep` exits 1 in both cases, `set -euo pipefail` propagates that
  to the assignment, and the whole script exits from *inside* `$(...)`
  without a diagnostic. Both pipelines now end in `|| true`, and the count
  is defaulted to 0.

  The bug was there since the hook-order check landed and only fired for
  specific `.zshrc` shapes, so the run reported `current zshrc hook` and
  stopped without an error line. Terminal config, Manual, and Summary never
  ran.

- **The "ghostty not installed" guard checked `/Applications/Ghostty.app`.** A
  macOS path in the Linux script, copied across when the phase was ported.
  Harmless in practice - the directory is absent on a Linux box, so the AND
  never changed the answer - but the intent was nonsense and it survived
  because it never fired. Now just `command -v ghostty`, which is what the
  check was always trying to be.

## [1.4.0]

The macOS side found these first; this is the same audit run against the Linux
fragment. Not everything carried over - see the note on
`history-substring-search` below - so the two scripts are deliberately not
identical here.

### Fixed

- **`fzf-tab` was sourced and inert.** Without `zstyle ':completion:*' menu
  no`, zsh's own menu selection owns the completion UI and fzf-tab is never
  invoked. It is cloned, named first in `plugins=()`, sourced, working, and
  never reached — naming it in the plugin list was never enough.

  The fragment now writes that, the `fzf-tab:*` settings, `list-colors`, and
  binds Tab to `fzf-tab-complete` — guarded on the widget existing, so a failed
  clone leaves Tab doing the normal thing rather than nothing.

- **`history-substring-search` was bound only for terminfo sequences.** Unlike
  macOS, this one is *not* broken: Linux uses the plugin oh-my-zsh bundles,
  which does bind keys. But it binds `$terminfo[kcuu1]`/`kcud1` only, so a
  terminal outside application cursor mode sends the raw escape and reaches
  nothing — the "works locally, not over SSH" report. Both spellings are now
  bound, plus vi `k`/`j`, guarded on the widget.

- **`alias find="fd"` tested an alias, not a binary.** Added in the same pass
  as the macOS one, and initially placed after `alias fd="fdfind"` — which
  makes `command -v fd` succeed on a box with no `fd` binary at all. It would
  have worked, since zsh expands an alias to an alias, but by accident. The
  `find` pair is now emitted before the `fd` alias.

- **Insecure completion directories.** zsh treats a group- or world-writable
  `fpath` entry as untrusted and oh-my-zsh responds by loading **no**
  completions at all. The trigger differs from macOS, where it is Homebrew
  creating `<prefix>/share` group-writable: here the directories are clones in
  `$HOME`, so the cause is the umask that made them — a 002 umask with
  `USERGROUPS_ENAB` makes every directory git creates group-writable.

  A new `completion perms` step chmods `g-w,o-w` on the oh-my-zsh directories
  and cloned plugins, including `zsh-completions/src`, which is the path
  actually added to `fpath`. Only what is on `fpath` is touched.

### Added

- **The powerlevel10k instant prompt**, at the top of the fragment. It was
  never emitted, so the headline feature of the theme this script clones was
  off unless you had written the block yourself.

  It only works if it runs before everything else, so the script now reports
  `zshrc hook order` when the `source` line has executable code above it. It
  does not rewrite `~/.zshrc` to fix that — that file is the user's. The check
  matches a line that actually sources the fragment, not any mention of it.

- **`~/.p10k.zsh` is sourced** after oh-my-zsh. Without it powerlevel10k runs
  its configuration wizard on every new shell until you answer it, and then the
  answers it writes are never read back.

- **`alias find="fd"`/`fdfind`**, which was the one member of the cli bundle
  with no `find`-shaped alias.

### Changed

- **`cat` and `ls` aliases now behave like the commands they replace.** `bat`
  pages by default and `cat` does not, hence `--paging=never`; `eza --icons`
  emits icons into a pipe where they become mojibake in whatever reads them,
  hence `--icons=auto`, which ties them to stdout being a terminal.

## [1.3.0]

### Changed

- **GIMP comes from Flathub instead of apt**, so it tracks upstream rather than
  whatever the release froze on. Same call the `creative` group already makes
  for Blender, and the numbers make the case rather than the principle: trixie
  ships **3.0.4**, Flathub is on **3.2.4** — a whole minor series ahead.

  The gap widens rather than closes. Debian stable freezes on release: trixie
  will still be on the 3.0 line in two years, taking security fixes and nothing
  else. Bookworm is a major version behind at 2.10.34.

  **You will have two GIMPs until you remove one.** Nothing here uninstalls, so
  a machine that ran an earlier manifest keeps Debian's at `/usr/bin/gimp` —
  two entries in the desktop menu, and `gimp` at a prompt still running the apt
  one because the Flatpak is only on `PATH` via its own exports directory. This
  is the one package in the manifest where leaving the old copy is untidy
  rather than harmless: `sudo apt remove gimp` finishes the move.

## [1.2.0]

### Added

- **A Nerd Font, which powerlevel10k has needed since day one.** The Windows
  manifest has installed Meslo since its first release; this side installed the
  theme that requires it and no font at all, so the prompt rendered as boxes.

  Desktop machines only, and that is not a size argument: the glyphs are drawn
  by the terminal you are typing at. SSH into a headless box from a terminal
  that already has Meslo and the prompt is correct with no font on the server;
  install one there and nothing anywhere looks different.

- **`RELEASES`, a third category of software** alongside apt packages and git
  clones: a single static binary from a GitHub release, into `~/.local/bin`.
  For things that are in neither the Debian archive nor a repository you can
  clone and run.

  Unlike the `TOOLS` clones these are version-checked properly — the binary is
  asked what it is, the newest release tag is fetched, and a run where they
  already agree downloads nothing and says `current`.

- **tflint and terraform-docs**, as the first two `RELEASES` entries. Neither
  is packaged by Debian in any release. They are the Terraform counterpart to
  the `ansible-lint` and `yamllint` pair that was already here.

- **Claude Code**, installed once by Anthropic's script into `~/.local/bin` and
  then left alone, because it updates itself. Reinstalling it every run would
  be the second installer in a fight it cannot win.

- **`~/.local/bin` on PATH in the managed zsh fragment.** The stock `~/.profile`
  on Debian adds it, but zsh never reads `.profile` — so without this the three
  things above install correctly and none of their commands exist.

### Changed

- **btop replaces htop** and **tmux replaces screen** in the `cli` group.

- **`{UNAME_ARCH}` is substituted into release URLs**, alongside the `{ARCH}`
  that was already there. The same machine has two names — dpkg says `amd64`
  and `arm64`, `uname -m` says `x86_64` and `aarch64` — and upstream projects
  are split about evenly over which they name their assets for. Both words are
  now available to a `RELEASES` entry, off one definition that the AWS CLI
  phase shares, so the two phases cannot drift on what the word means.

  Not named `GOARCH`, which was the obvious suggestion and is wrong: Go's own
  `GOARCH` values are `amd64` and `arm64` — the dpkg spelling — so the name
  would have pointed at the wrong one of the two while sounding decisive.

### Fixed

- **The `cli` group installed the wrong `yq`.** Debian's `yq` package is
  kislyuk/yq — the distribution's own description calls it a "jq wrapper for
  YAML documents", a Python script that transcodes YAML and shells out to jq.
  The Windows manifest installs `MikeFarah.yq` and Homebrew's `yq` formula is
  mikefarah's too: the Go program, a different project that answers to the same
  command name.

  That is the whole point of the `cli` group inverted. It exists so muscle
  memory transfers between the three shells, and a simple read is spelled
  identically on both — `yq '.a.b' file` works either way — which is exactly
  what let this survive unnoticed. Everything past a simple read diverges:
  `yq eval`, `-i` in place, `-o=json`. A snippet written on the other two
  platforms failed here in a way that reads like a typo rather than a different
  program.

  `yq` is now a `RELEASES` entry taking mikefarah's static binary, which needed
  no new code — its asset has no extension, and `unpack_asset` already treats
  that shape as a plain binary rather than guessing at an archive.

  **Nothing uninstalls the old one.** A machine that ran an earlier manifest
  keeps Debian's `yq` at `/usr/bin/yq`; it is shadowed rather than removed,
  because the managed zsh fragment prepends `~/.local/bin` to `PATH`. Run
  `sudo apt remove yq` by hand if you would rather not have both on disk.

- **`set -e` inside a subshell used as an `if` condition does nothing**, and
  the first draft of the release-binary downloader relied on it. Bash
  suppresses the abort for the whole condition context, so a failed download
  went on to unpack nothing, find nothing, and report whatever the last command
  thought of being handed an empty path. Both new download paths chain their
  steps with `&&` instead, so the exit status means what it looks like it means.
- A release whose tag moved without its asset changing reported
  `upgraded 0.60.0 -> 0.60.0` — an arrow saying nothing happened in the colour
  that says something did. It reports `current` now.

## [1.1.1]

### Fixed

- **Three lines that claimed a change on every run.** `zsh config`, `apt
  packages` and `flatpak apps` reported `installed` or `upgraded` whether or
  not anything had moved, which is the one thing this output exists to tell
  you apart. A daily unattended run printed the same green lines on the day it
  updated forty packages and on the day it updated none.

  Each now decides the same way the git-clone path already did — look at the
  state, act, look again:

  - `zsh config` renders the fragment to a temp file and compares it with
    `~/.zshrc.bootstrap`. Identical is `current`; different is `upgraded`;
    absent is `installed`.
  - `apt packages` counts what `apt-get --just-print upgrade` would move before
    running anything. Zero is `current`, and the upgrade is not run at all; the
    count is also what the `--dry-run` line reports, from the same function.
  - `flatpak apps` compares the `active` commit of every installed ref before
    and after the update, rather than matching a string in flatpak's output —
    which is localised, and not a stable interface.

## [1.1.0]

### Added

- **Zoom**, as the Flathub reference `us.zoom.Zoom` in the desktop-gated `apps`
  group. Not in the Debian archive, and its own `.deb` is a direct download
  with no repository behind it — so Flathub is the only one of the three
  options that a normal update run would ever keep current.

## [1.0.0]

First release. A Debian-family counterpart to the Windows bootstrap, built on
the same idea: one command that both builds a fresh machine and updates an
existing one, a manifest that says what rather than how, and one printed line
per decision so a run that changes nothing says so.

### Added

- **A desktop check, which is the reason a server and a workstation can share
  one manifest.** Groups marked `GROUP_<name>_GUI=yes` are skipped and reported
  as `no-gui` when the machine has no desktop environment, so Blender and GIMP
  do not drag a large dependency tree onto a box where nobody can open them.

  The two obvious signals are both wrong and neither is used. `$DISPLAY` and
  `$WAYLAND_DISPLAY` describe the *session*, not the machine: they are unset
  when you SSH into your own desktop, set when you SSH into a headless server
  with X forwarding, and WSLg sets both on a WSL install with no desktop at
  all. `systemctl get-default` reports `graphical.target` on that same install.
  Both measured on WSL Ubuntu 24.04.

  So the script asks what is installed instead — a display manager, or session
  `.desktop` files under `/usr/share/xsessions` or
  `/usr/share/wayland-sessions`. Neither appears by accident, and the answer is
  the same over SSH as at the keyboard. `--gui` and `--no-gui` override it.
- **Package groups** from the distribution archive and Flathub: `shell`, `cli`,
  `dev`, `infra`, and the desktop-gated `creative` and `apps`. The CLI bundle
  deliberately matches the Windows manifest so muscle memory transfers between
  the two shells.
- **Third-party repositories**, added properly: each gets its own key
  dearmoured into `/etc/apt/keyrings` and a deb822 `.sources` file with a
  `Signed-By` line scoping that key to that repository. `apt-key`, which trusts
  a key for *every* repository on the system, is not used anywhere. `{ID}` and
  `{CODENAME}` are substituted from `/etc/os-release`, because Docker publishes
  a separate tree per distribution and per release and pointing Ubuntu at the
  Debian one installs packages built against a different libc. Ships VS Code,
  Docker Engine and Unity Hub.
- **Version managers under `$HOME`** — `pyenv`, `pyenv-virtualenv` and `tfenv`
  — as git clones. No root, no third-party apt key, and nothing system-wide to
  conflict with the distribution's own packages. `tfenv` is how Terraform
  arrives without trusting a HashiCorp signing key machine-wide. Upgrades are
  `git pull --ff-only`: a checkout that cannot fast-forward is reported, never
  forced, because it is the user's.
- **.NET SDK** from Microsoft's install script into `$HOME/.dotnet`, tracking
  the same major the Windows manifest installs. Every SDK on disk is reported,
  because `dotnet-install.sh` installs side by side and a channel rollover
  leaves the previous major there forever.
- **zsh** — oh-my-zsh, powerlevel10k and the plugin set, matching the fleet's
  Ansible role so a shell is the same wherever you land. Plugin order is
  load-bearing and the manifest explains why for each of the three constraints.
  Your `.zshrc` is not rewritten: the managed block lives in
  `~/.zshrc.bootstrap` and a single `source` line is appended if absent.
- `--dry-run`, `--groups`, `--list-groups`, `--skip-upgrade`, `--gui`,
  `--no-gui`, `--yes`, `--version`.
- The manifest's required sections are checked at load and in CI, so a section
  that goes missing fails immediately with the file named rather than much
  later with an unbound-variable error naming the consuming line.

### Notes

- **`PKG_GROUPS`, not `GROUPS`.** `GROUPS` is a bash builtin holding the
  current user's group IDs, so assigning to it silently does nothing. The first
  version of this manifest did exactly that and the run reported groups called
  `1000` and `27`.
- **`fd-find` installs as `fdfind` and `bat` as `batcat`** on Debian, which
  renames both to dodge a clash with older archive packages. The managed zsh
  fragment aliases them and guards each on `command -v`, because a blind alias
  to a missing binary breaks the normal command entirely.
- A package the release does not carry — `eza` on bookworm, for instance — is
  reported as `missing` rather than failing the run.
