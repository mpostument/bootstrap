# bootstrap.sh

Installs and updates a Debian-family machine's software from a manifest. One
command does both.

```bash
./bootstrap.sh --dry-run     # show what would change, touch nothing
./bootstrap.sh               # do it
```

It calls `sudo` for the steps that need root and runs everything else as you.

## The desktop check

Groups marked `GROUP_<name>_GUI=yes` are skipped when the machine has no
desktop, and reported as `no-gui`.

Detection asks what is **installed** — a display manager, or session `.desktop`
files under `/usr/share/xsessions` or `/usr/share/wayland-sessions`. Not
`$DISPLAY`/`$WAYLAND_DISPLAY` and not `systemctl get-default`: both describe the
session rather than the machine, and both report a desktop on WSL, which has
none. Override with `--gui` or `--no-gui`.

## What it does

1. **Repositories** — third-party apt sources, each with its own key under
   `/etc/apt/keyrings` and a `Signed-By` line scoping it to that repository.
2. **Repository packages** — VS Code, Docker, Unity Hub, kubectl, Azure CLI,
   Google Cloud CLI, GitHub CLI.
3. **Package groups** — archive and Flathub, GUI groups gated on the check above.
4. **Upgrades** — one apt transaction plus `flatpak update`, only when outdated.
5. **Housekeeping** — cached `.deb` downloads past their age, and a report of
   what `apt autoremove` and `flatpak uninstall --unused` would take.
6. **Tools** — `TOOLS` git clones under `$HOME`; empty since mise replaced
   pyenv, nvm and tofuenv.
7. **.NET SDK** — Microsoft's install script into `$HOME/.dotnet`.
8. **Release binaries** — upstream builds into `~/.local/bin`: the modern CLI
   bundle (bat, eza, fd, ripgrep, fzf, jq, yt-dlp and the rest), starship,
   atuin, uv, carapace, and the Kubernetes and Terraform tools. The archive
   trails upstream by years for most of them, and Ubuntu 24.04 lacks several.
9. **Python tools** — each group's `GROUP_*_UV` entries, through `uv tool`.
10. **Ghostty** — the community `.deb` that ghostty.org points Debian and Ubuntu
    to, on desktop machines.
11. **Nerd Font** — Meslo, on desktop machines.
12. **Claude Code** — Anthropic's script into `~/.local/bin`.
13. **VS Code extensions** — `VSCODE_EXTENSIONS`, installed with
    `code --install-extension`; never removes one that isn't listed.
14. **zsh** — Starship, completion and the `ZSH_PLUGIN_REPOS` checkouts,
    plus a managed `~/.zshrc.bootstrap` sourced from your own `.zshrc`.
15. **Prompt config** — `starship.toml` from the repo root to
    `~/.config/starship.toml`, the same file all three platforms deploy.
16. **bat config** — `bat/config` and the Catppuccin Mocha theme from the repo
    root, the palette starship, ghostty, atuin and delta all render in.
17. **Schedule** — a systemd system timer that re-runs this script daily.

## Options

```
--dry-run          Show what would change, touch nothing.
--select           Tick which packages this machine has - see below.
--groups a,b       Limit to named groups. Default is every group.
--list-groups      Print the groups in the manifest and exit.
--list-packages    Print every package/tool this script manages and exit.
--status           Print what the last real run did and exit. Exits 1 if that
                   run failed.
--history[=n]      Print the last n runs (default 10) and what each moved.
--doctor           Check what a login shell actually sees, and exit. Changes
                   nothing; exits 1 if something is wrong.
--skip-upgrade     Install what is missing, leave installed versions alone.
--skip-cleanup     Leave cached .deb downloads on disk.
--skip-schedule    Leave the systemd timer alone.
--skip-vscode-extensions
                   Install none of the VS Code extensions in the manifest.
--skip-update-check
                   Don't check the GitHub origin for a newer release tag.
--gui / --no-gui   Override desktop detection instead of probing for it.
--yes              Pass -y to apt. Implied when not attached to a terminal.
--version          Print the version and exit.
```

`tools` is a zsh function written into the managed fragment: the `cli` group as
of the last run, with what to type and what it does.

Four fzf pickers sit beside it, defined when fzf is on `PATH`. Each only picks;
what runs afterwards is an ordinary git or kill command.

| | |
|---|---|
| `gb` | switch branch - local and remote, newest first, the log as the preview |
| `gs` | browse stashes; Enter applies, ctrl-p pops, ctrl-x drops (not defined where Ghostscript owns `gs`) |
| `fkill [signal]` | pick some of your own processes and signal them, TERM by default |
| `cheat` | search the `tools` list, preview its tldr page, put the command on the prompt |

## Choosing packages

```bash
./bootstrap.sh --select            # tick what this machine should have
./bootstrap.sh --select --dry-run  # the same menu, and what it would change
```

