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

## [1.18.0]

### Added

- **`tools` now shows what to actually type and what it does, for the `cli`
  group.** Requested directly. Sourced from `tools/cli-parity.conf`'s new
  `cmd`/`desc` columns, matched by the exact Homebrew formula/cask name.
  Everything outside `cli` is unaffected - a formula or cask name already
  is the run command for the rest of the manifest, or is not a CLI thing
  at all. Same change in windows/CHANGELOG.md and linux/CHANGELOG.md.

## [1.17.0]

### Added

- **`tools`, a shell function always available at a prompt, no repo needed.**
  Same muscle-memory idea as `cat`/`ls`/`find`/`grep` above: baked directly
  into the managed `.zshrc` fragment on every run, from `packages.conf` as
  of that run. Stale exactly the way the other aliases are if the manifest
  changes and this script does not run again - `--list-packages` is the
  live version for when that matters. Same command in windows/CHANGELOG.md
  and linux/CHANGELOG.md.

## [1.16.0]

### Added

- **`--list-packages`, printing every package name in every group and
  exiting without touching anything.** Requested directly: the manifest
  has grown past the point of remembering what is in it. `--list-groups`
  still gives the short, count-only version. Same flag added in
  windows/CHANGELOG.md and linux/CHANGELOG.md.

## [1.15.0]

### Added

- **`du`/`df` aliases in the zsh fragment, to `dust`/`duf`.** Same
  muscle-memory idea as cat/ls/find/grep above, requested explicitly rather
  than assumed - dust prints a tree with bars and duf a table with
  different columns, so neither is a drop-in for a script parsing
  traditional du/df output; that script should keep calling the real
  binary. Same pair added in windows/CHANGELOG.md and linux/CHANGELOG.md.

### Fixed

- **The DBeaver Community comment overstated what it covers.** It has no
  driver at all for MongoDB, Cassandra, Redis or InfluxDB - those need the
  paid Lite/Enterprise/Ultimate editions - rather than a limited one.
  Comment corrected; same fix in windows/CHANGELOG.md and
  linux/CHANGELOG.md.

## [1.14.0]

### Added

- **`lnav` in the `cli` group.** Log file navigator - auto-detects format
  and timestamps, highlights ERROR/WARN levels. Same addition in
  windows/CHANGELOG.md and linux/CHANGELOG.md; `tools/cli-parity.conf`
  updated to match.

## [1.13.0]

### Added

- **`fx` in the `cli` group.** Interactive JSON viewer/processor - macOS
  only, since it has no winget package and is not in the Debian archive.
  `tools/cli-parity.conf` records the gap.

## [1.12.0]

### Removed

- **`sd`, `hyperfine`, `fastfetch` and `direnv`, all reverting 1.11.0.**
  Added without asking first; taken back out at the user's request rather
  than kept because they happened to already be there. The direnv hook in
  the zsh fragment is removed with it. Same reversion in
  windows/CHANGELOG.md and linux/CHANGELOG.md.

## [1.11.0]

### Added

- **`sd`, `hyperfine` and `fastfetch` in the `cli` group.** A sed
  alternative, a benchmarking tool, and a fast neofetch replacement -
  neofetch itself has been unmaintained since 2024.
- **`direnv` in the `cli` group, hooked in the zsh fragment** next to
  zoxide (`eval "$(direnv hook zsh)"`), not just installed - per-directory
  environment variables need the shell hook to do anything.

Same additions land in windows/CHANGELOG.md and linux/CHANGELOG.md;
`tools/cli-parity.conf` updated to match.

## [1.10.0]

### Added

- **`procs`, `dust`, `duf` and `glow` in the `cli` group.** Modern
  replacements for `ps`, `du`, `df`, and a markdown reader for the
  terminal - same "modern CLI bundle" as bat/eza/fd. Same four land in
  windows/CHANGELOG.md and linux/CHANGELOG.md; `tools/cli-parity.conf`
  updated to match.

## [1.9.0]

### Added

- **`dbeaver-community` in the `apps` group.** A DB client, fully open
  source rather than a free tier of a paid app like TablePlus. Added to
  all three manifests - see windows/CHANGELOG.md and linux/CHANGELOG.md.

## [1.8.0]

### Added

- **`bruno` in the `apps` group.** An API client, chosen over Postman:
  collections are plain-text files that diff in git, not a vendor account.
  Added to all three manifests - see windows/CHANGELOG.md and
  linux/CHANGELOG.md.

### Changed

- **`tofuenv` in the `dev` group, replacing `tfenv`.** Manages OpenTofu
  instead of Terraform - HashiCorp's 2023 BSL relicensing and its 2025
  acquisition by IBM pushed this manifest to the open fork. `tofu` on PATH
  instead of `terraform`. Same swap in windows/CHANGELOG.md and
  linux/CHANGELOG.md.

