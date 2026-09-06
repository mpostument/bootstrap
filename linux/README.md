# bootstrap.sh

Installs and updates a Debian-family machine's software from a manifest.

One command does both jobs. On a fresh machine it installs everything; on a
machine that already has it, it takes the updates.

```bash
./bootstrap.sh --dry-run     # show what would change, touch nothing
./bootstrap.sh               # do it
```

It calls `sudo` for the steps that need root and runs everything else as you.
Nothing here needs you to be root for the whole run.

## The desktop check

The thing that makes one manifest work on both a workstation and a server:
groups marked `GROUP_<name>_GUI=yes` are **skipped** when the machine has no
desktop environment. Blender, GIMP, VLC and the rest are reported as `no-gui`
rather than dragging a large dependency tree onto a box where nobody can open
them.

The two obvious ways to detect this are both wrong, so neither is used:

| Signal | Why it lies |
|---|---|
| `$DISPLAY` / `$WAYLAND_DISPLAY` | Describes the *session*, not the machine. Unset when you SSH into your own desktop; **set** when you SSH into a headless server with X forwarding. WSLg sets both on a WSL install with no desktop at all. |
| `systemctl get-default` | Reports `graphical.target` on that same WSL install. |

Both were measured on WSL Ubuntu 24.04: `DISPLAY=:0`, `WAYLAND_DISPLAY=wayland-0`,
`graphical.target` — and no desktop.

So the script asks what is **installed** instead: a display manager, or session
`.desktop` files under `/usr/share/xsessions` or `/usr/share/wayland-sessions`.
Neither appears by accident, and the answer is the same over SSH as it is at
the keyboard — which is the property that matters for something meant to run
unattended.

Override it with `--gui` or `--no-gui` when you know better.

## What it does

1. **Repositories** — adds the third-party apt sources in the manifest, each
   with its own key under `/etc/apt/keyrings` and a `Signed-By` line scoping
   that key to that repository only.
2. **Repository packages** — VS Code, Docker, Unity Hub.
3. **Package groups** — everything from the distribution archive and Flathub,
   with GUI groups gated on the desktop check.
4. **Upgrades** — one apt transaction for the whole system, plus `flatpak
   update` — and only when something is actually outdated.
5. **Tools** — `pyenv`, `pyenv-virtualenv`, `tfenv` and `nvm`, git clones under
   `$HOME`.
6. **.NET SDK** — Microsoft's install script, into `$HOME/.dotnet`.
7. **Release binaries** — `tflint` and `terraform-docs`, static builds from
   GitHub into `~/.local/bin`, for software Debian does not package.
8. **Nerd Font** — Meslo, on desktop machines, because powerlevel10k needs it.
9. **Claude Code** — Anthropic's script, once, into `~/.local/bin`.
10. **zsh** — oh-my-zsh, powerlevel10k and the plugins, plus a managed
    `~/.zshrc.bootstrap` fragment sourced from your own `.zshrc`.

## Options

```
--dry-run          Show what would change, touch nothing.
--groups a,b       Limit to named groups. Default is every group.
--list-groups      Print the groups in the manifest and exit.
--skip-upgrade     Install what is missing, leave installed versions alone.
--gui / --no-gui   Override desktop detection instead of probing for it.
--yes              Pass -y to apt. Implied when not attached to a terminal.
--version          Print the version and exit.
```

## The manifest

`packages.conf` is sourced as bash, so it can use arrays and comments freely.
Software is sorted by **who owns it**, the same way the Windows manifest sorts
it, because that is the distinction that matters when an update goes wrong:

| | installed | upgraded |
|---|---|---|
| `GROUP_*_APT` | yes | yes, in one system-wide transaction |
| `GROUP_*_FLATPAK` | yes | yes |
| `REPOS` | yes, with its key and source file | yes |
| `RELEASES` | yes, a static binary into `~/.local/bin` | yes, checked against the newest release tag |
| `TOOLS` | yes, git clone into `$HOME` | yes, `git pull --ff-only` |
| `HELD` | no | no |
| `MANUAL` | no | no |

Adding to `REPOS` is not a small decision: a repository there can push a
package to this machine on every future run, forever. Each entry names its key
URL explicitly rather than piping a vendor script into a shell, and the key is
scoped with `Signed-By` — unlike `apt-key`, which trusts a key for *every*
repository on the system.

`{ID}` and `{CODENAME}` in a repository URL are substituted from
`/etc/os-release`. Docker publishes a separate tree per distribution and per
release, and pointing Ubuntu at the Debian one installs packages built against
a different libc.

### Two names worth knowing

**`PKG_GROUPS`, not `GROUPS`.** `GROUPS` is a bash builtin holding the current
user's group IDs. Assigning to it silently does nothing, and every group name
becomes a number — the first version of this manifest did exactly that and the
run reported groups called `1000` and `27`.

**`fd-find` installs as `fdfind`, `bat` as `batcat`.** Debian renames both to
dodge a clash with older archive packages. The managed zsh fragment aliases
them and guards each on `command -v`, because a blind alias to a missing binary
breaks the normal command entirely.

## zsh

The shell setup matches the fleet's Ansible role, so a shell is the same
wherever you land: oh-my-zsh, powerlevel10k, and the plugin list in the
manifest.

Plugin **order** is load-bearing, not alphabetical:

- `zsh-syntax-highlighting` must be last but one. It wraps ZLE widgets, and
  anything sourced after it defines widgets outside that wrapping.
- `history-substring-search` is the documented exception and goes after it.
- `fzf-tab` must load after `compinit` but before anything that wraps ZLE
  widgets, which makes first the only position that satisfies it.

Your `.zshrc` is not rewritten. The managed block lives in
`~/.zshrc.bootstrap`, and a single `source` line is appended to `.zshrc` if it
is not already there.

## Releases

All three platforms ship in **one** GitHub release, tagged `vX` — the tag names
the bundle, not a version. Each platform still versions independently, so a
release states which version of each is inside, and this one's number lives in
`BOOTSTRAP_VERSION` in `bootstrap.sh` with its notes in `CHANGELOG.md`.

The release workflow refuses to publish if any platform's current version has
no matching changelog section, if any shipped script fails to parse, or if
shellcheck complains.
