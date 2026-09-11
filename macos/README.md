# bootstrap.sh

Installs and updates a Mac's software from a manifest. One command does both.

```bash
./bootstrap.sh --dry-run     # show what would change, touch nothing
./bootstrap.sh               # do it
```

**Do not run it with `sudo`.** Homebrew refuses to operate as root, and a run
that got far enough would leave root-owned files that later runs cannot write.
The script checks and refuses. Homebrew's own first-time installer is the one
place a password is needed.

The prefix is chosen from `sysctl -n sysctl.proc_translated`, not `uname -m`,
which reports `x86_64` on Apple silicon under Rosetta.

## What it does

1. **Preflight** — architecture and prefix, Xcode Command Line Tools, Homebrew.
2. **Taps** — third-party Homebrew repositories from the manifest. Empty as shipped.
3. **Package groups** — formulae and casks, GUI groups gated on `--no-gui`.
4. **Upgrades** — `brew upgrade`, only when something is outdated.
5. **zsh** — oh-my-zsh, Starship and plugins, plus a managed
   `~/.zshrc.bootstrap` sourced from your own `.zshrc`.
6. **Prompt config** — `starship.toml` from the repo root to
   `~/.config/starship.toml`, the same file all three platforms deploy.

`pyenv`, `pyenv-virtualenv`, `tofuenv`, `nvm`, `dotnet-sdk` and `claude-code`
are Homebrew packages here, not separate phases as on Linux.

## Options

```
--dry-run          Show what would change, touch nothing.
--groups a,b       Limit to named groups. Default is every group.
--list-groups      Print the groups in the manifest and exit.
--list-packages    Print every package name in every group and exit.
--skip-upgrade     Install what is missing, leave installed versions alone.
--gui / --no-gui   Whether to install groups that need a desktop. Default --gui.
--version          Print the version and exit.
```

`tools` is a zsh function written into the managed fragment: the `cli` group as
of the last run, with what to type and what it does.

## The manifest

`packages.conf` is sourced as bash. Software is sorted by who owns it:

| | installed | upgraded |
|---|---|---|
| `GROUP_*_FORMULA` | yes | yes, `brew upgrade --formula` |
| `GROUP_*_CASK` | yes, unless the app is already there | yes, `brew upgrade --cask` |
| `TAPS` | yes | n/a |
| `TOOLS` | yes, git clone into `$HOME` | yes, `git pull --ff-only` |
| `HELD` | no | no |
| `MANUAL` | no | no |

Formulae and casks are looked up separately, never with a bare `brew list`: the
same name can be both. `docker` the formula is the CLI alone; `docker-desktop`
the cask is the engine.

Casks that declare `auto_updates` (VS Code, Docker Desktop, Chrome) are left to
their own updaters — no `--greedy` — and reported as self-updating. An app in
`/Applications` that Homebrew did not install is reported `present` and left
alone.

GNU make installs as `gmake`, since Homebrew will not shadow `/usr/bin/make`;
the zsh fragment aliases `make` to it. `bat` and `fd` keep their own names here,
unlike Debian.

## zsh

The system zsh is used as-is — macOS has shipped it as the login shell since
Catalina, and Homebrew's zsh is deliberately not in the manifest.

Plugin order is load-bearing: `zsh-syntax-highlighting` last but one,
`history-substring-search` after it, `fzf-tab` first (after `compinit`, before
anything that wraps ZLE widgets).

Your `.zshrc` is not rewritten. The managed block lives in
`~/.zshrc.bootstrap`, compared before it is replaced, with one `source` line
appended to `.zshrc` if absent. `brew shellenv` comes first in the fragment.

## Releases

All three platforms ship in one GitHub release tagged `vX`; each versions
independently. This one's number is `BOOTSTRAP_VERSION` in `bootstrap.sh`, with
notes in `CHANGELOG.md`. The release workflow refuses to publish if the current
version has no changelog section, a script fails to parse, or shellcheck
complains.
