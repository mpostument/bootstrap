# PowerShell profile - managed by windows/bootstrap.ps1

# Force UTF-8 everywhere: console I/O, and cmdlets that write files (Out-File, Set-Content, etc.)
# default to the system codepage otherwise, which mangles emoji/box-drawing chars from tools
# like starship and eza into mojibake (e.g. "≡ƒÄ»" instead of a target emoji).
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
[Console]::InputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8
$PSDefaultParameterValues['*:Encoding'] = 'utf8'

# PSReadLine
# https://learn.microsoft.com/powershell/module/psreadline
Import-Module PSReadLine -MinimumVersion 2.4.5 -Force -ErrorAction SilentlyContinue
Import-Module CompletionPredictor -ErrorAction SilentlyContinue

try {
    Set-PSReadLineOption -PredictionSource HistoryAndPlugin -ErrorAction Stop
} catch {
    try { Set-PSReadLineOption -PredictionSource History } catch { }
}
# ListView by default: the full dropdown of matches. F2 flips to InlineView
# (a single greyed suggestion on the current line, like zsh/bash autosuggestions)
# on demand.
Set-PSReadLineOption -PredictionViewStyle ListView
Set-PSReadLineOption -EditMode Windows
Set-PSReadLineOption -BellStyle None
Set-PSReadLineOption -HistoryNoDuplicates
Set-PSReadLineOption -HistorySearchCursorMovesToEnd
Set-PSReadLineOption -MaximumHistoryCount 1000000
Set-PSReadLineOption -Colors @{ InlinePrediction = '#5A5A5A' }

Set-PSReadLineKeyHandler -Key UpArrow -Function HistorySearchBackward
Set-PSReadLineKeyHandler -Key DownArrow -Function HistorySearchForward
# F2: flip to InlineView on demand.
Set-PSReadLineKeyHandler -Key F2 -Function SwitchPredictionView
Set-PSReadLineKeyHandler -Key Tab -Function MenuComplete
Set-PSReadLineKeyHandler -Key Ctrl+RightArrow -Function ForwardWord
Set-PSReadLineKeyHandler -Key Ctrl+LeftArrow -Function BackwardWord
Set-PSReadLineKeyHandler -Key RightArrow -Function ForwardChar

# fzf colours: Catppuccin Mocha, the palette starship.toml, the Windows
# Terminal scheme and atuin use. Set before PSFzf, which shells out to fzf and
# inherits it. https://github.com/catppuccin/fzf
$env:FZF_DEFAULT_OPTS = @(
    '--color=bg+:#313244,bg:#1e1e2e,spinner:#f5e0dc,hl:#f38ba8'
    '--color=fg:#cdd6f4,header:#f38ba8,info:#cba6f7,pointer:#f5e0dc'
    '--color=marker:#b4befe,fg+:#cdd6f4,prompt:#cba6f7,hl+:#f38ba8'
    '--color=selected-bg:#45475a,border:#6c7086,label:#cdd6f4'
) -join ' '

# Previews: Ctrl+T shows the file in bat, Alt+C the directory as an eza tree.
# PSFzf appends these to FZF_DEFAULT_OPTS for that one key. The file list itself
# stays PSFzf's default - fzf's native walker, relative paths from the path under
# the cursor; its fd mode would insert absolute ones. fzf runs the preview through
# cmd.exe, hence no `| head` after eza - --level=2 is what bounds it.
if (Get-Command bat -ErrorAction SilentlyContinue) {
    $env:FZF_CTRL_T_OPTS = "--preview 'bat --color=always --style=numbers --line-range=:300 {}' --preview-window=right,60%,border-left"
}
if (Get-Command eza -ErrorAction SilentlyContinue) {
    $env:FZF_ALT_C_OPTS = "--preview 'eza --tree --level=2 --color=always --icons=auto {}'"
}

# PSFzf -- fuzzy history (Ctrl+R), file (Ctrl+T) and git completion
# https://github.com/kelleyma49/PSFzf
if (Get-Command fzf -ErrorAction SilentlyContinue) {
    try {
        Import-Module PSFzf -ErrorAction Stop
        # Ctrl+R goes to atuin when it is installed - it searches the same history
        # with more to filter on. PSFzf keeps Ctrl+T (files) either way.
        if (Get-Command atuin -ErrorAction SilentlyContinue) {
            Set-PsFzfOption -PSReadlineChordProvider 'Ctrl+t'
        } else {
            Set-PsFzfOption -PSReadlineChordProvider 'Ctrl+t' -PSReadlineChordReverseHistory 'Ctrl+r'
        }

        Set-PsFzfOption -TabExpansion

        # -TabExpansion only reaches git, through PowerShell's legacy TabExpansion
        # hook; it never binds the key. Tab stayed on MenuComplete (above), which
        # prints a flat list once the menu outgrows the window - kubectl's 46
        # described subcommands do. This hands Tab to fzf for every command. A
        # single match is inserted directly; Ctrl+Space is still MenuComplete.
        Set-PSReadLineKeyHandler -Key Tab -ScriptBlock { Invoke-FzfTabCompletion }

        Set-PsFzfOption -EnableAliasFuzzyHistory -EnableAliasFuzzyKillProcess
    } catch {
        Write-Warning "PSFzf failed to load (try closing and reopening the terminal): $($_.Exception.Message)"
    }
}

