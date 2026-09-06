# Changelog

Versions of `macos/bootstrap.sh` and the manifest it reads.

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

## [1.1.0]

### Changed

- **pyenv, pyenv-virtualenv, tfenv and nvm are Homebrew formulae**, not git
  clones under `$HOME`. `TOOLS` is now empty on macOS, and the four moved into
  the `dev` group where brew version-checks, upgrades and reports them with
  everything else.

  What it costs is worth naming: `$HOME/.pyenv` is the same path on Linux and
  macOS, so the two managed fragments used to say the same thing about it and
  no longer do. What it buys is one owner and one upgrade transaction instead
  of four `git pull`s that can each fail differently.

  None of the four needs a `PATH` line any more — `brew shellenv` already puts
  them in front. The Linux fragment still prepends `$HOME/.pyenv/bin` and
  `$HOME/.tfenv/bin`, because there they really are clones.

- **`pyenv virtualenv-init` is now run**, which the clone-based setup never
  did. Without it the plugin is installed and inert: `pyenv virtualenv` still
  creates environments and none of them ever activate on `cd`.

### Fixed

- **nvm would have broken silently under Homebrew**, and avoiding that is why
  the `nvm` oh-my-zsh plugin is no longer in the macOS plugin list.

  The plugin only falls back to a Homebrew nvm when `NVM_DIR` is *empty*, and
  when it does it points `NVM_DIR` at the Cellar — which is exactly the
  configuration Homebrew's own caveat warns "will destroy any nvm-installed
  Node installations upon upgrade/reinstall", because `brew upgrade nvm`
  replaces that directory wholesale. Set `NVM_DIR` correctly instead and the
  plugin finds no `nvm.sh` there and quietly does nothing at all.

  So the fragment splits the two halves by hand, as Homebrew documents:
  `NVM_DIR` at `~/.nvm` for the data, `nvm.sh` sourced from the brew prefix.
  The lazy loading the plugin provided is written out explicitly rather than
  lost — stubs for `nvm`, `node`, `npm` and `npx` that replace themselves on
  first use, so a shell that never runs node still starts instantly.

- **The .NET SDK is the `dotnet-sdk` cask**, not Microsoft's install script
  into `$HOME/.dotnet`. The phase is gone, `DOTNET_ENABLED`, `DOTNET_CHANNEL`
  and `DOTNET_DIR` with it, and so are the fragment's `PATH` and `DOTNET_ROOT`
  exports — the cask installs to `/usr/local/share/dotnet` and links `dotnet`
  and `dnx` from a directory already on `PATH`, so there is nothing left for
  the shell to arrange.

- **The zsh theme and the four add-on plugins are Homebrew formulae** rather
  than git clones into oh-my-zsh's custom directory. `ZSH_CUSTOM_PLUGINS` is
  now empty and `ZSH_THEME` is now blank; nothing is cloned on macOS at all.

  Both blanks are load-bearing rather than tidy. oh-my-zsh resolves a name in
  `plugins=()` and `ZSH_THEME` against its own directories only, so naming a
  brew-installed plugin there finds nothing, and naming the theme there makes
  oh-my-zsh report it missing and fall back to its default. They are sourced by
  path after `oh-my-zsh.sh` instead.

  **The ordering rules moved with them.** They used to be encoded in the order
  of `ZSH_PLUGINS`; nothing enforces them now except the fragment, so they are
  written where the sourcing happens: `fzf-tab` after compinit, then
  autosuggestions, then `zsh-syntax-highlighting` last but one because it wraps
  every ZLE widget in existence when it loads, then history-substring-search,
  the documented exception that must follow it.

  `zsh-completions` is the odd one and goes the other way: it ships completion
  functions rather than a script to source, so its directory joins `fpath`
  *before* `oh-my-zsh.sh` runs compinit. Adding it afterwards is the classic
  way to install it and see no new completions at all.

- **The `fzf-tab` path is `fzf-tab.zsh`, not `fzf-tab.plugin.zsh`.** Upstream
  names it the second way and so does every oh-my-zsh guide; the Homebrew
  formula installs the first. The wrong name fails the readability guard and
  loads nothing, silently — the same shape as every other bug in this release.