`--select` opens every package in the manifest as a menu, a section per group
- apt packages, flatpaks and uv tools together - and a `releases` section for
the release binaries, which belong to no group:

```
   [x] shell                        9/9
 >   [■] git                              1:2.43.0         required
     [x] git-lfs                          3.4.1
   [-] releases                    40/41
     [ ] popeye                           -                release
```

Up/Down or j/k move, PgUp/PgDn and Home/End jump; Space ticks a package, or on
a section ticks all of it - and clears it if it was all ticked. Enter applies,
q or Esc cancels. Your current pick comes pre-ticked; `REQUIRED` in
`packages.conf` (zsh, git, uv) shows locked and is always installed.

On Enter, what you ticked is installed and what you unticked is uninstalled,
after one confirmation that lists it - `apt-get remove` through sudo,
`flatpak uninstall`, `uv tool uninstall`, or the binary deleted from
`~/.local/bin`. apt removes whatever depends on a package along with it, so
each removal is simulated first: if it would take anything else, it is not
run, and the result names what would have gone.

The pick is saved to `/var/lib/bootstrap-linux/selection` - there and not in
`$HOME`, because the systemd timer runs as root and has to read it - one
`yes <package>` or `no <package>` per line, written through sudo. Every later
run follows it, the timer too. Without that file every package is wanted, as
before `--select` existed; delete it to go back. A package added to the
manifest after your pick is asked about once on the next manual run and the
answer kept; the timer never asks and never installs it. A section with
nothing ticked counts as switched off, and its newcomers are left out without
asking. Only `--select` ever uninstalls anything.

## The manifest

`packages.conf` is sourced as bash. Software is sorted by who owns it:

| | installed | upgraded |
|---|---|---|
| `GROUP_*_APT` | yes | yes, in one system-wide transaction |
| `GROUP_*_FLATPAK` | yes | yes |
| `REPOS` | yes, with its key and source file | yes |
| `RELEASES` | yes, a static binary into `~/.local/bin` | yes, against the newest release tag |
| `GROUP_*_UV` | yes, `uv tool install` into `~/.local/bin` | yes, `uv tool upgrade` |
| `TOOLS` | yes, git clone into `$HOME` | yes, `git pull --ff-only` |
| `HELD` | no | no |
| `MANUAL` | no | no |

A `REPOS` entry can push packages to this machine on every future run. Each
names its key URL explicitly rather than piping a vendor script into a shell,
and scopes it with `Signed-By`.

`{ID}` and `{CODENAME}` in a repository URL are substituted from
`/etc/os-release` — Docker publishes a separate tree per distribution and
release. Where a vendor has not caught up with a release,
`REPO_<name>_CODENAME_MAP=(trixie:bookworm)` substitutes the release it does
publish.

`PKG_GROUPS`, not `GROUPS`: the latter is a bash builtin holding the user's
group IDs, and assigning to it silently turns every group name into a number.

An apt `fd-find` or `bat` left from before the CLI bundle moved to `RELEASES`
installs as `fdfind` / `batcat`; the zsh fragment aliases those only where the
real names are absent.

## zsh

Plugin order is load-bearing: `zsh-syntax-highlighting` last but one,
`history-substring-search` after it, `fzf-tab` first (after `compinit`, before
anything that wraps ZLE widgets).

Your `.zshrc` is not rewritten. The managed block lives in
`~/.zshrc.bootstrap`, with one `source` line appended to `.zshrc` if absent.

## Schedule

A systemd system timer (`bootstrap-linux.timer`, see `SCHEDULE_UNIT_NAME`)
re-runs this script daily at `SCHEDULE_TIME`.

- Needs root, like any step here that calls `sudo`.
- Skipped where systemd is not PID 1 (stock WSL) or `SCHEDULE_ENABLED=no`.
  `--skip-schedule` does the same for one run.
- `Persistent=true`, so a trigger the machine slept through fires on wake.
- Logs to the journal: `journalctl -u bootstrap-linux`.

Remove it with `sudo systemctl disable --now bootstrap-linux.timer`.

### Did last night's run work?

Every real run leaves a record — when, how long, the exit code, the counts, the
id of every step that failed, and the message it died with if it did. Written
from the `EXIT` trap, so a run that aborts in preflight records that instead of
leaving yesterday's success in place. Dry runs never write it.

There are two paths, because two different users run this script: the timer is
root, so its record is `/var/lib/bootstrap-linux/last-run`, and yours is
`${XDG_STATE_HOME:-~/.local/state}/bootstrap-linux/last-run`. `--status` reads
whichever is newer and says which one it used.

```console
$ ./bootstrap.sh --status

== Last run ====================================================
  when            2026-09-17 04:21:37  (7h 30m ago)
  trigger         unattended - the systemd timer, or output redirected
  version         v1.33.0
  duration        1m 34s
  result          exit 1
  failed          repo: Visual Studio Code, apt packages
  counts          installed=1 upgraded=12 current=109
  log             journalctl -u bootstrap-linux
  record          /var/lib/bootstrap-linux/last-run
```

