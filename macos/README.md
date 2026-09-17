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
5. **Housekeeping** — `brew cleanup`, and the formulae `brew autoremove`
   would take, reported and not taken.
6. **zsh** — Starship, completion and the Homebrew zsh plugins, plus a
   managed `~/.zshrc.bootstrap` sourced from your own `.zshrc`.
7. **VS Code extensions** — `VSCODE_EXTENSIONS`, installed with
   `code --install-extension`; never removes one that isn't listed.
8. **Prompt config** — `starship.toml` from the repo root to
   `~/.config/starship.toml`, the same file all three platforms deploy.
9. **bat config** — `bat/config` and the Catppuccin Mocha theme from the repo
   root, the palette starship, ghostty, atuin and delta all render in.
10. **Schedule** — a launchd agent that re-runs all of the above daily.
    Skip with `--skip-schedule`.

`pyenv`, `pyenv-virtualenv`, `tofuenv`, `nvm`, `dotnet-sdk` and `claude-code`
are Homebrew packages here, not separate phases as on Linux.

## Options

```
--dry-run          Show what would change, touch nothing.
--groups a,b       Limit to named groups. Default is every group.
--list-groups      Print the groups in the manifest and exit.
--list-packages    Print every package name in every group and exit.
--status           Print what the last real run did and exit. Exits 1 if that
                   run failed.
--skip-upgrade     Install what is missing, leave installed versions alone.
--skip-cask-upgrade
                   Upgrade formulae but not casks.
--skip-cleanup     Leave stale downloads and superseded versions on disk.
--skip-schedule    Leave the launchd agent alone.
--skip-vscode-extensions
                   Install none of the VS Code extensions in the manifest.
--skip-update-check
                   Don't check the GitHub origin for a newer release tag.
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

**`HELD`** — software another installer owns, reported and never touched. The
macOS counterpart of `Managed` in `windows/packages.psd1`: JetBrains Toolbox
installs and self-updates Rider and DataGrip, and the `rider`/`datagrip` casks
would fight it, so Toolbox is in the `dev` group and the two IDEs are held.

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

## Housekeeping

`brew upgrade` leaves the version it replaced in the Cellar and the bottle it
downloaded in the cache, and neither is read again. `brew cleanup
--prune=$BREW_CLEANUP_PRUNE_DAYS` removes exactly those: versions nothing links
to, and cache entries past that age. On the machine this was written on it had
7.3 GB to reclaim.

`brew autoremove` is printed and never run. It uninstalls formulae it believes
nothing depends on any more, and one installed on purpose as a tool looks
exactly like one orphaned by a dependency change — so the list is yours to act
on. `BREW_CLEANUP_ENABLED=no` turns the phase off; `--skip-cleanup` does it for
one run.

## Schedule

A launchd **user agent**, `~/Library/LaunchAgents/$SCHEDULE_LABEL.plist`,
re-runs this script daily at `SCHEDULE_TIME`. An agent and not a daemon
because this script refuses to run as root, and Homebrew refuses along with
it: the job has to be the uid that owns the prefix.

- A run that came due while the Mac was asleep or off starts once it is awake
  again, so the time is "about then", not exactly.
- The agent passes `--skip-cask-upgrade`. A cask that wants an admin password
  has nowhere to ask for one and would fail every night; formulae, which is
  most of what moves, still upgrade daily, and casks come with the next
  interactive run.
- `PATH` is set in the plist — a launchd job inherits almost nothing — to the
  Homebrew prefix, `~/.local/bin` and the system directories.
- Logs land in `SCHEDULE_LOG_DIR`, one `bootstrap-YYYY-MM-DD.log` per run,
  pruned after `SCHEDULE_KEEP_LOG_DAYS`.
- `SCHEDULE_ENABLED=no` turns it off; `--skip-schedule` skips the phase for
  one run without touching what is already loaded.

```bash
./bootstrap.sh --status                                     # what did the last run do
launchctl print "gui/$(id -u)/com.github.bootstrap.macos"   # is it loaded, and when did it last run
launchctl kickstart -p "gui/$(id -u)/com.github.bootstrap.macos"   # run it now
```

### Did last night's run work?

An unattended run is a run nobody watches, so it leaves two things behind.

**A record**, in `${XDG_STATE_HOME:-~/.local/state}/bootstrap-macos/last-run`:
when, how long, the exit code, the counts, and — the part the log buries — the
id of every step that failed, or the message the run died with. Written from
the `EXIT` trap, so a run that aborts in preflight records that instead of
leaving yesterday's success in place. Dry runs never write it: a dry run is a
question, not an answer.

```console
$ ./bootstrap.sh --status

== Last run ====================================================
  when            2026-09-17 04:20:03  (7h 30m ago)
  trigger         unattended - the launchd agent, or output redirected
  version         v1.36.0
  duration        1m 34s
  result          exit 1
  failed          brew formulae, docker-desktop
  counts          installed=1 upgraded=12 current=109 present=34
  log             ~/Library/Logs/bootstrap-macos/bootstrap-2026-09-17.log
```

It exits 1 when that run failed, so `bootstrap.sh --status` works as a check.

**A notification**, one banner, when an unattended run fails and
`SCHEDULE_NOTIFY_ON_FAILURE=yes`. Only unattended: an interactive run has
already printed the failures in red, and a banner on top of that is noise.
`osascript` is silent where there is no GUI session to post into — over ssh,
say — so nothing breaks there either.

Remove it with `launchctl bootout "gui/$(id -u)/com.github.bootstrap.macos"`
and `rm ~/Library/LaunchAgents/com.github.bootstrap.macos.plist`.

## Releases

All three platforms ship in one GitHub release tagged `vX`; each versions
independently. This one's number is `BOOTSTRAP_VERSION` in `bootstrap.sh`, with
notes in `CHANGELOG.md`. The release workflow refuses to publish if the current
version has no changelog section, a script fails to parse, or shellcheck
complains.

Preflight checks this checkout's own GitHub origin for a newer release tag and
prints one line if it's behind - separate from `BOOTSTRAP_VERSION` above,
which is this script's own number. Silent on a release tarball, a fork, or no
network. `--skip-update-check` opts out.