### Notes

- **oh-my-zsh itself is the one thing here not from Homebrew**, and not by
  choice: there is no formula for it, so the framework is still installed by
  its own script. Everything that plugs into it now comes from brew.

- **helm is 4.2.4 on all three platforms** — winget `Helm.Helm`, the `helm`
  formula, and the Linux `RELEASES` entry that tracks the newest tag. No pin
  was needed; all three were already there.

## [1.0.0]

First release. A Homebrew counterpart to the Windows and Linux bootstraps,
built on the same idea: one command that both builds a fresh machine and
updates an existing one, a manifest that says what rather than how, and one
printed line per decision so a run that changes nothing says so.

### Added

- **An architecture check that survives Rosetta, which is the reason the
  Homebrew prefix is ever right.** Homebrew lives at `/opt/homebrew` on Apple
  silicon and `/usr/local` on Intel, and installing into the wrong one produces
  no error — just a second, parallel Homebrew the shell never picks up.

  `uname -m` is the obvious signal and it lies: under Rosetta it reports
  `x86_64` on an Apple silicon Mac, because that is what a translated process
  is entitled to believe, and a Terminal with *Open using Rosetta* ticked is
  enough to trigger it. `sysctl -n sysctl.proc_translated` is asked instead —
  the kernel sets it to `1` when this process is translated, and it is absent
  on a real Intel Mac, so a missing value and a `0` both mean native. A run
  from a Rosetta shell says so and targets the native prefix anyway.

- **Formulae and casks looked up separately, never with a bare `brew list`.**
  The same name can be both. `docker` is a formula — the CLI client on its own,
  with no engine behind it — and `docker-desktop` is the cask with the engine
  and the app. A check that does not say which kind it means reports one as
  installed when the other is, and the symptom is a working `docker` command
  that cannot reach a daemon.

- **`--no-gui`, as a flag rather than a probe.** Groups marked
  `GROUP_<name>_GUI=yes` are skipped for a headless build agent. This is
  deliberately not auto-detected the way the Linux script detects a desktop:
  every Mac has a window server, and the signals that do differ — a console
  user, `$SSH_CONNECTION` — describe the session rather than the machine, which
  is the exact mistake the Linux check exists to avoid. Groups are kept
  homogeneous so the gate cannot take the linters down with Docker Desktop.

- **A refusal to run as root.** The inverse of the Linux script, which calls
  `sudo` for the steps that need it. Homebrew refuses to operate as root, and a
  run that got far enough would leave root-owned files in the prefix and in
  `$HOME` that later normal runs cannot write.

- **Upgrades that report what actually moved.** `brew upgrade` exits 0 whether
  it moved forty packages or none, so `brew outdated` is asked first and the
  count is both the decision and the detail printed. Nothing outdated means
  `current`, and the upgrade is not run at all.

- **No `--greedy` on cask upgrades, on purpose.** Casks that declare
  `auto_updates` — VS Code, Docker Desktop, Chrome — keep themselves current,
  and `--greedy` makes Homebrew download and reinstall them on top of an app
  that has already updated itself. That is two installers fighting over one
  `.app`, and the visible symptom is a large download on every run for
  something that was never out of date. They are named in the output instead.
  An app already in `/Applications` that Homebrew did not put there is likewise
  reported as `present` and left alone.

- **The managed zsh fragment, compared before it is replaced.** oh-my-zsh,
  powerlevel10k and the plugin list, written to `~/.zshrc.bootstrap` and
  sourced from a `.zshrc` this script never rewrites. The fragment is rendered
  to a temp file beside the target and compared, so a run that changes nothing
  reports `current` rather than claiming an install.

  `brew shellenv` goes first and unconditionally: nothing below it can find a
  Homebrew-installed binary until the prefix is on PATH, and on a first run the
  calling shell has not read a profile since Homebrew appeared.

- **Xcode Command Line Tools checked, never installed by force.**
  `xcode-select --install` opens a modal dialog and waits for a human, which
  would hang an unattended run with no output explaining why. Homebrew's own
  installer brings them in, so the check only has to be fatal when Homebrew is
  already present.

