# ============================================================
# PowerShell profile - managed by windows/bootstrap.ps1
# ============================================================
# Deployed verbatim to BOTH profile paths, because PS7 and Windows PowerShell
# 5.1 do not share one:
#   Documents\WindowsPowerShell\Microsoft.PowerShell_profile.ps1   (5.1)
#   Documents\PowerShell\Microsoft.PowerShell_profile.ps1          (7)
#
# Edit this file in the repo, not the deployed copies - the next bootstrap run
# overwrites those. A profile found in place WITHOUT the "managed by" line
# above is treated as hand-written and copied to .bak before it is replaced.
#
# Every block below is guarded, so this file is safe to load before
# bootstrap.ps1 has finished installing what it references.

# ============================================================
# PSReadLine
# https://learn.microsoft.com/powershell/module/psreadline
# ============================================================
# Windows PowerShell 5.1 preloads an old inbox copy (2.0.0) before this
# profile runs; PS7 already ships a recent one. Force-load the newer
# version either way.
Import-Module PSReadLine -MinimumVersion 2.4.5 -Force -ErrorAction SilentlyContinue

# CompletionPredictor makes the ListView below more than a history list: it
# feeds PowerShell's own tab-completion results into the same dropdown, so
# parameter names and enum values show up there too, not just things already
# typed once. It plugs into the predictor subsystem, which is PS7-only and
# absent from Windows PowerShell 5.1 -- hence the fallback below rather than
# one flat PredictionSource line, and hence packages.psd1 listing it under
# Modules7 and not Modules51.
Import-Module CompletionPredictor -ErrorAction SilentlyContinue

# Prediction options need a real console (VT support); skip quietly if
# unavailable (e.g. non-interactive hosts, some CI/editor terminals) --
# these throw terminating exceptions, so -ErrorAction alone won't suppress
# them.
try {
    Set-PSReadLineOption -PredictionSource HistoryAndPlugin -ErrorAction Stop
} catch {
    # 5.1, or a PS7 without the module: history alone still gives a ListView.
    try { Set-PSReadLineOption -PredictionSource History } catch { }
}
try { Set-PSReadLineOption -PredictionViewStyle ListView } catch { }
Set-PSReadLineOption -EditMode Windows
Set-PSReadLineOption -BellStyle None
Set-PSReadLineOption -HistoryNoDuplicates
Set-PSReadLineOption -HistorySearchCursorMovesToEnd
# Default is 4096 lines, which on a daily-driver machine rolls over in weeks
# and quietly takes the older half of both the ListView and the Up-arrow
# history search with it. 1000000 matches HISTORY_SIZE / HISTORY_FILE_SIZE
# on the Unix side - what the running shell keeps and what reaches the file
# are both this - so history lasts the life of the machine rather than a
# busy quarter, on all three platforms.
Set-PSReadLineOption -MaximumHistoryCount 1000000
Set-PSReadLineOption -Colors @{ InlinePrediction = '#5A5A5A' }

# Up/Down arrows: search history matching what's already typed
Set-PSReadLineKeyHandler -Key UpArrow -Function HistorySearchBackward
Set-PSReadLineKeyHandler -Key DownArrow -Function HistorySearchForward
# Tab: show a completion menu instead of just cycling
Set-PSReadLineKeyHandler -Key Tab -Function MenuComplete
# Ctrl+RightArrow / Ctrl+LeftArrow: jump by word
Set-PSReadLineKeyHandler -Key Ctrl+RightArrow -Function ForwardWord
Set-PSReadLineKeyHandler -Key Ctrl+LeftArrow -Function BackwardWord
# Right arrow at end of line: accept the greyed-out prediction
Set-PSReadLineKeyHandler -Key RightArrow -Function ForwardChar

# ============================================================
# Terminal-Icons -- file-type icons in Get-ChildItem / ls output
# https://github.com/devblackops/Terminal-Icons
# ============================================================
Import-Module Terminal-Icons -ErrorAction SilentlyContinue

