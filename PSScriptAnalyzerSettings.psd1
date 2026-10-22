# PSScriptAnalyzer settings for JobSweep.
#
# Picked up automatically by the VS Code PowerShell extension, and by
#   Invoke-ScriptAnalyzer -Path . -Recurse -Settings .\PSScriptAnalyzerSettings.psd1
#
# The first full pass (2026-10-22, PSScriptAnalyzer 1.25.0) found no errors.
# Every warning traced to a deliberate choice in this codebase, not a defect:
#
#   PSAvoidUsingPositionalParameters (258, Information)
#       All in Test-JobSweepFilters.ps1: Check 'name' (actual) (expected).
#       Positional is the readable form for a table of test cases.
#   PSAvoidUsingWriteHost (45)
#       Write-Log prints coloured status lines to the console on purpose and
#       writes the same text to the log file; Write-Host is the right tool.
#   PSAvoidUsingEmptyCatchBlock (9)
#       Best-effort steps that must never stop the run: setting TLS 1.2, a
#       log write, reading HTTP status and Retry-After headers, probing the
#       output folder. Failures there are handled by what follows.
#   PSUseSingularNouns (9)
#       Get-GreenhouseJobs, Test-RemoteFlags, Resolve-WorkdayBullets...
#       Renaming would churn the test suite, which pulls these functions out
#       of the script by name.
#   PSAvoidOverwritingBuiltInCmdlets (1)
#       False positive: no Write-Log cmdlet exists in PowerShell 5.1 or 7.
#   PSUseShouldProcessForStateChangingFunctions (1)
#       New-Posting builds an object in memory; it changes no system state.

@{
    Severity     = @('Error', 'Warning', 'Information')

    # Off for the whole repo: both fire only on deliberate style. Every other
    # rule stays on; the empty-catch and singular-noun findings are handled in
    # the code instead, so the rules still guard anything new.
    ExcludeRules = @(
        'PSAvoidUsingWriteHost'
        'PSAvoidUsingPositionalParameters'
    )

    Rules = @{
        # Every ATS provider fetches a list of postings, so Get-<Ats>Jobs is
        # plural by nature -- today's seven and any added later. The allow-list
        # matches on the end of the noun, so other plurals are still flagged.
        # Data and Windows are the rule's built-in defaults.
        PSUseSingularNouns = @{
            Enable        = $true
            NounAllowList = @('Data', 'Windows', 'Jobs')
        }
    }
}
