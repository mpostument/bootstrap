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
