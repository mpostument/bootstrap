# Changelog

Versions of `linux/bootstrap.sh` and the manifest it reads.

The version lives in one place, `BOOTSTRAP_VERSION` in `bootstrap.sh`. The
release workflow refuses to publish a tag whose version disagrees with it, and
reads the release notes from the matching section below — so an entry here is
not optional.

Tags are `linux-vX.Y.Z`. The prefix is deliberate: this repository holds more
than one platform, and a bare `vX.Y.Z` would imply all of it had been released
together.

Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/);
versioning is [SemVer](https://semver.org/spec/v2.0.0.html).

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
