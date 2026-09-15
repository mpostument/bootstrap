
@{
    Groups = @(
        @{
            Name        = 'shell'
            Description = 'Terminal, prompt and the PowerShell host itself'
            Packages    = @(
                'Microsoft.PowerShell'
                'Microsoft.WindowsTerminal'
                'Starship.Starship'
                'Atuinsh.Atuin'
                'rsteube.Carapace'
                'gerardog.gsudo'
            )
        }

        @{
            Name        = 'cli'
            Description = 'Modern CLI bundle - nicer cat, ls, find and grep'
            Packages    = @(
                'sharkdp.bat'
                'dandavison.delta'
                'Wilfred.difftastic'
                'eza-community.eza'
                'sharkdp.fd'
                'BurntSushi.ripgrep.MSVC'
                'ajeetdsouza.zoxide'
                'junegunn.fzf'
                'jqlang.jq'
                'MikeFarah.yq'
                '7zip.7zip'
                'yt-dlp.yt-dlp'
                'yt-dlp.FFmpeg'
                'dalance.procs'
                'bootandy.dust'
                'muesli.duf'
                'charmbracelet.glow'
                'tstack.lnav'
            )
        }

        @{
            Name        = 'dev'
            Description = 'Editors, runtimes and language toolchains'
            Packages    = @(
                'Microsoft.VisualStudioCode'
                'Git.Git'
                'GitHub.cli'
                'JetBrains.Toolbox'
                'Microsoft.WSL'
                'Canonical.Ubuntu'
                'Python.Python.3.14'
                'Python.Launcher'
                'OpenJS.NodeJS.LTS'
                'DenoLand.Deno'
                'Microsoft.DotNet.SDK.10'
                'GoLang.Go'
                'Microsoft.OpenJDK.21'
                'jdx.mise'
                'astral-sh.uv'
                'koalaman.shellcheck'
            )
        }

        @{
            Name        = 'infra'
            Description = 'Configuration management and linting'
            Packages    = @(
                'TerraformLinters.tflint'
                'Terraform-docs.Terraform-docs'
            )
        }

        @{
            Name        = 'cloud'
            Description = 'Cloud and Kubernetes CLIs'
            Packages    = @(
                'Kubernetes.kubectl'
                'Kubecolor.kubecolor'
                'Helm.Helm'
                'Derailed.k9s'
                'stern.stern'
                'Amazon.AWSCLI'
                'Microsoft.AzureCLI'
                'Google.CloudSDK'
            )
        }

        @{
            Name        = 'network'
            Description = 'Network diagnostics - route and latency'
            Packages    = @(
                'FujiApple.Trippy'
                'orf.gping'
                'Insecure.Nmap'
            )
        }

        @{
            Name        = 'creative'
            Description = '3D, 2D and capture tooling'
            Packages    = @(
                'BlenderFoundation.Blender'
                'Unity.UnityHub'
                'Celsys.ClipStudioPaint'
                'NickeManarin.ScreenToGif'
                'Flameshot.Flameshot'
                'OBSProject.OBSStudio'
                'SoftFever.OrcaSlicer'
                'Creality.CrealityPrint'
            )
        }

        @{
            Name        = 'apps'
            Description = 'Everyday desktop applications'
            Packages    = @(
                'Google.Chrome'
                'Bitwarden.Bitwarden'
                'Bitwarden.CLI'
                'Microsoft.PowerToys'
                'Valve.Steam'
                'Telegram.TelegramDesktop'
                'Obsidian.Obsidian'
                'ONLYOFFICE.DesktopEditors'
                'Anthropic.Claude'
                'Bruno.Bruno'
                'DBeaver.DBeaver.Community'
                'SumatraPDF.SumatraPDF'
                'VideoLAN.VLC'
                'shinchiro.mpv'
                'Rufus.Rufus'
                'qBittorrent.qBittorrent'
                'Ubisoft.Connect'
                'Zoom.Zoom.EXE'
            )
        }
    )

    Pins = @{
    }

    Managed = @(
        @{
            Id     = 'Unity editors'
            By     = 'Unity Hub'
            Detect = 'Unity [0-9]*'
            Note   = 'often installed side by side on purpose - several major versions at once'
        }
        @{
            Id     = 'Rider'
            By     = 'JetBrains Toolbox'
            Detect = 'JetBrains Toolbox (Rider)*'
            Note   = 'Toolbox self-updates it; winget also publishes JetBrains.Rider, which would fight it'
        }
        @{
            Id     = 'Android Studio'
            By     = 'JetBrains Toolbox'
            Detect = 'JetBrains Toolbox (AndroidStudio)*'
            Note   = 'same Toolbox instance as Rider'
        }
    )

    # Curated from `code --list-extensions` on this machine, minus duplicates
    # (docker.docker over the two ms-azuretools Docker/Container Tools
    # extensions, GitLens over donjayamanne.githistory, hashicorp.terraform
    # already bundles HCL, the python extension pack over its loose parts).
    # Install-only: never uninstalls an extension that isn't listed here.
    VsCodeExtensions = @(
        'aaron-bond.better-comments'
        'anthropic.claude-code'
        'christian-kohler.path-intellisense'
        'codezombiech.gitignore'
        'davidanson.vscode-markdownlint'
        'docker.docker'
        'eamodio.gitlens'
        'github.vscode-pull-request-github'
        'golang.go'
        'hashicorp.terraform'
        'ms-azuretools.vscode-azureterraform'
        'ms-dotnettools.csdevkit'
        'ms-dotnettools.csharp'
        'ms-dotnettools.vscode-dotnet-runtime'
        'ms-kubernetes-tools.vscode-kubernetes-tools'
        'ms-python.debugpy'
        'ms-python.python'
        'ms-python.vscode-pylance'
        'ms-vscode-remote.remote-containers'
        'ms-vscode-remote.remote-ssh'
        'ms-vscode-remote.remote-ssh-edit'
        'ms-vscode-remote.remote-wsl'
        'ms-vscode-remote.vscode-remote-extensionpack'
        'ms-vscode.powershell'
        'ms-vscode.remote-explorer'
        'ms-vscode.remote-server'
        'redhat.vscode-commons'
        'redhat.vscode-yaml'
        'visualstudiotoolsforunity.vstuc'
        'vscode-icons-team.vscode-icons'
        'yzhang.markdown-all-in-one'
    )

    Schedule = @{
        Enabled  = $true
        TaskName = 'windows-bootstrap daily update'

        Time     = '04:20'

        LogDir       = 'windows-bootstrap\logs'
        KeepLogDays  = 30
    }

    Git = @{
        LfsEnabled = $true

        DeltaEnabled = $true

        DifftasticEnabled = $true

        UnityMergeEnabled = $true
        UnityEditorRoot   = 'C:\Program Files\Unity\Hub\Editor'
        UnityMergeRelPath = 'Editor\Data\Tools\UnityYAMLMerge.exe'
    }

    Shell = @{
        NerdFont          = 'Meslo'
        TerminalFontFace  = 'MesloLGM Nerd Font Mono'
        TerminalFontSize  = 14
        TerminalColorScheme = 'Catppuccin Mocha'
        TerminalColorSchemeDef = @{
            name                = 'Catppuccin Mocha'
            background          = '#1E1E2E'
            foreground          = '#CDD6F4'
            cursorColor         = '#F5E0DC'
            selectionBackground = '#585B70'
            black               = '#45475A'
            red                 = '#F38BA8'
            green               = '#A6E3A1'
            yellow              = '#F9E2AF'
            blue                = '#89B4FA'
            purple              = '#F5C2E7'
            cyan                = '#94E2D5'
            white               = '#BAC2DE'
            brightBlack         = '#585B70'
            brightRed           = '#F38BA8'
            brightGreen         = '#A6E3A1'
            brightYellow        = '#F9E2AF'
            brightBlue          = '#89B4FA'
            brightPurple        = '#F5C2E7'
            brightCyan          = '#94E2D5'
            brightWhite         = '#A6ADC8'
        }
        TerminalCopyOnSelect = $true
        TerminalPadding    = '10, 10'
        TerminalHistorySize = 100000
        TerminalPwshGuid  = '{574e775e-4f2a-5b96-ac1e-a2962a402336}'
        Modules51         = @('PSReadLine', 'Terminal-Icons', 'PSFzf', 'posh-git')
        Modules7          = @('PSReadLine', 'Terminal-Icons', 'PSFzf', 'CompletionPredictor', 'posh-git')
        PSReadLineMinimum = '2.4.5'
    }

    Mpv = @{
        AddToPath = $true

        Addons = @(
            @{
                Name   = 'uosc'
                Source = 'release'
                Repo   = 'tomasklaen/uosc'
                Kind   = 'zip'
                Url    = 'https://github.com/tomasklaen/uosc/releases/download/{0}/uosc.zip'
            }
            @{
                Name   = 'thumbfast'
                Source = 'commit'
                Repo   = 'po5/thumbfast'
                Kind   = 'script'
                File   = 'thumbfast.lua'
                Url    = 'https://raw.githubusercontent.com/po5/thumbfast/{0}/thumbfast.lua'
            }
            @{
                Name   = 'autoload'
                Source = 'commit'
                Repo   = 'mpv-player/mpv'
                Path   = 'TOOLS/lua/autoload.lua'
                Kind   = 'script'
                File   = 'autoload.lua'
                Url    = 'https://raw.githubusercontent.com/mpv-player/mpv/{0}/TOOLS/lua/autoload.lua'
            }
            @{
                Name   = 'chapterskip'
                Source = 'commit'
                Repo   = 'dyphire/mpv-scripts'
                Path   = 'chapterskip.lua'
                Kind   = 'script'
                File   = 'chapterskip.lua'
                Url    = 'https://raw.githubusercontent.com/dyphire/mpv-scripts/{0}/chapterskip.lua'
            }
            @{
                Name   = 'auto-save-state'
                Source = 'commit'
                Repo   = 'dyphire/mpv-scripts'
                Path   = 'auto-save-state.lua'
                Kind   = 'script'
                File   = 'auto-save-state.lua'
                Url    = 'https://raw.githubusercontent.com/dyphire/mpv-scripts/{0}/auto-save-state.lua'
            }
            @{
                Name   = 'memo'
                Source = 'commit'
                Repo   = 'po5/memo'
                Kind   = 'script'
                File   = 'memo.lua'
                Url    = 'https://raw.githubusercontent.com/po5/memo/{0}/memo.lua'
            }
        )
    }

}
