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
   Google Cloud CLI.
3. **Package groups** — archive and Flathub, GUI groups gated on the check above.
4. **Upgrades** — one apt transaction plus `flatpak update`, only when outdated.
5. **Tools** — `pyenv`, `pyenv-virtualenv`, `tofuenv`, `nvm` as git clones under `$HOME`.
6. **.NET SDK** — Microsoft's install script into `$HOME/.dotnet`.
7. **Release binaries** — `tflint`, `terraform-docs`, `helm`, `k9s`, `stern`,
   `yq`, `starship` into `~/.local/bin`.
8. **Nerd Font** — Meslo, on desktop machines.
9. **Claude Code** — Anthropic's script into `~/.local/bin`.
10. **zsh** — oh-my-zsh, Starship and plugins, plus a managed
    `~/.zshrc.bootstrap` sourced from your own `.zshrc`.
11. **Prompt config** — `starship.toml` from the repo root to
    `~/.config/starship.toml`, the same file all three platforms deploy.
12. **Schedule** — a systemd system timer that re-runs this script daily.

## Options

```
--dry-run          Show what would change, touch nothing.
--groups a,b       Limit to named groups. Default is every group.
--list-groups      Print the groups in the manifest and exit.
--list-packages    Print every package/tool this script manages and exit.
--skip-upgrade     Install what is missing, leave installed versions alone.
--skip-schedule    Leave the systemd timer alone.
--gui / --no-gui   Override desktop detection instead of probing for it.
--yes              Pass -y to apt. Implied when not attached to a terminal.
--version          Print the version and exit.
```

`tools` is a zsh function written into the managed fragment: the `cli` group as
of the last run, with what to type and what it does.

## The manifest

`packages.conf` is sourced as bash. Software is sorted by who owns it:

| | installed | upgraded |
|---|---|---|
| `GROUP_*_APT` | yes | yes, in one system-wide transaction |
| `GROUP_*_FLATPAK` | yes | yes |
| `REPOS` | yes, with its key and source file | yes |
| `RELEASES` | yes, a static binary into `~/.local/bin` | yes, against the newest release tag |
| `TOOLS` | yes, git clone into `$HOME` | yes, `git pull --ff-only` |
| `HELD` | no | no |
| `MANUAL` | no | no |

A `REPOS` entry can push packages to this machine on every future run. Each
names its key URL explicitly rather than piping a vendor script into a shell,
and scopes it with `Signed-By`.

`{ID}` and `{CODENAME}` in a repository URL are substituted from
`/etc/os-release` — Docker publishes a separate tree per distribution and
release.

`PKG_GROUPS`, not `GROUPS`: the latter is a bash builtin holding the user's
group IDs, and assigning to it silently turns every group name into a number.

`fd-find` installs as `fdfind` and `bat` as `batcat`; the zsh fragment aliases
both, guarded on `command -v`.

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

## Releases

All three platforms ship in one GitHub release tagged `vX`; each versions
independently. This one's number is `BOOTSTRAP_VERSION` in `bootstrap.sh`, with
notes in `CHANGELOG.md`. The release workflow refuses to publish if the current
version has no changelog section, a script fails to parse, or shellcheck
complains.
