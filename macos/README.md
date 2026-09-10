# bootstrap.sh

Installs and updates a Mac's software from a manifest.

One command does both jobs. On a fresh machine it installs everything; on a
machine that already has it, it takes the updates.

```bash
./bootstrap.sh --dry-run     # show what would change, touch nothing
./bootstrap.sh               # do it
```

**Do not run it with `sudo`.** This is the inverse of the Linux script, which
calls `sudo` for the steps that need root. Homebrew refuses to operate as root,
and a run that got far enough as root would leave root-owned files in the brew
prefix and in your home directory that later normal runs cannot write. The
script checks and refuses. The one place a password is unavoidable is
Homebrew's own first-time installer, which needs it to create the prefix.

## The Homebrew prefix, and why `uname -m` is not enough

Homebrew lives at a different path per architecture — `/opt/homebrew` on Apple
silicon, `/usr/local` on Intel — and everything downstream depends on getting
that right. Install into the wrong one and there is no error: you get a second,
parallel Homebrew that the shell never picks up, and a `brew list` that
disagrees with what is on your PATH.

The obvious way to ask is `uname -m`, and on its own it lies:

| Signal | Why it lies |
|---|---|
| `uname -m` | Reports `x86_64` on an Apple silicon Mac whenever the process is running under Rosetta — an Intel binary, a Terminal with *Open using Rosetta* ticked, or an `arch -x86_64 zsh` somewhere in your shell history. That is what a translated process is entitled to believe. |
| `$(arch)` | Same problem, same reason. |

So the script asks the kernel instead. `sysctl -n sysctl.proc_translated`
returns `1` when *this* process is being translated, and is absent on a real
Intel Mac — so a missing value and a `0` both mean native. `arm64`, or `x86_64`
plus translation, means Apple silicon and `/opt/homebrew`.

Run it from a Rosetta shell and it says so, then targets the native prefix
anyway:

```
  arch            arm64  (Apple silicon, seen through Rosetta)
  note            this shell is running under Rosetta - targeting the native prefix anyway
```

This is the same class of bug as the Linux script's desktop check: a signal
that describes *the current process* being read as if it described *the
machine*.

## Desktop software

Groups marked `GROUP_<name>_GUI=yes` in the manifest are skipped by `--no-gui`,
so a headless build agent does not get Zoom and Docker Desktop.

Unlike the Linux script, this is **not auto-detected**, and that is the honest
answer rather than a missing feature. Linux can ask whether a display manager
or any session files are installed, and a machine with none of them genuinely
cannot start a desktop. Every Mac can — the window server is part of the OS.
The signals that do differ between a laptop and a rack-mounted mini (whether
anyone is logged in at the console, whether `$SSH_CONNECTION` is set) all
describe the session rather than the machine, which is exactly the mistake the
Linux check exists to avoid. So it defaults to on and takes an override.

Groups are kept **homogeneous** for the same reason: the flag skips a whole
group, so putting Docker Desktop in with `yamllint` would take the linters down
with it on a headless run.

## What it does

1. **Preflight** — architecture and prefix, Xcode Command Line Tools, and
   Homebrew itself, installed non-interactively if it is not there.
2. **Taps** — third-party Homebrew repositories from the manifest. Empty as
   shipped; the mechanism is there so adding one is a manifest edit.
3. **Package groups** — formulae and casks, with GUI groups gated on `--no-gui`.
4. **Upgrades** — `brew upgrade` for formulae and casks, but only when
   something is actually outdated.
5. **Tools** — empty here. `pyenv`, `pyenv-virtualenv`, `tofuenv` and `nvm` are
   Homebrew formulae in the `dev` group, not git clones under `$HOME` the way
   the Linux script installs them.
6. *(no .NET phase — the `dotnet-sdk` cask covers it, in the `dev` group.)*
7. **zsh** — oh-my-zsh, powerlevel10k and the plugins, plus a managed
   `~/.zshrc.bootstrap` fragment sourced from your own `.zshrc`.

Claude Code has no phase of its own here: Homebrew carries it as the
`claude-code` cask, so it is installed and kept current by the package groups
like anything else brew owns. The Linux script uses Anthropic's install script
instead, because it is not in the Debian archive.

## Options

```
--dry-run          Show what would change, touch nothing.
--groups a,b       Limit to named groups. Default is every group.
--list-groups      Print the groups in the manifest and exit.
--skip-upgrade     Install what is missing, leave installed versions alone.
--gui / --no-gui   Whether to install groups that need a desktop. Default is
                   --gui; use --no-gui on a headless build agent.
--version          Print the version and exit.
```