# zoxide -- smarter cd; `z <part-of-path>` jumps to your most-used match
# https://github.com/ajeetdsouza/zoxide
if (Get-Command zoxide -ErrorAction SilentlyContinue) {
    Invoke-Expression (& { (zoxide init powershell | Out-String) })
}

# atuin -- history in SQLite: exit code, duration, directory and session per
# command, searched with Ctrl+R. Optional end-to-end encrypted sync across machines.
# https://atuin.sh
# After PSFzf, so atuin's Ctrl+R is the binding that survives. Up/Down are then
# re-asserted because atuin's init claims UpArrow too, and HistorySearchBackward
# (prefix search on what you have already typed) is the better use of that key.
if (Get-Command atuin -ErrorAction SilentlyContinue) {
    Invoke-Expression (& { (atuin init powershell | Out-String) })
    Set-PSReadLineKeyHandler -Key UpArrow -Function HistorySearchBackward
    Set-PSReadLineKeyHandler -Key DownArrow -Function HistorySearchForward
}

# Modern CLI bundle -- nicer cat/ls/find/grep
# bat: https://github.com/sharkdp/bat | eza: https://github.com/eza-community/eza
if (Get-Command bat -ErrorAction SilentlyContinue) {
    Remove-Item Alias:cat -Force -ErrorAction SilentlyContinue
    function cat { bat --paging=never @args }
}
if (Get-Command eza -ErrorAction SilentlyContinue) {
    Remove-Item Alias:ls -Force -ErrorAction SilentlyContinue
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

if (Get-Command dust -ErrorAction SilentlyContinue) {
    function du { dust @args }
}
if (Get-Command duf -ErrorAction SilentlyContinue) {
    function df { duf @args }
}

# doggo -- dig's job with readable output. Windows has no dig at all, only
# Resolve-DnsName, so this adds the name rather than shadowing anything.
# https://github.com/mr-karan/doggo
if (Get-Command doggo -ErrorAction SilentlyContinue) {
    function dig { doggo @args }
}

# xh -- HTTP from the terminal. The tarball's `xhs` (xh --https) is a symlink
# upstream, so it is a function here instead. https://github.com/ducaale/xh
if (Get-Command xh -ErrorAction SilentlyContinue) {
    function http { xh @args }
    function https { xh --https @args }
}

# lazygit -- git TUI; lg is the name its own README suggests.
# https://github.com/jesseduffield/lazygit
if (Get-Command lazygit -ErrorAction SilentlyContinue) {
    function lg { lazygit @args }
}

# lazydocker -- the same TUI for containers; lzd is its README's name.
# https://github.com/jesseduffield/lazydocker
if (Get-Command lazydocker -ErrorAction SilentlyContinue) {
    function lzd { lazydocker @args }
}

# Workflow pickers: fzf over git branches, stashes and the tools list. Each one
# only picks; what runs afterwards is an ordinary git command. The zsh side has
# the same names, plus fkill - which PSFzf already provides here
# (-EnableAliasFuzzyKillProcess above), so it is not redefined.
if (Get-Command fzf -ErrorAction SilentlyContinue) {
    # gb - switch branch. Local and remote, newest commit first, log as preview.
    # A remote branch is checked out with --track, which makes the local branch.
    function gb {
        git rev-parse --git-dir *> $null
        if ($LASTEXITCODE -ne 0) { Write-Error 'gb: not a git repository'; return }
        $pick = git for-each-ref --sort=-committerdate '--format=%(refname:short)' refs/heads refs/remotes |
            Where-Object { $_ -notmatch '/HEAD$' } |
            fzf --height=50% --reverse --prompt='branch> ' --preview 'git log --oneline --graph --decorate --color=always -30 {}'
        if (-not $pick) { return }
        git show-ref --verify --quiet "refs/heads/$pick"
        if ($LASTEXITCODE -eq 0) { git switch $pick } else { git switch --track $pick }
    }

    # gs - browse stashes with the diff as preview (through delta when there is
    # one). Enter applies, ctrl-p pops, ctrl-x drops; apply is the default because
    # it leaves the stash behind. Not defined where Ghostscript owns gs.
    if (-not (Get-Command gs -CommandType Application -ErrorAction SilentlyContinue)) {
        function gs {
            git rev-parse --git-dir *> $null
            if ($LASTEXITCODE -ne 0) { Write-Error 'gs: not a git repository'; return }
            $show = 'git stash show -p --color=always {1}'
            if (Get-Command delta -ErrorAction SilentlyContinue) { $show = 'git stash show -p {1} | delta --paging=never' }
            # --expect prints the key that ended the pick on the first line, empty for Enter.
            $out = @(git stash list | fzf --height=60% --reverse --delimiter=: --prompt='stash> ' `
                --header='enter apply / ctrl-p pop / ctrl-x drop' --expect=ctrl-p,ctrl-x --preview $show)
            if ($out.Count -lt 2) { return }
            $pick = ($out[1] -split ':')[0]
            switch ($out[0]) {
                'ctrl-p' { git stash pop $pick }
                'ctrl-x' { git stash drop $pick }
                default  { git stash apply $pick }
            }
        }
    }

    # cheat - search the list `tools` prints. The preview is the command's tldr
    # page (its --help when there is none); the pick is shown as its tldr page,
    # since a running function cannot type onto the prompt the way zsh's print -z does.
    function cheat {
        if (-not $global:ToolsRows) { Write-Error 'cheat: the tools list is not loaded'; return }
        $lines = foreach ($r in $global:ToolsRows) {
            $page = ($r[1].Trim() -split '\s+')[0]
            if (-not $page) { continue }
            ('{0,-26} {1,-10} {2}' -f $r[0], $r[1], $r[2]) + "`t" + $page
        }
        $pick = $lines | fzf --delimiter "`t" --with-nth=1 --height=70% --reverse --prompt='tool> ' `
            --preview 'tldr --color always {2}'
        if ($pick) { tldr ($pick -split "`t")[-1] }
    }
}

# sd deliberately gets no `sed` alias: its pattern and replacement syntax is not
# sed's, so anything pasted from a script or a README would silently do
# something else. Call it as sd. https://github.com/chmln/sd

# mise -- one version manager for Python, Node, Go, Java and the Terraform
# family, driven by a per-project .mise.toml. https://mise.jdx.dev
# Windows has no pyenv/nvm to replace; mise sits alongside the winget-installed
# runtimes and wins for any tool a .mise.toml in the current tree pins.
if (Get-Command mise -ErrorAction SilentlyContinue) {
    Invoke-Expression (& { (mise activate pwsh | Out-String) })
}

# carapace -- flag and subcommand completion for 1000+ CLIs (kubectl, gh, az,
# helm...) through one engine. https://github.com/carapace-sh/carapace-bin
# CARAPACE_COLOR=0 because PSFzf's Tab list shows each completion's label as-is,
# so carapace's colours would arrive there as raw escape sequences. git is NOT
# excluded here, unlike the zsh platforms where zsh's own _git is better: on
# PowerShell carapace's git completer is the best available - branches by
# category for checkout/switch, only changed files for add/restore, remotes for
# push, and the repository's own aliases with their definitions as descriptions.
# PowerShell 7 only: Windows PowerShell 5.1 drops the empty argument carapace's
# completer passes for the word under the cursor, gets `[]` back and throws - so
# every Tab cost a carapace run and still ended in file names. 5.1 therefore has
# no git completion at all now that posh-git is gone; 7 is the default profile.
if ($PSVersionTable.PSVersion.Major -ge 7 -and (Get-Command carapace -ErrorAction SilentlyContinue)) {
    $env:CARAPACE_COLOR = '0'
    # carapace ends each value with a space (`get `) to move MenuComplete on to the
    # next argument. PSFzf quotes any completion containing whitespace and adds its
    # own space, so Tab produced `kubectl "get " ` and kubectl rejected `get `.
    # '*' drops carapace's space for every value; PSFzf still supplies one.
    $env:CARAPACE_NOSPACE = '*'
    Invoke-Expression (& { (carapace _carapace powershell | Out-String) })
}

# uv -- carapace has no completer for it, and uv's own PowerShell script is ~750 KB,
# ~200 ms to load in every new shell. A stub stands in: the first Tab after `uv`
# loads the real completer and answers through it from then on. The real one is
# captured, not registered, because a completer cannot re-run completion itself.
if (Get-Command uv -ErrorAction SilentlyContinue) {
    Register-ArgumentCompleter -Native -CommandName uv -ScriptBlock {
        param($wordToComplete, $commandAst, $cursorPosition)
        if (-not $script:UvCompleter) {
            function Register-ArgumentCompleter {
                param([switch]$Native, [string[]]$CommandName, [scriptblock]$ScriptBlock)
                $script:UvCompleter = $ScriptBlock
            }
            Invoke-Expression ((uv generate-shell-completion powershell) | Out-String)
        }
        & $script:UvCompleter $wordToComplete $commandAst $cursorPosition
    }
}

# mise -- its own completer, loaded on the first Tab the same way. mise's script
# cuts the command at the cursor with Extent.Text, but the extent ends at the last
# word, so after `mise ` it completed the word `mise` again (file names) instead of
# the next one. The text is padded back out to the cursor before it is handed over.
if (Get-Command mise -ErrorAction SilentlyContinue) {
    Register-ArgumentCompleter -Native -CommandName mise -ScriptBlock {
        param($wordToComplete, $commandAst, $cursorPosition)
        if (-not $script:MiseCompleter) {
            function Register-ArgumentCompleter {
                param([switch]$Native, [string[]]$CommandName, [scriptblock]$ScriptBlock)
                $script:MiseCompleter = $ScriptBlock
            }
            Invoke-Expression ((mise completion powershell) | Out-String)
        }
        $extent = $commandAst.Extent
        $width = [Math]::Max(0, $cursorPosition - $extent.StartOffset)
        $padded = [pscustomobject]@{
            Extent = [pscustomobject]@{ Text = $extent.Text.PadRight($width); StartOffset = $extent.StartOffset }
        }
        & $script:MiseCompleter $wordToComplete $padded $cursorPosition
    }
}

if (Get-Command kubectl -ErrorAction SilentlyContinue) {
    Set-Alias -Name k -Value kubectl
}

# trippy -- traceroute and ping in one live view. It needs Administrator on
# Windows; gsudo elevates just this command, in this window.
if ((Get-Command trip -ErrorAction SilentlyContinue) -and (Get-Command gsudo -ErrorAction SilentlyContinue)) {
    function trip { gsudo trip.exe @args }
}

# Starship
# https://starship.rs/
$env:STARSHIP_CONFIG = Join-Path $env:USERPROFILE '.config\starship.toml'
if (Get-Command starship -ErrorAction SilentlyContinue) {
    Invoke-Expression (&starship init powershell)

    function Invoke-Starship-TransientFunction {
        &starship module character
    }
    Enable-TransientPrompt

    # The right prompt, and the context that only appears while you type
    $script:StarshipCSI = "$([char]27)["
    $script:StarshipCtxGroup = ''
    $script:StarshipRightCol = 0

    $script:StarshipCtxMap = [ordered]@{
        kube      = @('kubectl', 'kubecolor', 'k', 'kubectx', 'kubens', 'kustomize', 'k9s', 'stern',
                      'helm', 'helmfile', 'flux', 'argocd', 'velero', 'skaffold', 'kubeseal')
        aws       = @('aws', 'aws-vault', 'awslocal', 'eksctl', 'sam', 'copilot',
                      'yawsso', 'saml2aws', 'granted', 'assume')
        azure     = @('az', 'azd', 'azcopy', 'func')
        gcloud    = @('gcloud', 'gsutil', 'bq', 'firebase', 'gke-gcloud-auth-plugin')
        terraform = @('terraform', 'tofu', 'terragrunt', 'tflint', 'terraform-docs',
                      'infracost', 'tfenv', 'tfswitch')
        dotnet    = @('dotnet', 'msbuild', 'nuget')
    }

    function Get-StarshipContextGroup {
        param([string]$Line)

        $words = @(($Line -split '\s+') | Where-Object { $_ })
        $skip = @('sudo', 'doas', 'command', 'env', 'time', 'nice', 'nohup', 'watch')
        while ($words.Count -gt 0 -and ($words[0] -like '*=*' -or $words[0] -in $skip)) {
            $words = @($words | Select-Object -Skip 1)
        }
        if ($words.Count -eq 0) { return '' }

        $cmd = $words[0]
        $slash = $cmd.LastIndexOfAny([char[]]@('\', '/'))
        if ($slash -ge 0) { $cmd = $cmd.Substring($slash + 1) }
        if ($cmd -match '\.(exe|cmd|bat|ps1)$') { $cmd = $cmd.Substring(0, $cmd.LastIndexOf('.')) }

        foreach ($group in $script:StarshipCtxMap.Keys) {
            if ($script:StarshipCtxMap[$group] -contains $cmd) { return $group }
        }
        if ($cmd -like 'kubectl-*') { return 'kube' }
        if ($cmd -like 'dotnet-*') { return 'dotnet' }
        return ''
    }

    function Get-StarshipRightPrompt {
        $promptArgs = @('prompt', "--terminal-width=$($Host.UI.RawUI.WindowSize.Width)")
        if ($script:StarshipCtxGroup) {
            $promptArgs += "--profile=ctx_$($script:StarshipCtxGroup)"
        } else {
            $promptArgs += '--right'
        }
        return ((&starship @promptArgs) -join '').TrimEnd("`r", "`n")
    }

    function Update-StarshipContext {
        $line = $null
        $cursor = 0
        [Microsoft.PowerShell.PSConsoleReadLine]::GetBufferState([ref]$line, [ref]$cursor)
        $group = Get-StarshipContextGroup $line
        if ($group -ne $script:StarshipCtxGroup) {
            $script:StarshipCtxGroup = $group
            [Microsoft.PowerShell.PSConsoleReadLine]::InvokePrompt()
        }
    }

    Set-PSReadLineKeyHandler -Chord 'Spacebar' -BriefDescription 'StarshipContextSpacebar' `
        -LongDescription 'Insert a space, then refresh the prompt context' -ScriptBlock {
        param($key, $arg)
        [Microsoft.PowerShell.PSConsoleReadLine]::SelfInsert($key, $arg)
        Update-StarshipContext
    }

    Set-PSReadLineKeyHandler -Chord 'Backspace' -BriefDescription 'StarshipContextBackspace' `
        -LongDescription 'Delete the previous character, then refresh the prompt context' -ScriptBlock {
        param($key, $arg)
        [Microsoft.PowerShell.PSConsoleReadLine]::BackwardDeleteChar($key, $arg)
        Update-StarshipContext
    }

    Set-PSReadLineKeyHandler -Chord 'Delete' -BriefDescription 'StarshipContextDelete' `
        -LongDescription 'Delete the character under the cursor, then refresh the prompt context' -ScriptBlock {
        param($key, $arg)
        [Microsoft.PowerShell.PSConsoleReadLine]::DeleteChar($key, $arg)
        Update-StarshipContext
    }

    $script:StarshipInnerPrompt = (Get-Item function:prompt).ScriptBlock
    if ($script:StarshipInnerPrompt) {
        function global:prompt {
            $left = & $script:StarshipInnerPrompt
            $dollarQuestion = $global:?
            $lastExit = $global:LASTEXITCODE

            $buffer = $null
            $bufferCursor = 0
            try {
                [Microsoft.PowerShell.PSConsoleReadLine]::GetBufferState([ref]$buffer, [ref]$bufferCursor)
                if ([string]::IsNullOrWhiteSpace($buffer)) { $script:StarshipCtxGroup = '' }
            } catch { }

            $left = [string]$left
            $out = $left
            $lead = [regex]::Match($left, '^[\r\n]+')
            $eraseOld = ''
            if ($script:StarshipRightCol -gt 0) {
                $eraseOld = "$($script:StarshipCSI)$($script:StarshipRightCol)G$($script:StarshipCSI)K"
            }

            if ($lead.Success) {
                $rest = $left.Substring($lead.Length)
                $right = Get-StarshipRightPrompt
                $plain = [regex]::Replace($right, "$([char]27)\[[0-9;]*[A-Za-z]", '')
                $col = $Host.UI.RawUI.WindowSize.Width - $plain.Length
                if ($plain.Length -gt 0 -and $col -gt 1) {
                    $out = $lead.Value + $eraseOld + "$($script:StarshipCSI)${col}G" + $right + "`r" + $rest
                    $script:StarshipRightCol = $col
                } elseif ($eraseOld) {
                    $out = $lead.Value + $eraseOld + "`r" + $rest
                    $script:StarshipRightCol = 0
                }
            } else {
                if ($eraseOld) { $out = $eraseOld + "`r" + $left }
                $script:StarshipRightCol = 0
                $script:StarshipCtxGroup = ''
            }

            $out

            $global:LASTEXITCODE = $lastExit
            if ($dollarQuestion) { $null = 1 + 1 } else { Write-Error '' -ErrorAction 'Ignore' }
        }
    }
}

# PowerToys "Command Not Found"
# https://learn.microsoft.com/windows/powertoys/cmd-not-found
Import-Module -Name Microsoft.WinGet.CommandNotFound -ErrorAction SilentlyContinue

# tools -- list every package this fleet's bootstrap manages
$toolsList = Join-Path $PSScriptRoot 'tools-list.ps1'
if (Test-Path $toolsList) { . $toolsList }