- **The Meslo Nerd Font**, which powerlevel10k needs and which the Windows
  manifest has installed since its first release. Without it the prompt is not
  merely plain — it is boxes, because p10k draws from the private-use area.

- **Ghostty as the terminal.** Windows gets Windows Terminal and a merged
  settings file; macOS was being left with Terminal.app. Ghostty over iTerm2
  because its config is a plain text file this script could manage the same way
  it manages the zsh fragment, where iTerm2 keeps its settings in a plist.

  Worth knowing before you SSH anywhere: ghostty sets `TERM=xterm-ghostty`, and
  a Debian box that has never heard of that terminfo entry will complain until
  you use ghostty's SSH integration or force `TERM=xterm-256color`.

- **Claude Code**, as the `claude-code` cask in the `dev` group — not the
  vendor script the Linux side uses. Homebrew carries it, so it is installed,
  version-checked and reported by the phase that already does that for every
  other package, rather than by a phase of its own that could only ever say
  `present`.

  The "two installers fighting" objection does not apply here the way it first
  appears. Claude Code still updates itself, and `brew upgrade` is not greedy —
  this script never passes `--greedy`, which is the flag that would let brew
  reach past a self-updating package and stamp on it. So brew installs it once
  and then defers, which is exactly what the hand-rolled phase was doing.

- **tflint and terraform-docs**, the Terraform counterpart to the `ansible-lint`
  and `yamllint` pair.

### Notes

- **Three names in this manifest were wrong, and all three were found by
  machine rather than by a failed install.** `verify-manifests.yml` checks every
  formula and cask against the Homebrew index, and its first run caught:

  - `google-cloud-sdk` → **`gcloud-cli`**. The cask was renamed and the old
    token resolves to nothing.
  - `mpv` → **`stolendata-mpv`**. Also renamed. Homebrew records this in the
    cask's `old_tokens`, which is how the new name was recovered rather than
    merely the absence noticed.
  - `tflint` is **not in homebrew-core at all** and needs the
    `terraform-linters/tap` now declared in `TAPS`. Without it the infra group
    failed with "No available formula".

  Each was a `brew install` that could only ever fail. The check reads the
  whole index once instead of asking per name, which is what lets it tell a
  rename from a disappearance — and what stops it calling `python3` and
  `sqlite3` bugs, since both are aliases with no page of their own.

- **GNU make installs as `gmake`.** `/usr/bin/make` is BSD make and Homebrew
  will not shadow a system binary, so the formula lands under a different name
  — the macOS counterpart to Debian's `fdfind` and `batcat`. The managed zsh
  fragment aliases `make` to it, guarded on `command -v`.
- **`bat` and `fd` keep their real names**, unlike on Debian, so the fragment
  is simpler here. Every alias is still guarded, because the same fragment has
  to work on a machine where one of those installs failed.
- **Temurin rather than the `openjdk` formula.** `openjdk` is keg-only on
  macOS: it installs where `/usr/libexec/java_home` cannot see it, and
  Homebrew's own caveat tells you to finish the job with a `sudo` symlink. The
  cask puts a real JDK bundle where every Java launcher already looks.
- **Ansible is not installed by Homebrew.** It comes from a per-project
  virtualenv instead, so its version is a decision the playbook repository
  makes rather than one brew makes for every project on the machine at once.
  The Linux manifest does install it from the distribution, where it is the
  control node for a fleet — a different job. `ansible-lint` is still here and
  does pull `ansible-core` in behind it; that copy sits in the brew prefix and
  does not shadow a virtualenv, and the manifest says how to drop it too.
- **No creative group**, and no Telegram, qBittorrent or Unity Hub. The Linux
  manifest carries a creative group for Blender, GIMP, Inkscape and OBS, plus
  those three elsewhere; this one carries none of them.
- **Homebrew's zsh is not in the manifest.** macOS has shipped zsh as the
  default login shell since Catalina, and installing a second one that a login
  shell will not use without `chsh` is worse than useless. The system zsh is
  reported and used as-is.