There is no `--yes`. Homebrew does not prompt for confirmation on an install,
so there is nothing to answer.

## The manifest

`packages.conf` is sourced as bash, so it can use arrays and comments freely.
Software is sorted by **who owns it**, the same way the Windows and Linux
manifests sort it, because that is the distinction that matters when an update
goes wrong:

| | installed | upgraded |
|---|---|---|
| `GROUP_*_FORMULA` | yes | yes, `brew upgrade --formula` |
| `GROUP_*_CASK` | yes, unless the app is already there | yes, `brew upgrade --cask` |
| `TAPS` | yes | n/a |
| `TOOLS` | yes, git clone into `$HOME` | yes, `git pull --ff-only` |
| `HELD` | no | no |
| `MANUAL` | no | no |

A **tap** looks like a one-word command and is the same class of decision as
trusting an apt signing key: it is a git repository of build recipes, and once
tapped it can define what `brew install <name>` does. The shipped `TAPS` list
is empty because homebrew/core and homebrew/cask cover everything here.

### Formulae and casks are looked up separately

Never with a bare `brew list`. The same name can be both, and `docker` is the
example that bites: the **formula** is the CLI client on its own with no engine
behind it, and the **cask** `docker-desktop` is the engine and the app.
Install the formula when you wanted Desktop and you get a working `docker`
command that cannot reach a daemon — and a check that does not say which kind
it means will report one as installed when the other is.

### Two names worth knowing

**GNU make arrives as `gmake`.** `/usr/bin/make` is BSD make, and Homebrew will
not shadow a system binary, so the formula installs under a different name.
This is the macOS counterpart to Debian's `fdfind` and `batcat`. The managed
zsh fragment aliases `make` to it, guarded on `command -v`; `/usr/bin/make` is
still there under its full path if you need BSD make.

**`bat` is `bat` and `fd` is `fd`.** Homebrew does *not* rename them the way
Debian does, so the fragment is simpler here than the Linux one. It still
guards every alias on `command -v`, because the same fragment has to work on a
machine where one of those installs failed.

### Casks that update themselves

Some casks — VS Code, Docker Desktop, Chrome — declare `auto_updates` and keep
themselves current. `brew outdated --cask` deliberately leaves them out, and
this script deliberately does **not** pass `--greedy`, which would make
Homebrew download and reinstall an app that has already updated itself. That is
two installers fighting over one `.app`, and the visible symptom is a large
download on every single run for something that was never out of date.

They are named in the output instead, so it is clear Homebrew is not the thing
keeping them current:

```
  present       self-updating casks    visual-studio-code docker-desktop - left to their own updaters
```

An app already in `/Applications` that Homebrew did not put there is reported
as `present` and left alone, for the same reason.

## zsh

macOS has shipped zsh as the default login shell since Catalina, so unlike the
Linux script there is nothing to install and no `chsh` to run — the system zsh
is reported and used as-is. Homebrew's zsh is deliberately not in the manifest:
installing it gives you a second zsh that a login shell will not use.

The rest matches the Linux setup, so a shell is the same wherever you land:
oh-my-zsh, powerlevel10k, and the plugin list in the manifest.

Plugin **order** is load-bearing, not alphabetical:

- `zsh-syntax-highlighting` must be last but one. It wraps ZLE widgets, and
  anything sourced after it defines widgets outside that wrapping.
- `history-substring-search` is the documented exception and goes after it.
- `fzf-tab` must load after `compinit` but before anything that wraps ZLE
  widgets, which makes first the only position that satisfies it.

Two entries differ from the Linux list, both because of the platform:
`command-not-found` is dropped (it wraps Debian's handler and does nothing
here), and `macos` is added.

Your `.zshrc` is not rewritten. The managed block lives in
`~/.zshrc.bootstrap`, rendered to a temp file and compared before it is
replaced — so a run that changes nothing reports `current` rather than claiming
an install. A single `source` line is appended to `.zshrc` if it is not already
there.

The fragment puts `brew shellenv` first and unconditionally. Nothing below it
can find a Homebrew-installed binary until the prefix is on PATH, and on a
first run the calling shell has never read a profile since Homebrew appeared.

## Releases

All three platforms ship in **one** GitHub release, tagged `vX` — the tag names
the bundle, not a version. Each platform still versions independently, so a
release states which version of each is inside, and this one's number lives in
`BOOTSTRAP_VERSION` in `bootstrap.sh` with its notes in `CHANGELOG.md`.

The release workflow refuses to publish if any platform's current version has
no matching changelog section, if any shipped script fails to parse, or if
shellcheck complains.