## [1.7.0]

### Added

- **`~/.zshenv`, so Homebrew is on PATH in non-interactive shells.** The two
  places this script put `brew shellenv` both miss the case: `~/.zprofile` runs
  for login shells only, and the `~/.zshrc.bootstrap` fragment for interactive
  ones. `.zshenv` is the only file zsh reads on *every* invocation, so without
  it `zsh -c 'bat file'` - and anything an editor, a GUI app, or a coding agent
  spawns to run one command - started with no Homebrew prefix on PATH and
  failed on binaries the manifest had installed. The symptom is easy to
  misread, because the aliases survive: the fragment defines `cat` as `bat
  --paging=never` behind a `command -v bat` guard, so a shell that loaded the
  rc and then had PATH replaced keeps an alias pointing at a binary it can no
  longer resolve.

  Written as `~/.zshenv.bootstrap` plus a source line in `~/.zshenv`, the same
  fragment-and-hook shape as `.zshrc`, so an existing `.zshenv` is left alone.
  The fragment holds `brew shellenv` and nothing else on purpose: `.zshenv` is
  read by scripts too, so anything that prints there corrupts their output and
  anything slow is paid for by every zsh. The `.zprofile` line stays - shellenv
  prepends, so a login shell re-asserts the prefix ahead of anything that
  reordered PATH, and the duplicate entry is one modern shellenv dedupes.

## [1.6.0]

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

## [1.5.0]

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

### Added

- **The ghostty config is more than one line now.** `scrollback-limit` was all
  it had, which meant every other decision - font, palette, Option-key
  handling, window state - was ghostty's default rather than this manifest's.
  Seven new knobs, each in the manifest with a paragraph of why, rendered into
  `~/.config/ghostty/config` the same way scrollback already was.

  - `theme = Catppuccin Mocha`. A name that matches a row from
    `ghostty +list-themes`; ghostty ships 463 of them, so changing palette is
    a one-line edit to the manifest and nothing else. Ghostty's own default
    on macOS is a plain dark; Catppuccin Mocha is the widely used dark across
    dev tooling in 2026.
  - `font-family = MesloLGM Nerd Font Mono`. The Meslo Nerd Font this
    manifest has installed since the first release, matched by its face-table
    name (spaces) rather than the ttf filename. Ghostty's default is empty
    which falls back to SF Mono, so p10k's glyphs were rendering from a
    different font than the one the manifest ships.
  - `font-size = 16`. Ghostty's default is 13; 16 matches the iTerm2 profile
    this manifest replaces and is comfortable at a normal seating distance
    on a Retina display.
  - `macos-option-as-alt = true`. Option-f/b/arrows produce the word-wise
    escape sequences readline, zsh and vim recognise. macOS's default keeps
    the typographic bindings (Option-e for é, and the rest), which nobody
    uses at a terminal - the shortcut half of that keyboard is what
    everything on the command line actually uses.
  - `window-save-state = always`. Restores tabs and splits across a plain
    Cmd-Q and relaunch. The default `default` only restores when the OS asks
    (login-item restart, or a reboot with "Reopen windows" ticked); it drops
    the state on a hand quit, which is the case anyone not running tmux was
    silently losing.
  - `copy-on-select = clipboard`. Selecting text puts it on the clipboard
    Cmd-V pastes from. **Not `true`**, which Ghostty documents as valid and
    is not the same thing - `true` copies to the X11-style primary selection,
    a separate buffer on macOS that nothing reaches with Cmd-V. The trade-off
    is a stray selection replaces whatever was on the clipboard.
  - `quit-after-last-window-closed = true`. Match CLI-tool convention. macOS's
    default is to keep the app alive with no visible window, which is right
    for a mail client and wrong for a terminal - the Dock icon lingers and
    Cmd-Q is the only way out.
  - `shell-integration-features = cursor,sudo,title,ssh-env,ssh-terminfo`.
    Ghostty auto-installs the shell hooks; this opts INTO the extras.
    `cursor` follows zsh vi-mode with a bar/block change, `sudo` preserves
    the prompt state through sudo, `title` keeps the terminal title tracking
    cwd. `ssh-env` carries `TERM=xterm-ghostty` and `COLORTERM=truecolor`
    through ssh, and `ssh-terminfo` pipes `infocmp -x xterm-ghostty` through
    `tic -x -` on the remote on first connect - installing the entry under
    the remote user's `~/.terminfo`, cached locally afterwards. Together
    they solve the caveat this manifest carried in a comment since 1.0.0:
    "a Debian box that has never heard of that terminfo entry will complain
    until you use ghostty's SSH integration or force TERM=xterm-256color."
    The two features go together - adding `ssh-env` alone actually makes
    the problem worse on hosts without the entry, because the remote now
    thinks it can drive an xterm-ghostty it does not understand.
  - `keybind = global:cmd+\`=toggle_quick_terminal`. Quake-style drop-down
    terminal summoned from any app, including full-screen ones. `global:`
    scopes the binding to the OS rather than a ghostty window, so it fires
    even when ghostty is not focused. Blank in the manifest disables it.
  - `window-padding-x = 10`, `window-padding-y = 10`. Ghostty's default 2/2
    is visually cramped at 16pt - the prompt sits right against the frame.