It exits 1 when that run failed, so `bootstrap.sh --status` works as a check.

With `SCHEDULE_NOTIFY_ON_FAILURE=yes` a failed unattended run also sends one
`notify-send` to every logged-in desktop session. The timer runs as root, which
has no session bus of its own, so the message is handed to each
`/run/user/<uid>/bus` in turn; a headless machine has none, and nothing
happens. Interactive runs never notify — they already printed the failures in
red.

## Is it actually in effect?

Every phase here asserts that a package is *installed*. `--doctor` asserts that
it is in **effect**, which is not the same thing and is where the bugs have
been: `~/go/bin` missing from `PATH`, an apt `fd-find` shadowing the real `fd`,
the mise shims never reaching a login shell, `starship.toml` never applied, Tab
never getting to fzf-tab. Every one of those was found months later by somebody
noticing.

So the checks run inside a real login shell — `zsh -lic` — because that is the
environment they are about, and no other phase looks there. One probe emits
every fact at once, in about a second; a shell per check would take a minute to
say the same thing.

```console
$ ./bootstrap.sh --doctor

== Doctor - the cli group on PATH ==============================
  ok            bat                     /home/you/.local/bin/bat
  present       yq                      a mise shim answers first, ahead of /home/you/.local/bin/yq
== Doctor - shell integration ==================================
  ok            fzf-tab                 bound to Tab
  ok            atuin                   the atuin-search widget exists
  broken        starship                not initialised in a login shell
```

`ok` is in effect, `broken` is not, and `present` is a judgement call left to
you — a mise shim in front of a binary runs the same program through one more
exec, and a config file that differs from the repo is only going to be replaced
by the next run. It changes nothing and exits 1 if anything is broken.

## What moved

`--status` answers "did last night's run work". `--history` answers "and what
did it change":

```console
$ ./bootstrap.sh --history=3

== History =====================================================
  when              took     result   i/u/f   what moved
  2026-09-15 04:20* 1m 34s   ok       1/12/0  node 24.20.0>24.21.0, ripgrep 14.1.0>14.1.1
  2026-09-16 04:20* 2m 02s   exit 1   0/3/2   starship 1.25.1>1.26.0
  2026-09-17 09:11  8s       ok       0/0/0
  3 run(s), * = unattended
```

The versions come from a snapshot taken before the packages phase and another
after the upgrades, so they are what actually moved rather than what scrolled
past. One line per run, oldest first, capped at 200 lines — eight months of
nightly runs.

## Housekeeping

apt keeps every `.deb` it downloads in `/var/cache/apt/archives` and removes
none of them. On a machine the timer upgrades nightly that is every package it
has ever installed. `APT_CLEANUP_PRUNE_DAYS` sets the age past which a cached
download goes; `APT_CLEANUP_ENABLED=no` turns the phase off and `--skip-cleanup`
skips it for one run.

Nothing is uninstalled. `apt-get autoremove` and `flatpak uninstall --unused`
are run with `--dry-run` and their findings printed, because both are usually
right about orphaned packages, old kernels and unused runtimes, and "usually"
is not good enough to do unattended at 04:20. The journal's size is reported
the same way, with the `journalctl --vacuum-time` command to trim it: the
journal belongs to the whole system, not to this script.

## Releases

All three platforms ship in one GitHub release tagged `vX`; each versions
independently. This one's number is `BOOTSTRAP_VERSION` in `bootstrap.sh`, with
notes in `CHANGELOG.md`. The release workflow refuses to publish if the current
version has no changelog section, a script fails to parse, or shellcheck
complains.

Preflight checks for a newer release and prints one line if this install is
behind - separate from `BOOTSTRAP_VERSION` above, which is this script's own number.
Two kinds of install know their release: a git checkout (its tag, and its
GitHub origin) and a release archive (the `RELEASE` file beside the platform
directory, naming the tag and the repo). Silent on anything else, a fork
hosted elsewhere, or no network. `--skip-update-check` opts out.

On a run you are sitting at, it also offers to update: `Update to vX and
rerun? [y/N]`. Yes updates in place and runs the new script with the same
arguments. A checkout moves to the release - a branch fast-forwards to the
tag, a checkout of a tag moves to the new one - and refuses instead of
guessing when there are local changes, or a branch has commits the release
does not (then updating is `git pull` by hand). An archive install downloads
the new release's archive, checks it against the published `.sha256`, unpacks
it into a temp directory and copies it over the install - same directory, so
the scheduled run that points into it keeps working. The systemd timer, `--dry-run`, `--doctor` and a run as root only print
the line - root writing into your install would leave files you could not
change.
