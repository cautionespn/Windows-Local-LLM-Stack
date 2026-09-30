# PSScriptAnalyzer settings for llmstack-windows.ps1 and the tests.
# CI runs: Invoke-ScriptAnalyzer -Settings ./PSScriptAnalyzerSettings.psd1
# Only rules that actually fire are excluded, each with its reason.
@{
    Severity     = @('Error', 'Warning')
    ExcludeRules = @(
        # An interactive installer: output is for the person at the console,
        # in colour, on Windows PowerShell 5.1 and 7. Tests read it through
        # the information stream (6>&1).
        'PSAvoidUsingWriteHost',
        # The script asks its own confirmations, one per change, defaulting
        # to no; -WhatIf/-Confirm would duplicate them. Its functions are
        # private helpers, not cmdlets.
        'PSUseShouldProcessForStateChangingFunctions',
        # Private helper names describe what they return (Get-LlmCatalogRows,
        # Get-LlmInstalledModels); they are not exported cmdlets.
        'PSUseSingularNouns'
    )
}
