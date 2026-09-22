@{
    # PSScriptAnalyzer settings for windows/*.ps1, read by lint.yml.
    #
    # A ratchet, not a wish list. Every rule PSScriptAnalyzer ships is enforced
    # at Warning and above except the ones below, each of which has findings in
    # this repository today and a reason to. The counts are from the commit
    # that added this file - they are there to be argued down, and a rule that
    # reaches zero should come off this list rather than sit here forever.
    #
    # The point of excluding rather than lowering the severity: new code cannot
    # introduce a violation of any *other* rule without CI going red, which is
    # the only way a linter added to an existing codebase is worth having.

    Severity = @('Error', 'Warning')

    ExcludeRules = @(
        # 33 findings. This is a console tool whose entire job is printing a
        # coloured report to a human; Write-Output would put the report into
        # the pipeline, where callers would have to filter it back out.
        'PSAvoidUsingWriteHost'

        # 8. Parameters kept for a uniform signature across sibling functions,
        # and PSScriptAnalyzer cannot see uses inside a string expansion.
        'PSReviewUnusedParameter'

        # 7. `iex` on a here-string is how the shell phase evaluates the
        # profile fragments it just wrote, with input this script generated.
        'PSAvoidUsingInvokeExpression'

        # 7 + 4. Phases call ShouldProcess through $PSCmdlet at the point of
        # change rather than declaring it per helper function; the -WhatIf
        # behaviour is tested and correct.
        'PSShouldProcess'
        'PSUseShouldProcessForStateChangingFunctions'

        # 3. The profile deliberately shadows built-ins with the modern
        # equivalents (ls -> eza, cat -> bat), exactly as the zsh fragment
        # does on the other two platforms.
        'PSAvoidOverwritingBuiltInCmdlets'

        # 2, both in prompt hooks in profile.ps1, where the recovery *is*
        # "carry on and draw the prompt anyway" and a log line would fire on
        # every keystroke. bootstrap.ps1 has none: its catches say why they
        # gave up with Write-Verbose.
        'PSAvoidUsingEmptyCatchBlock'

        # 2. Get-InstalledPackages and friends return collections; renaming
        # them now would break nothing and read worse.
        'PSUseSingularNouns'

        # 2, both `$global:ToolsRows`. One file writes that list and another
        # reads it: bootstrap.ps1 generates tools-list.ps1, the profile
        # dot-sources it, `cheat` in the profile reads it back, and -Doctor
        # asks a fresh shell how many rows it has. A script-scoped variable
        # belongs to the file it is written in, so it would not survive any of
        # those hops - this one is global on purpose.
        'PSAvoidGlobalVars'

        # 1. A BOM is what Windows PowerShell 5.1 needs to read a UTF-8 file,
        # and what this repository deliberately does not write elsewhere.
        'PSUseBOMForUnicodeEncodedFile'

        # 1. Flagged on a winget call whose arguments are assembled as an
        # array and splatted, which the rule does not follow.
        'PSUseCmdletCorrectly'
    )
}
