<#
.SYNOPSIS
    Lints the repository with PSScriptAnalyzer, exactly as CI does.

.DESCRIPTION
    Runs PSScriptAnalyzer over every script in the repository with
    PSScriptAnalyzerSettings.psd1. Errors and warnings fail (exit 1); Information
    findings are reported but do not.

    Pinned to the analyzer version the settings were tuned against, because a
    newer analyzer can add rules and fail the build with no code change. Installs
    that version for the current user if it is missing.

    Inside GitHub Actions each finding becomes an annotation on its file and
    line; anywhere else it prints file:line [rule] message.

.EXAMPLE
    .\Test-JobSweepLint.ps1
    powershell.exe -File .\Test-JobSweepLint.ps1      # Windows PowerShell 5.1
    .\Test-JobSweepLint.ps1 -BothEditions             # both, one summary table

    Every run ends with the summary banner from JobSweep.Summary.ps1.
#>

[CmdletBinding()]
param(
    # Run this lint under powershell.exe AND pwsh, each in its own process, and
    # print one summary for both. A missing edition is a failure, not a skip.
    [switch] $BothEditions,
    # Where a run writes its counts as JSON. -BothEditions sets this; you never need to.
    [string] $ResultPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$version = '1.25.0'
$edition = "PowerShell $($PSVersionTable.PSVersion)"
. (Join-Path $PSScriptRoot 'JobSweep.Summary.ps1')

if ($BothEditions) {
    $results = foreach ($exe in 'powershell.exe', 'pwsh') {
        Write-Host "`n==== $exe ====" -ForegroundColor Cyan
        if (-not (Get-Command $exe -ErrorAction SilentlyContinue)) {
            [pscustomobject][ordered]@{ Edition = $exe; Version = '-'; Analyzer = $version; Findings = '-'; Blocking = '-'; Result = 'MISSING' }
            continue
        }
        $out = Join-Path ([IO.Path]::GetTempPath()) ("jobsweep-lint-{0}.json" -f ([guid]::NewGuid().ToString('N')))
        $ver = & $exe -NoProfile -Command '$PSVersionTable.PSVersion.ToString()'
        & $exe -NoProfile -ExecutionPolicy Bypass -File $PSCommandPath -ResultPath $out | Out-Host
        $code = $LASTEXITCODE
        $r = $null
        if (Test-Path -LiteralPath $out) {
            try { $r = Get-Content -Raw -LiteralPath $out | ConvertFrom-Json }
            catch { Write-Host "Could not read the $exe result file: $($_.Exception.Message)" -ForegroundColor Red }
            Remove-Item -LiteralPath $out -Force -ErrorAction SilentlyContinue
        }
        [pscustomobject][ordered]@{
            Edition  = $exe
            Version  = "$ver"
            Analyzer = $version
            Findings = $(if ($r) { $r.Findings } else { '-' })
            Blocking = $(if ($r) { $r.Blocking } else { '-' })
            Result   = $(if ($code -eq 0 -and $r) { 'PASS' } elseif ($code -eq 0) { 'FAIL (no counts written)' } else { "FAIL (exit $code)" })
        }
    }
    $results = @($results)
    $okRuns = @($results | Where-Object { $_.Result -eq 'PASS' }).Count
    Write-JobSweepSummary -Script 'Test-JobSweepLint.ps1 -BothEditions' -Target "PSScriptAnalyzer $version, $PSScriptRoot" `
        -Rows $results -Pass $okRuns -Fail ($results.Count - $okRuns) -Skip 0
    if ($okRuns -ne $results.Count) { exit 1 }
    exit 0
}

if (-not (Get-Module -ListAvailable PSScriptAnalyzer | Where-Object Version -eq $version)) {
    # Windows PowerShell 5.1 needs TLS 1.2 and the NuGet provider for the Gallery.
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    if (-not (Get-PackageProvider -ListAvailable -Name NuGet -ErrorAction SilentlyContinue)) {
        Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Scope CurrentUser -Force | Out-Null
    }
    Install-Module PSScriptAnalyzer -RequiredVersion $version -Scope CurrentUser -Force
}
Import-Module PSScriptAnalyzer -RequiredVersion $version

$settings = Join-Path $PSScriptRoot 'PSScriptAnalyzerSettings.psd1'
$findings = @(Invoke-ScriptAnalyzer -Path $PSScriptRoot -Recurse -Settings $settings)
$inActions = $env:GITHUB_ACTIONS -eq 'true'

Push-Location $PSScriptRoot
try {
    foreach ($f in $findings) {
        # repo-relative with forward slashes, so GitHub links the annotation to the file
        $file = (Resolve-Path -Relative $f.ScriptPath) -replace '^\.[\\/]', '' -replace '\\', '/'
        if ($inActions) {
            $level = if ("$($f.Severity)" -eq 'Information') { 'notice' } else { 'error' }
            Write-Output "::$level file=$file,line=$($f.Line)::[$($f.RuleName)] $($f.Message)"
        } else {
            Write-Output "$($file):$($f.Line) [$($f.Severity)] [$($f.RuleName)] $($f.Message)"
        }
    }
} finally { Pop-Location }

$blocking = @($findings | Where-Object { "$($_.Severity)" -in 'Error', 'Warning', 'ParseError' })
Write-Output "PSScriptAnalyzer $version on ${edition}: $($findings.Count) finding(s), $($blocking.Count) blocking."
if ($ResultPath) {
    [ordered]@{ Findings = $findings.Count; Blocking = $blocking.Count } |
        ConvertTo-Json -Compress | Set-Content -LiteralPath $ResultPath -Encoding utf8
} else {
    # One row per rule that fired, so the table says what to fix.
    $rows = @($findings | Group-Object RuleName, Severity | ForEach-Object {
        [pscustomobject][ordered]@{ Rule = $_.Group[0].RuleName; Severity = "$($_.Group[0].Severity)"; Count = $_.Count
            Blocking = $(if ("$($_.Group[0].Severity)" -in 'Error', 'Warning', 'ParseError') { 'yes' } else { 'no' }) } })
    if ($rows.Count -eq 0) { $rows = @([pscustomobject][ordered]@{ Edition = $edition; Analyzer = $version; Findings = 0; Blocking = 0; Result = 'PASS' }) }
    Write-JobSweepSummary -Script 'Test-JobSweepLint.ps1' -Target "PSScriptAnalyzer $version on $edition, $PSScriptRoot" `
        -Rows $rows -Pass $(if ($blocking.Count -eq 0) { 1 } else { 0 }) -Fail $(if ($blocking.Count -gt 0) { 1 } else { 0 }) -Skip 0
}
if ($blocking.Count -gt 0) { exit 1 }
