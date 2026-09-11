# bootstrap

Set up a machine's software from a manifest, and keep it up to date afterwards.
One command does both: on a fresh machine it installs, on an existing one it
upgrades, and it prints a line for every decision.

| Platform | Sources |
|---|---|
| [Windows](windows/) | winget |
| [Linux](linux/) | apt, Flathub, `$HOME` version managers |
| [macOS](macos/) | Homebrew formulae and casks, `$HOME` version managers |

## Windows

```powershell
cd windows
.\bootstrap.ps1 -WhatIf     # show what would change, touch nothing
.\bootstrap.ps1             # do it
```

## Linux

```bash
cd linux
./bootstrap.sh --dry-run     # show what would change, touch nothing
./bootstrap.sh               # do it
```

Debian family. Groups needing a desktop are skipped on a headless machine.

## macOS

```bash
cd macos
./bootstrap.sh --dry-run     # show what would change, touch nothing
./bootstrap.sh               # do it
```

Homebrew, and not under `sudo`.

## Rules

- Idempotent: a second run changes nothing and says so.
- Declarative: what gets installed lives in a manifest, not in code.
- Software owned by another installer is detected and reported, never touched.
- Never destructive: installs and upgrades only, and backs up config it replaces.

## Checks

`release.yml` runs on a `v*` tag and validates only what is in the repository:
scripts parse, manifests have the sections their script reads, each script can
start, and the `cli` group matches `tools/cli-parity.conf`.

`verify-manifests.yml` asks whether every package name still resolves — Debian's
archive, the Homebrew API, `winget-pkgs`, and a `HEAD` against every `RELEASES`
asset. Runs on push and weekly.

```bash
bash tools/parity.sh     # the parity check alone, no network needed
```

## Versioning

All three platforms ship in one GitHub release, tagged `vYYYY.MM`. The tag names
the bundle; each platform versions independently in its own script and its own
`CHANGELOG.md`, and the release notes say which versions are inside.
