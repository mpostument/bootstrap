# PowerShell profile - managed by windows/bootstrap.ps1

# Force UTF-8 everywhere: console I/O, and cmdlets that write files (Out-File, Set-Content, etc.)
# default to the system codepage otherwise, which mangles emoji/box-drawing chars from tools
# like starship, eza, and Terminal-Icons into mojibake (e.g. "≡ƒÄ»" instead of a target emoji).
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
try { Set-PSReadLineOption -PredictionViewStyle ListView } catch { }
Set-PSReadLineOption -EditMode Windows
Set-PSReadLineOption -BellStyle None
Set-PSReadLineOption -HistoryNoDuplicates
Set-PSReadLineOption -HistorySearchCursorMovesToEnd
Set-PSReadLineOption -MaximumHistoryCount 1000000
Set-PSReadLineOption -Colors @{ InlinePrediction = '#5A5A5A' }

Set-PSReadLineKeyHandler -Key UpArrow -Function HistorySearchBackward
Set-PSReadLineKeyHandler -Key DownArrow -Function HistorySearchForward
Set-PSReadLineKeyHandler -Key Tab -Function MenuComplete
Set-PSReadLineKeyHandler -Key Ctrl+RightArrow -Function ForwardWord
Set-PSReadLineKeyHandler -Key Ctrl+LeftArrow -Function BackwardWord
Set-PSReadLineKeyHandler -Key RightArrow -Function ForwardChar

# Terminal-Icons -- file-type icons in Get-ChildItem / ls output
# https://github.com/devblackops/Terminal-Icons
Import-Module Terminal-Icons -ErrorAction SilentlyContinue

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

# mise -- one version manager for Python, Node, Go, Java and the Terraform
# family, driven by a per-project .mise.toml. https://mise.jdx.dev
# Windows has no pyenv/nvm to replace; mise sits alongside the winget-installed
# runtimes and wins for any tool a .mise.toml in the current tree pins.
if (Get-Command mise -ErrorAction SilentlyContinue) {
    Invoke-Expression (& { (mise activate pwsh | Out-String) })
}

# posh-git -- tab-completion for git subcommands, branches and remotes
# https://github.com/dahlbyk/posh-git
Import-Module posh-git -ErrorAction SilentlyContinue

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
        kube      = @('kubectl', 'k', 'kubectx', 'kubens', 'kustomize', 'k9s', 'stern',
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