# ============================================================
# PSFzf -- fuzzy history (Ctrl+R), file (Ctrl+T) and git completion
# https://github.com/kelleyma49/PSFzf
# ============================================================
if (Get-Command fzf -ErrorAction SilentlyContinue) {
    # PSFzf throws a terminating exception on import if it can't find fzf,
    # which -ErrorAction alone won't suppress -- wrap in try/catch. This can
    # legitimately happen right after installing fzf, until PATH changes
    # propagate to already-open terminal windows.
    try {
        Import-Module PSFzf -ErrorAction Stop
        Set-PsFzfOption -PSReadlineChordProvider 'Ctrl+t' -PSReadlineChordReverseHistory 'Ctrl+r'

        # -TabExpansion is narrower than the name suggests, and worth being
        # precise about because the name invites the wrong assumption: it does
        # NOT rebind the tab key and does NOT replace the completion menu.
        # What it does is register native argument completers for git, tgit
        # and gitk which route those commands' completions through fzf, so
        # `git checkout <tab>` opens a fuzzy branch picker. Everything else
        # still reaches MenuComplete, bound further up, untouched.
        #
        # That is less than zsh gets from fzf-tab, where every completion in
        # the shell goes through fzf. PowerShell has no equivalent: PSReadLine
        # owns the completion menu itself and exposes no hook for swapping the
        # presentation out, so the fuzzy-filter-instead-of-arrow experience is
        # a zsh-only win rather than something the two can be brought level on.
        Set-PsFzfOption -TabExpansion

        # fh = fuzzy-search history and run it; fkill = pick a process to
        # kill. Both purely additive new commands.
        #
        # NOT enabled: -EnableAliasFuzzySetLocation. It defines an alias
        # named fd, which would shadow the fd.exe installed from the cli group in
        # packages.psd1 -- including for the find function defined
        # below in this same file, which calls fd directly and would start
        # invoking a fuzzy directory picker instead.
        Set-PsFzfOption -EnableAliasFuzzyHistory -EnableAliasFuzzyKillProcess
    } catch {
        Write-Warning "PSFzf failed to load (try closing and reopening the terminal): $($_.Exception.Message)"
    }
}

# ============================================================
# zoxide -- smarter cd; `z <part-of-path>` jumps to your most-used match
# https://github.com/ajeetdsouza/zoxide
# ============================================================
if (Get-Command zoxide -ErrorAction SilentlyContinue) {
    Invoke-Expression (& { (zoxide init powershell | Out-String) })
}

# ============================================================
# Modern CLI bundle -- nicer cat/ls/find/grep
# bat: https://github.com/sharkdp/bat | eza: https://github.com/eza-community/eza
# fd:  https://github.com/sharkdp/fd  | ripgrep: https://github.com/BurntSushi/ripgrep
# ============================================================
# Built-in aliases (cat/ls -> Get-Content/Get-ChildItem) take precedence
# over same-named functions, so they're removed first. `gci`/`dir` still
# reach the original cmdlet if a script or muscle memory needs it.
if (Get-Command bat -ErrorAction SilentlyContinue) {
    Remove-Item Alias:cat -Force -ErrorAction SilentlyContinue
    function cat { bat --paging=never @args }
}
if (Get-Command eza -ErrorAction SilentlyContinue) {
    Remove-Item Alias:ls -Force -ErrorAction SilentlyContinue
    # eza silently lists nothing when called with zero path args (a known
    # quirk on Windows) -- default explicitly to the current directory.
    function ls {
        if ($args.Count -eq 0) { eza --icons=auto --group-directories-first . }
        else { eza --icons=auto --group-directories-first @args }
    }
}
if (Get-Command fd -ErrorAction SilentlyContinue) {
    function find { fd @args }
}
if (Get-Command rg -ErrorAction SilentlyContinue) {
    function grep { rg @args }
}

