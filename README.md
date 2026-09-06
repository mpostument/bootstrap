# bootstrap

Set up a machine's software from a manifest, and keep it up to date afterwards.

One command does both jobs. On a fresh machine it installs everything; on a
machine that already has it, it takes the updates. The tool works out per
package which one it is doing, and prints a line for every decision it makes.

| Platform | Status | Sources |
|---|---|---|
| [Windows](windows/) | Working — see [`windows/README.md`](windows/README.md) | winget |
| [Linux](linux/) | Working — see [`linux/README.md`](linux/README.md) | apt, Flathub, `$HOME` version managers |
| [macOS](macos/) | Working — see [`macos/README.md`](macos/README.md) | Homebrew formulae and casks, `$HOME` version managers |

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

## macOS

```bash
cd macos
./bootstrap.sh --dry-run     # show what would change, touch nothing
./bootstrap.sh               # do it
```

Homebrew, and **not** under `sudo` — the inverse of the Linux script, because
brew refuses to run as root. It works out the right prefix for the machine
rather than the shell it was started from: `uname -m` reports `x86_64` on an
Apple silicon Mac under Rosetta, and believing it installs a second, parallel
Homebrew into `/usr/local` that nothing ever picks up. See
[`macos/README.md`](macos/README.md).

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

## Checks

Two workflows, split by whether a check needs the outside world.

**`release.yml`** runs on a `v*` tag and validates only what is in the
repository: every script parses, every manifest has the sections its script
reads, each script can actually start, and the `cli` group matches
`tools/cli-parity.conf` on all three platforms. Publishing must never depend on
whether somebody else's package index is reachable this minute.

**`verify-manifests.yml`** asks the world the question the manifests cannot
answer themselves: does every name still resolve? Debian's archive for the apt
packages, the Homebrew API for formulae *and* casks separately, the
`winget-pkgs` repository for winget ids including their case, and a `HEAD`
against every `RELEASES` asset URL. It runs on push and weekly — the schedule
being the point, because package names rot while nobody touches the repository.

```bash
bash tools/parity.sh     # the parity check, on its own, no network needed
```

The reason both exist is written up in each file, but the short version is
that this repository keeps paying the same bill at runtime. `yq` named a real
Debian package that was a *different program* from the one the other two
platforms installed. `Derailed.k9s` needed its capital D found by hand.
`google-cloud-sdk` moved from formula to cask. Each was discovered by a run
failing on somebody's machine, and each is now a check.

## Versioning

All three platforms ship in **one** GitHub release. The tag names the bundle,
not a version — `git tag v2026.02` — and the release notes say which version of
each platform is inside.

The platforms still version independently, each with its own number in its own
script and its own `CHANGELOG.md`, because a Linux fix is not a reason to
renumber Windows. What a release records is that these three particular
versions were published together.
