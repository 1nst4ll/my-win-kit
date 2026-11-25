# PSScriptAnalyzer settings for tools/lint.ps1 and CI.
# Why each rule is excluded: see CLAUDE.md -> "Lint".
@{
    Severity     = @('Error', 'Warning')
    ExcludeRules = @(
        'PSAvoidUsingWriteHost'                        # interactive TUIs: coloured console output is the product
        'PSAvoidUsingEmptyCatchBlock'                  # best-effort console/host calls that some hosts lack
        'PSUseSingularNouns'                           # internal helpers, never exported to users
        'PSUseApprovedVerbs'                           # internal helpers, never exported to users
        'PSAvoidUsingInvokeExpression'                 # vendor installers are official irm | iex one-liners
        'PSUseShouldProcessForStateChangingFunctions'  # internal helpers; the kit's what-if is -DryRun
    )
}