# du/df to dust/duf are a bigger change of shape than the pairs above: dust
# prints a tree with bars, duf a table with different columns, and neither is
# a drop-in for a script parsing traditional du/df output - that script
# should keep calling the real binary, not these functions. Windows has no
# built-in du/df to remove an alias for, unlike cat/ls above.
if (Get-Command dust -ErrorAction SilentlyContinue) {
    function du { dust @args }
}
if (Get-Command duf -ErrorAction SilentlyContinue) {
    function df { duf @args }
}

# ============================================================
# posh-git -- tab-completion for git subcommands, branches and remotes
# https://github.com/dahlbyk/posh-git
# ============================================================
# Imported for its argument completers only, and imported BEFORE Starship
# below on purpose: posh-git also defines its own `prompt` function to show
# git status, and Starship's `init` redefines `prompt` again right after
# this - so whichever runs last wins. Starship already shows git status in
# the prompt itself; this block would otherwise fight it for the same line.
Import-Module posh-git -ErrorAction SilentlyContinue

# ============================================================
# Starship
# https://starship.rs/
# ============================================================
# The SAME starship.toml the Linux and macOS zsh fragments read - see
# bootstrap.ps1's Prompt config step, which deploys it here from the repo
# root, not from a per-platform copy. Set explicitly rather than trusted to
# Starship's own Windows default ({FOLDERID_RoamingAppData}\starship\
# config.toml, a different path than the ~/.config one the other two
# platforms use) - one path on every platform, matching one file.
$env:STARSHIP_CONFIG = Join-Path $env:USERPROFILE '.config\starship.toml'
if (Get-Command starship -ErrorAction SilentlyContinue) {
    Invoke-Expression (&starship init powershell)

    # Once a command is submitted, collapse that now-historical prompt line
    # to a single arrow instead of leaving the full bar - path, git branch/
    # status, language versions, clock - sitting in the scrollback forever.
    # Same job the old prompt-theme.omp.json fork did for Oh My Posh, but a
    # real Starship feature now rather than something forked in to get it:
    # `[profiles] transient` in starship.toml is what the character below
    # renders. Function name and the Enable- call are both fixed by
    # Starship's own PowerShell integration, not a choice made here.
    function Invoke-Starship-TransientFunction {
        &starship module character
    }
    Enable-TransientPrompt
}

# ============================================================
# PowerToys "Command Not Found"
# https://learn.microsoft.com/windows/powertoys/cmd-not-found
# ============================================================
# Suggests a winget package to install when a command is not found.
#
# PowerToys writes this import into the profile itself from its settings UI,
# fenced between two comment lines carrying a fixed GUID. That does not
# survive a managed profile: the redeployed file replaces it, and because the
# replacement carries the "managed by" marker there is no .bak either - it
# would be silently removed on every run, forever. Carried here instead, so
# the feature is declared rather than injected.
#
# If PowerToys ever re-adds its own GUID-fenced copy, delete that block; this
# line already does the same job. Importing twice is harmless but pointless.
#
# Effectively PS7-only: it plugs into the feedback-provider subsystem, which
# does not exist in Windows PowerShell 5.1. Guarded rather than branched, so
# 5.1 simply skips it the same way it skips CompletionPredictor above.
Import-Module -Name Microsoft.WinGet.CommandNotFound -ErrorAction SilentlyContinue

# ============================================================
# tools -- list every package this fleet's bootstrap manages
# ============================================================
# Generated next to this profile by bootstrap.ps1's shell phase, from
# packages.psd1 as of the LAST run - same idea as the cat/ls/find/grep
# functions above, baked in rather than looked up live. Absent until the
# first run that reaches the shell phase, hence the guard.
$toolsList = Join-Path $PSScriptRoot 'tools-list.ps1'
if (Test-Path $toolsList) { . $toolsList }
