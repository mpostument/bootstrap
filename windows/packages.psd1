# Software manifest for bootstrap.ps1. Data only - Import-PowerShellDataFile
# refuses to evaluate expressions, so this file cannot execute anything even
# if it is edited badly.
#
# Why .psd1: the only thing that reads this file is PowerShell, which has no
# YAML parser without a third-party module. Import-PowerShellDataFile is built
# in, supports comments, and is safe. JSON would have cost the comments, which
# on a list like this are the most valuable part.
#
# THREE categories, because a desktop genuinely has three kinds of software
# and treating them alike is what breaks things:
#
#   Groups   winget owns it. Installed if missing, upgraded on every run.
#   Pins     Hands off the version entirely - never installed, never
#            upgraded, only reported. For packages where "latest" is a
#            decision you want to make yourself rather than inherit.
#   Managed  Something OTHER than winget owns it. Verified and reported,
#            never installed and never upgraded.
#
# To add a package: find its id with `winget search <name>`, put it in a
# group, re-run bootstrap.ps1. To stop a package moving: add it to Pins with
# a reason. Reasons are required by convention, not by the parser - a pin
# nobody can explain later is a pin nobody dares remove.

@{
    # Order is preserved and is the install order. shell first so that a
    # cold machine gets a working terminal before the long downloads start.
    Groups = @(
        @{
            Name        = 'shell'
            Description = 'Terminal, prompt and the PowerShell host itself'
            Packages    = @(
                'Microsoft.PowerShell'
                'Microsoft.WindowsTerminal'
                'JanDeDobbeleer.OhMyPosh'
                # A working `sudo` for Windows - elevate one command without
                # spawning a whole separate admin window/profile the way
                # `Start-Process -Verb RunAs` does. Not in the `cli` group:
                # it is a shell-elevation tool, not part of the modern-CLI
                # bundle, and Linux/macOS need no equivalent package since
                # `sudo` already ships there - see tools/cli-parity.conf.
                'gerardog.gsudo'
            )
        }

        @{
            Name        = 'cli'
            Description = 'Modern CLI bundle - nicer cat, ls, find and grep'
            # Kept deliberately in step with the zsh setup on the Linux side of
            # other shells you use. When a tool is added to one shell it belongs in the
            # other, or muscle memory stops transferring between them.
            Packages    = @(
                'sharkdp.bat'
                'eza-community.eza'
                'sharkdp.fd'
                'BurntSushi.ripgrep.MSVC'
                'ajeetdsouza.zoxide'
                'junegunn.fzf'
                'jqlang.jq'
                # yq alongside jq, and on the Linux side too: the fleet's
                # playbooks and CI are YAML, so the two get reached for in
                # the same breath.
                'MikeFarah.yq'
                '7zip.7zip'
                'yt-dlp.yt-dlp'
                'yt-dlp.FFmpeg'
            )
        }

        @{
            Name        = 'dev'
            Description = 'Editors, runtimes and language toolchains'
            # Microsoft.WSL and Canonical.Ubuntu get WSL and a distro onto the
            # disk. On a genuinely
            # fresh machine that is not quite the whole job: the Virtual
            # Machine Platform optional component has to be on as well, and
            # the distro needs a first launch to create its user. bootstrap.ps1
            # reports the gap rather than enabling Windows features and
            # rebooting behind your back - run `wsl --install` once, then
            # launch Ubuntu, and this pair keeps it updated from then on.
            Packages    = @(
                'Microsoft.VisualStudioCode'
                'Git.Git'
                'GitHub.cli'
                'JetBrains.Toolbox'
                'Microsoft.WSL'
                'Canonical.Ubuntu'
                # The newest stable line, not the one the machine happens to
                # have. Python.Launcher below is what makes that safe: `py`
                # picks between whatever is installed, and a project pinned
                # to an older minor keeps working through `py -3.12`.
                #
                # Changing this id does NOT remove the previous version -
                # nothing here ever uninstalls - so an older Python stays on
                # disk and simply stops being upgraded by this script.
                'Python.Python.3.14'
                'Python.Launcher'
                # The LTS channel, not the current-release one, and that is
                # the whole Node version policy - no pin required. LTS never
                # ships a major bump mid-line, so a routine "take every
                # upgrade" run cannot walk the toolchain from 24.x to 26.x on
                # a morning when nobody changed anything. It still takes patch
                # and minor releases, which is what you actually want.
                #
                # It is also simply newer than the plain id for this line:
                # OpenJS.NodeJS is on 26.x and its 24.x versions have aged out
                # of the catalogue at 24.10.0, while OpenJS.NodeJS.LTS is on
                # 24.19.0.
                'OpenJS.NodeJS.LTS'
                'DenoLand.Deno'
                'Microsoft.DotNet.SDK.10'
                'GoLang.Go'
                # Microsoft's build of OpenJDK rather than Oracle's: same
                # OpenJDK sources, no click-through licence, and it is the
                # one that matches what the Linux side gets from the
                # distribution's default-jdk.
                'Microsoft.OpenJDK.21'
                # OpenTofu, not Terraform: HashiCorp's BSL relicensing and its
                # 2025 IBM acquisition are the same case as Bruno over
                # Postman. `tofu` on PATH instead of `terraform`.
                'OpenTofu.Tofu'
            )
        }


        @{
            Name        = 'cloud'
            Description = 'Cloud and Kubernetes CLIs'
            # Kept in step with the Linux and macOS manifests so the same
            # commands exist wherever you land - the same reason the cli group
            # is identical across the three.
            #
            # stern is deliberately absent: it has no winget package, and an id
            # that does not resolve fails on every single run rather than once.
            # `scoop install stern` or a release binary from stern/stern if you
            # need it here.
            Packages    = @(
                'Kubernetes.kubectl'
                'Helm.Helm'
                # Capital D. winget is invoked with -e, so the id is matched
                # EXACTLY - 'derailed.k9s' returns "No package found matching
                # input criteria" rather than resolving case-insensitively.
                'Derailed.k9s'
                # v2. Amazon.AWSCLI is the v2 line; there is no separate v2 id.
                'Amazon.AWSCLI'
                'Microsoft.AzureCLI'
                # winget cannot parse this one's installed version - it lists it
                # without a number - so a plain run reports it as `skipped`
                # rather than upgrading it, exactly like Ubisoft.Connect in the
                # apps group.
                #
                # That is correct and not a gap. The SDK updates itself through
                # `gcloud components update`, so forcing winget past it with
                # -IncludeUnknown would put two installers on one package, which
                # is the thing this manifest avoids everywhere else.
                'Google.CloudSDK'
            )
        }

        @{
            Name        = 'creative'
            Description = '3D, 2D and capture tooling'
            # Unity Hub only. The EDITORS are under Managed below - installing
            # a Unity editor through winget is how you end up fighting the Hub
            # for ownership of a version some project pins.
            Packages    = @(
                'BlenderFoundation.Blender'
                'Unity.UnityHub'
                'Celsys.ClipStudioPaint'
                'NickeManarin.ScreenToGif'
                # The other end of the capture scale from ScreenToGif above:
                # ScreenToGif is for a short clip to drop into an issue, OBS is
                # for actual recording and streaming. Both on purpose - neither
                # is a worse version of the other.
                'OBSProject.OBSStudio'
                'SoftFever.OrcaSlicer'
                'Creality.CrealityPrint'
            )
        }

        @{
            Name        = 'apps'
            Description = 'Everyday desktop applications'
            # Google.Chrome is winget-managed here by choice, even though the
            # copy on a machine was often installed outside winget (it shows as
            # ARP\Machine\X86\Google Chrome with no winget id, so winget has
            # not correlated it). The first run therefore installs over the
            # top rather than adopting cleanly - which is fine, Chrome's
            # installer handles that, and afterwards it is a normal winget
            # package like everything else here. Expect one UAC prompt and a
            # full download that first time only.
            Packages    = @(
                'Google.Chrome'
                'Microsoft.PowerToys'
                'Valve.Steam'
                'Telegram.TelegramDesktop'
                'Obsidian.Obsidian'
                # Next to Obsidian on purpose - both are where thinking gets
                # written down rather than where work runs. This is the
                # DESKTOP app; Claude Code is a separate id (Anthropic.
                # ClaudeCode) and is not managed here, because the copy on this
                # machine was not installed through winget.
                #
                # Per-user installer, into %LOCALAPPDATA%, so unlike most of
                # this group it raises no UAC prompt and works on an
                # unelevated run.
                'Anthropic.Claude'
                # API client. Bruno over Postman: collections are plain-text
                # files that diff in git, not a vendor account.
                'Bruno.Bruno'
                'VideoLAN.VLC'
                # VLC and mpv both, on purpose. VLC opens anything and is the
                # one to hand somebody else; mpv is the one configured for
                # actually watching things - see the Mpv section below, and
                # windows/mpv/mpv.conf for the cache tuning that matters when
                # the file is coming over a network share.
                'shinchiro.mpv'
                # Writes bootable USB media. The general tool rather than a
                # vendor-specific imager, which is the right trade when you
                # write an image rarely and for varied targets.
                'Rufus.Rufus'
                # Plain id, not the Enhanced Edition or the -lt2- build -
                # those are different libtorrent lineages.
                #
                # Worth knowing if you also play media off a share this writes
                # to: in-progress files carry a .!qB extension, which is why
                # mpv/script-opts/autoload.conf ignores that pattern. Without
                # it a half-downloaded file joins the playlist.
                'qBittorrent.qBittorrent'
                # Uplay, renamed - the winget id is Ubisoft.Connect and there
                # is no 'uplay' package to find.
                #
                # It is one of the packages whose installed version winget
                # cannot parse: `winget list` reports it with a leading "<",
                # not a number. That means a plain run will NOT upgrade it -
                # only `-IncludeUnknown` will, and that flag is off by default
                # here for the good reason given in bootstrap.ps1's help. So
                # expect this one to sit at whatever Ubisoft's own launcher
                # last installed, which it updates itself anyway.
                'Ubisoft.Connect'
                # .EXE, not the plain Zoom.Zoom. winget publishes both and
                # they are the same product in two installer flavours - but
                # the copy on this machine came from the EXE manifest, and
                # naming the other one would install a second Zoom beside it
                # rather than upgrading the one that is there.
                'Zoom.Zoom.EXE'
            )
        }
    )

    # id -> why it is held. Neither installed nor upgraded; reported as "held"
    # so it stays visible rather than quietly absent from the run.
    #
    # Empty on purpose. Node used to live here, pinned because a hand-installed
    # 24.x sat outside winget where the script could not see it. That pin then
    # outlived the install it was protecting: once Node was uninstalled the
    # entry went on refusing to install it AND went on reporting "installed
    # outside winget at 24.x", which was no longer true of anything on disk.
    #
    # That is the failure mode a pin has by design. It is hands-off in BOTH
    # directions - never upgraded, and never installed either, because "install
    # the latest because none is here" is the same major-version decision the
    # pin exists to keep out of a script - so it cannot notice that the world
    # moved. Prefer a package id whose CHANNEL encodes the rule (see
    # OpenJS.NodeJS.LTS in the dev group) and pin only when no such id exists.
    #
    # To move a pin: remove the entry, run once, and put it back.
    Pins = @{
    }

    # Owned by another installer. bootstrap.ps1 reports on these and does not
    # touch them. Detect is matched against the registry uninstall key NAME
    # (PSChildName), not the display name, because Toolbox suffixes each key
    # with a per-install GUID that differs on every machine.
    #
    # Report-only in BOTH directions - nothing here is ever installed or
    # upgraded. That is the whole point for Unity and JetBrains, whose real
    # owners would fight winget over them, and it is also the reason software
    # that merely happens to be missing from winget does NOT belong here:
    # an entry that can only ever print a version it will never change is
    # inventory, not configuration.
    Managed = @(
        @{
            Id     = 'Unity editors'
            By     = 'Unity Hub'
            # 'Unity [0-9]*' and not 'Unity *': the latter also matches the
            # "Unity Hub 3.21.1" uninstall key, and the Hub IS a winget
            # package in the creative group above - it would be reported
            # twice, in two different categories, saying different things.
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

    # Consumed by the schedule phase: a daily unattended run, so updates
    # arrive without anyone remembering to ask for them.
    #
    # Enabled = $false leaves Task Scheduler completely alone; the phase then
    # reports what it would have registered and does nothing. -SkipSchedule
    # does the same for one run.
    Schedule = @{
        Enabled  = $true
        TaskName = 'windows-bootstrap daily update'

        # 24-hour HH:mm. Not on the hour, and not at a time the machine is
        # likely to be mid-something: a run that fires while you are working
        # pops installer windows over whatever you are doing.
        Time     = '04:20'

        # Under %LOCALAPPDATA%. One file per day, so a failure three days ago
        # is still readable, and anything older than KeepLogDays is pruned on
        # each run - a daily task left alone for a year is otherwise 365 files.
        LogDir       = 'windows-bootstrap\logs'
        KeepLogDays  = 30
    }


    # Consumed by the git phase. Two things Unity needs from git that nothing
    # else sets up, and that cost real work when they are missing.
    Git = @{
        # `git lfs install` writes the clean/smudge/process filters into the
        # global config. Installing the binary is NOT enough - without the
        # filters, LFS pointer files are checked out as their text stubs and a
        # Unity project full of them simply does not open.
        #
        # Git for Windows bundles git-lfs in its own installer, so there is no
        # winget package here on purpose: adding GitHub.GitLFS would put a
        # second copy on the machine for winget to fight Git.Git over.
        LfsEnabled = $true

        # Unity's own three-way merge tool for scenes and prefabs.
        #
        # This is the difference between a merge conflict in a .unity file
        # being resolvable and not. Those files are enormous auto-generated
        # YAML with unstable ordering; git's line-based merge cannot do
        # anything sensible with them, so without this the practical answer to
        # a scene conflict is to pick a side and redo the other person's work.
        #
        # Registered as a MERGETOOL, not a merge driver. A driver would run
        # automatically on every merge in every repository, and one that cannot
        # find its executable breaks the merge; a mergetool is invoked
        # deliberately with `git mergetool` and is inert until you ask.
        UnityMergeEnabled = $true
        # Unity Hub installs each editor under here, side by side - which is
        # exactly what the Managed section above says happens on purpose. The
        # newest one that actually carries the tool wins.
        UnityEditorRoot   = 'C:\Program Files\Unity\Hub\Editor'
        UnityMergeRelPath = 'Editor\Data\Tools\UnityYAMLMerge.exe'
    }

    # Consumed by the shell phase: the Nerd Font, the Oh My Posh theme
    # directory, the modules installed per PowerShell edition, and the Windows
    # Terminal settings the merge script patches - font face and size, the
    # colour scheme, copy-on-select, padding and scrollback. Kept in step with
    # the Ghostty knobs on the Unix side so a fleet running both feels the
    # same on either terminal.
    Shell = @{
        NerdFont          = 'Meslo'
        TerminalFontFace  = 'MesloLGM Nerd Font Mono'
        # WT's default is 12. Deliberately not the 16 ghostty/iTerm2 use on
        # the other two platforms - 14 is the size actually used on Windows.
        TerminalFontSize  = 14
        # A name that also has to appear in the schemes[] array of the merged
        # settings.json. The merge script writes both together: the reference
        # here, and the palette itself below, so a change to the name lands
        # atomically. Catppuccin Mocha is the widely used dark across dev
        # tooling in 2026, matching the ghostty side.
        TerminalColorScheme = 'Catppuccin Mocha'
        # The colours the merge script writes into settings.json under
        # schemes[] when the named scheme is missing. Values are the official
        # Catppuccin Mocha palette; changing them here changes what gets
        # written, but never overwrites a scheme somebody has hand-edited
        # under the same name - the merge is name-keyed on ADD, not replace.
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
        # $true copies the selection to the actual clipboard - Ctrl-V pastes
        # it. Windows Terminal has no separate primary-selection buffer the
        # way X11 or ghostty do, so there is only one thing this can mean.
        TerminalCopyOnSelect = $true
        # Padding between the terminal content and the window edge, in the
        # "left,top" / "left,top,right,bottom" string form settings.json takes.
        # WT's default is 8; 10 matches the ghostty side.
        TerminalPadding    = '10, 10'
        # Scrollback in LINES (WT's unit, not bytes). WT's default is 9001,
        # which is small on a machine that runs long log tails. 100000 is the
        # rough intent-match for ghostty's 256MB per surface without asking
        # for `-1 = unlimited` and the leaks that go with it.
        TerminalHistorySize = 100000
        # Fixed GUID for the Windows Terminal "PowerShell 7" profile entry,
        # kept stable across runs so the merge script can find it again.
        TerminalPwshGuid  = '{574e775e-4f2a-5b96-ac1e-a2962a402336}'
        OmpThemesDir      = 'oh-my-posh\themes'
        # posh-git: tab-completion for git subcommands, branches and remotes.
        # Not for its prompt - profile.ps1 imports it before oh-my-posh's
        # `init`, so oh-my-posh's own `prompt` function overwrites posh-git's
        # and wins; only the argument completers it registers survive.
        Modules51         = @('PSReadLine', 'Terminal-Icons', 'PSFzf', 'posh-git')
        # CompletionPredictor is PS7-only: it plugs into the predictor
        # subsystem, which does not exist in Windows PowerShell 5.1.
        # profile.ps1 imports it with -ErrorAction SilentlyContinue and falls
        # back to PredictionSource History, which is exactly the 5.1 case.
        Modules7          = @('PSReadLine', 'Terminal-Icons', 'PSFzf', 'CompletionPredictor', 'posh-git')
        PSReadLineMinimum = '2.4.5'
    }

    # Consumed by the mpv phase. The player itself is in the apps group above;
    # this is the UI and scripts that make it worth using.
    #
    # Deliberately UNPINNED, unlike the container images and clones on the
    # winget packages above, and for a reason worth stating: this is desktop
    # config on a machine somebody uses interactively, not infrastructure where
    # a surprise version means an outage. Staying current matters more here
    # than reproducibility.
    #
    # "Unpinned" is not "unversioned". Every run asks GitHub what the newest
    # release or commit is, writes that exact value to a stamp file next to the
    # scripts, and downloads only when it differs from the stamp. So a run that
    # finds nothing new still transfers nothing, the summary reports a real
    # `a1b2c3d -> e4f5g6h` rather than a shrug, and you can always read what is
    # actually deployed out of %APPDATA%\mpv\.<name>-version.
    #
    # Source says how to ask:
    #   release  newest release TAG      - for repositories that publish them
    #   commit   newest commit SHA       - for those that do not, which is
    #                                      three of these four
    # Path narrows a commit lookup to the file that matters, so an unrelated
    # commit elsewhere in a large repository is not mistaken for a new version.
    Mpv = @{
        # mpv's own installer puts mpv.exe under Program Files and adds nothing
        # to PATH, so `mpv file.mkv` from a prompt does not work out of the box.
        # This appends the directory the player was actually found in to the
        # USER PATH - never the machine one, which would need elevation and is
        # not this tool's to edit. Set to $false to leave PATH alone.
        AddToPath = $true

        Addons = @(
            @{
                Name   = 'uosc'
                Source = 'release'
                Repo   = 'tomasklaen/uosc'
                Kind   = 'zip'
                # Rooted at scripts\ and fonts\, so it expands straight into
                # the config directory.
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
                # Without Path this would track every commit to mpv itself -
                # dozens a week, none of which touch this script - and
                # re-download an identical file each time.
                Path   = 'TOOLS/lua/autoload.lua'
                Kind   = 'script'
                File   = 'autoload.lua'
                Url    = 'https://raw.githubusercontent.com/mpv-player/mpv/{0}/TOOLS/lua/autoload.lua'
            }
            @{
                # Press a key during an opening and it fast-forwards to the
                # next silence, which is where an OP almost always ends. Not
                # automatic - nothing is skipped unless you ask - which is the
                # right default for a script that guesses.
                #
                # Taken from dyphire/mpv-scripts rather than po5/chapterskip:
                # same lineage, but that one has not been touched since 2022
                # while this collection is actively maintained.
                Name   = 'chapterskip'
                Source = 'commit'
                Repo   = 'dyphire/mpv-scripts'
                Path   = 'chapterskip.lua'
                Kind   = 'script'
                File   = 'chapterskip.lua'
                Url    = 'https://raw.githubusercontent.com/dyphire/mpv-scripts/{0}/chapterskip.lua'
            }
            @{
                # mpv.conf sets save-position-on-quit, but that only writes on
                # a CLEAN quit - a crash, a power cut or a killed process loses
                # the position entirely. This re-saves periodically, so the
                # worst case is a minute of rewatching rather than starting the
                # episode again.
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
