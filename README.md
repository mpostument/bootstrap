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
  The one thing pruned is what an upgrade superseded - old versions and
  download caches - and only where the manifest asks for it.
- Config the repo owns is copied; a setting that is yours is left alone. The
  themes are both: the theme file is the repo's, and the one key that activates
  it - k9s's `ui.skin`, btop's `color_theme`, yazi's `dark` flavor - is set
  only when it is unset, because those files are rewritten by the tools
  themselves or hold settings of yours, and a theme you picked is a choice. `--doctor` reports the file and the key separately, so a theme that
  is deployed but not in effect does not read as healthy.

## Checks

`release.yml` runs on a `v*` tag and validates only what is in the repository:
scripts parse, manifests have the sections their script reads, each script can
start, and the `cli` group matches `tools/cli-parity.conf`.

`verify-manifests.yml` asks whether every package name still resolves — Debian's
archive, the Homebrew API, `winget-pkgs`, and a `HEAD` against every `RELEASES`
asset. Runs on push and weekly.

`lint.yml` runs on every push: actionlint, typos, taplo, shfmt (report only),
shellcheck over `tools/`, PSScriptAnalyzer over `windows/`, and the tests.

`tools/test.sh` asserts what the three scripts promise each other — that the
duration formatters agree across bash and PowerShell, that all three write the
same run record, that `--status` survives a record a killed run left
half-written, that the launchd plist parses, that the apt cache prunes by age
and only by age, and that theme activation writes when the key is unset and
keeps its hands off when it is not. The functions under test are extracted from the scripts
themselves, so a test cannot pass against a stale copy. Anything it needs and
cannot find — `plutil`, GNU `find`, `pwsh` — is skipped out loud.

```bash
bash tools/test.sh          # everything; no network, nothing installed
bash tools/test.sh record   # one section
bash tools/parity.sh        # the parity check alone
```

## Versioning

All three platforms ship in one GitHub release, tagged `vYYYY.MM`. The tag names
the bundle; each platform versions independently in its own script and its own
`CHANGELOG.md`, and the release notes say which versions are inside.
