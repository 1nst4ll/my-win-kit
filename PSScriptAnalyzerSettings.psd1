# PSScriptAnalyzer settings for tools/lint.ps1 and CI.
# Why each rule is excluded: see CLAUDE.md -> "Lint".
@{
    Severity     = @('Error', 'Warning')
    ExcludeRules = @(
        'PSAvoidUsingWriteHost'          # interactive TUIs: coloured console output is the product
        'PSAvoidUsingEmptyCatchBlock'    # best-effort console/host calls that some hosts lack
        'PSUseSingularNouns'             # Get-WingetRows, Get-PkgVersions: internal helpers
        'PSUseApprovedVerbs'             # Run-Install: internal helper, never exported
        'PSAvoidUsingInvokeExpression'   # custom installers use the vendors' official irm | iex
    )
}