## [1.4.0]

### Removed

- **`zoom` and `stolendata-mpv` are no longer installed.** Neither is wrong to
  want; neither is something a fresh machine needs before its owner asks. `vlc`
  stays and covers the same ground as mpv for the case this manifest is for.

  The comment `stolendata-mpv` carried is kept, moved up to the group preamble
  where it applies to every token rather than to one departed package. The
  lesson is not about mpv: Homebrew renames casks and keeps the old name
  resolving for a while, so a stale token can install a SECOND copy that `brew
  list` reports under a name this file never mentions. `gcloud-cli` was
  `google-cloud-sdk` and does exactly this. Check `old_tokens` before adding a
  cask; CI checks it too.

## [1.3.0]

### Fixed

- **`zsh-history-substring-search` was sourced and inert.** The formula ships
  no keybindings — upstream leaves that to the caller — so the fragment loaded
  it, its widgets were defined, and nothing you pressed ever reached them. The
  fragment now binds up/down and vi `k`/`j`.

  Easy to miss because oh-my-zsh bundles a copy that *does* bind keys: moving
  from the bundled plugin to the newer standalone formula silently turns the
  feature off. Both spellings of the arrow keys are bound — the terminfo
  sequence and the raw escape — because which one a terminal sends depends on
  application cursor mode.

- **`fzf-tab` was sourced and inert for the same class of reason.** Without
  `zstyle ':completion:*' menu no`, zsh's own menu selection owns the
  completion UI and fzf-tab is never invoked. The fragment now writes that,
  the `fzf-tab:*` settings, `list-colors`, and binds Tab to `fzf-tab-complete`
  — guarded on the widget existing, so a failed install leaves Tab doing the
  normal thing rather than nothing.

- **Installing `zsh-completions` could leave you with fewer completions than
  before it.** The fragment puts `<prefix>/share/zsh-completions` on `fpath`,
  which brings it and its parents into oh-my-zsh's startup audit. Homebrew
  creates `<prefix>/share` group-writable, zsh treats a group-writable `fpath`
  entry as untrusted, and oh-my-zsh responds by loading **no** completions at
  all and printing "Insecure completion-dependent directories detected".

  A new `completion perms` step chmods `g-w,o-w` on the affected directories —
  the same fix the formula prints in its own caveat. It is fixed rather than
  reported because this script creates the condition. `brew` may recreate the
  group bit on a later install into `share/`; a re-run puts it back.

### Added

- **The powerlevel10k instant prompt**, at the top of the fragment. It was
  never emitted, so the headline feature of the theme the manifest installs
  was off unless you had written the block yourself.

  It only works if it runs before everything else, so the fragment now reports
  `zshrc hook order` when the `source` line has executable code above it. It
  does not rewrite `~/.zshrc` to fix that — that file is the user's.

- **`~/.p10k.zsh` is sourced** after the theme. Without it powerlevel10k runs
  its configuration wizard on every new shell until you answer it, and then
  the answers it writes are never read back.

- **`alias find="fd"`**, which was the one member of the cli bundle with no
  alias while `bat`, `eza` and `ripgrep` all had one.

### Changed

- **`cat` and `ls` aliases now behave like the commands they replace.** `bat`
  pages by default and `cat` does not, hence `--paging=never`; `eza --icons`
  emits icons into a pipe where they become mojibake in whatever reads them,
  hence `--icons=auto`, which ties them to stdout being a terminal.

  The Linux fragment has the same two aliases and has not been changed.

## [1.2.0]

### Removed

- **`curl` is no longer installed.** Homebrew marks it `keg_only
  :provided_by_macos`, so it is never linked into `<prefix>/bin`. Installing it
  left a newer curl in `<prefix>/opt/curl/bin` that nothing on `PATH` reached,
  and `curl` in a shell stayed the system one — the manifest claimed an upgrade
  it was not delivering.

  `git` stays, and the contrast is the whole point: git is not keg-only, so
  Homebrew's really does shadow `/usr/bin/git`. Same reasoning, opposite answer.

  What is given up is an OpenSSL backend instead of SecureTransport, and
  HTTP/3. A machine that needs either wants `<prefix>/opt/curl/bin` prepended
  in the managed fragment, which is a deliberate change and not a line in an
  array. `bootstrap.sh` still calls the system `curl` to fetch the Homebrew and
  oh-my-zsh installers, which is what it always did — neither can wait for a
  package manager that is not there yet.

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
