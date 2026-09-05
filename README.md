# bootstrap

Set up a machine's software from a manifest, and keep it up to date afterwards.

One command does both jobs. On a fresh machine it installs everything; on a
machine that already has it, it takes the updates. The tool works out per
package which one it is doing, and prints a line for every decision it makes.

| Platform | Status | Sources |
|---|---|---|
| [Windows](windows/) | Working — see [`windows/README.md`](windows/README.md) | winget |
| [Linux](linux/) | Working — see [`linux/README.md`](linux/README.md) | apt, Flathub, `$HOME` version managers |
| macOS | Planned | Homebrew |

## Windows

```powershell
cd windows
.\bootstrap.ps1 -WhatIf     # show what would change, touch nothing
.\bootstrap.ps1             # do it
```

Full documentation, including the first run from a downloaded release, is in
[`windows/README.md`](windows/README.md).

## Linux

```bash
cd linux
./bootstrap.sh --dry-run     # show what would change, touch nothing
./bootstrap.sh               # do it
```

Debian family, and it works on a server as well as a workstation: groups that
need a desktop are detected and skipped on a headless machine, rather than
dragging Blender onto a box where nobody can open it. See
[`linux/README.md`](linux/README.md) for how that check works — and why the two
obvious ways to make it are both wrong.

## What this is trying to be

**Idempotent, and honest about it.** Running it twice should change nothing the
second time, and the summary should say so. A step that reports `installed` on
every run is a step that cannot tell you which run actually changed something,
which makes the output worthless exactly when you need it.

**Declarative where it can be.** What gets installed lives in a manifest, not in
code. Adding a package should not mean editing a script.

**Reported, not assumed.** Software owned by another installer is detected and
listed, never touched — letting two package managers fight over the same
application is how a machine ends up disagreeing with itself about what is
installed.

**Never destructive.** It installs and upgrades. It does not uninstall, and it
backs up any hand-written config it is about to replace.

## Versioning

Each platform is released independently, tagged `<platform>-vX.Y.Z`. See the
platform's own `CHANGELOG.md`.
